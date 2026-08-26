--!nonstrict
--[[
	CameraController.luau
	Owns workspace.CurrentCamera: the first-person baseline, the death camera and
	the recoil offset that weapon controllers push into the view.

	Ownership note: MouseLockController owns `player.CameraMode` and the mouse
	behaviour. This controller only touches the Camera instance, so the two never
	fight over the same property.

	Recoil
	------
	`addRecoilOffset(pitchDeg, yawDeg, recoveryRate?)` accumulates a view kick.
	The offset is re-applied in full every frame from a BindToRenderStep bound
	just after Enum.RenderPriority.Camera, because Roblox's camera module rebuilds
	Camera.CFrame from scratch each frame from raw mouse deltas — a one-shot
	rotation would be erased on the very next frame.

	Applying the kick to the camera (rather than to a cosmetic viewmodel) means it
	also moves the aim, which is the point: the spray pattern has to be fought.
	The offset then decays exponentially back to zero at `recoveryRate` units per
	second. That rate comes from WeaponConfig.<weapon>.recoilRecovery — it is a
	per-weapon number, so the recoil controller passes its own weapon's value and
	the default below is only the fallback used before the first shot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local MathUtil = require(Shared.Util.MathUtil)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local CameraController = {}
CameraController.Priority = 3

local RENDER_BINDING = "LaserTagCameraOffset"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1

local rifle = WeaponConfig.get("Rifle")
local DEFAULT_RECOIL_RECOVERY = (rifle and rifle.recoilRecovery) or 10

-- A kick larger than this is a bug in a spray pattern, not a design choice;
-- clamping keeps a bad value from throwing the view at the sky.
local MAX_RECOIL_DEG = 20

-- Death camera framing, in the killer's local space: behind and above the
-- shoulder, looking at their chest.
local DEATH_CAM_BACK = 9
local DEATH_CAM_UP = 4.5
-- Higher converges faster. 6 lands the camera in roughly half a second, which
-- fits inside Constants.RESPAWN_SECONDS with time left to watch the killer.
local DEATH_CAM_STIFFNESS = 6

local player = Players.LocalPlayer
local trove = Trove.new()

local camera: Camera? = workspace.CurrentCamera
local recoilPitch = 0
local recoilYaw = 0
local recoveryRate = DEFAULT_RECOIL_RECOVERY

local deathCamActive = false
local deathTargetPart: BasePart? = nil
local deathLastCFrame: CFrame? = nil
-- Bumped on every death so a stale watchdog from a previous death cannot cut a
-- later one short. Cheaper and safer than cancelling the thread: the watchdog
-- itself may be the caller of stopDeathCam.
local deathGeneration = 0

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function CameraController.getCamera(): Camera?
	if not camera or camera.Parent == nil then
		camera = workspace.CurrentCamera
	end
	return camera
end

--[[
	Adds a view kick. Positive pitch raises the view; positive yaw turns right.
	`recoveryRate` is WeaponConfig.<weapon>.recoilRecovery for the firing weapon;
	omit it to keep whatever rate was last set.
]]
function CameraController.addRecoilOffset(pitchDeg: number, yawDeg: number, newRecoveryRate: number?)
	if not MathUtil.isFinite(pitchDeg) or not MathUtil.isFinite(yawDeg) then
		return
	end

	if type(newRecoveryRate) == "number" and newRecoveryRate > 0 then
		recoveryRate = newRecoveryRate
	end

	recoilPitch = MathUtil.clamp(recoilPitch + pitchDeg, -MAX_RECOIL_DEG, MAX_RECOIL_DEG)
	recoilYaw = MathUtil.clamp(recoilYaw + yawDeg, -MAX_RECOIL_DEG, MAX_RECOIL_DEG)
end

--[[
	Current accumulated offset in degrees.
]]
function CameraController.getRecoilOffset(): (number, number)
	return recoilPitch, recoilYaw
end

function CameraController.setRecoilRecovery(rate: number)
	if type(rate) == "number" and rate > 0 then
		recoveryRate = rate
	end
end

function CameraController.resetRecoil()
	recoilPitch = 0
	recoilYaw = 0
end

function CameraController.isDeathCamActive(): boolean
	return deathCamActive
end

--------------------------------------------------------------------------------
-- First person baseline
--------------------------------------------------------------------------------

local function restoreCamera()
	local cam = CameraController.getCamera()
	if not cam then
		return
	end

	cam.CameraType = Enum.CameraType.Custom

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		cam.CameraSubject = humanoid
	end
end

--------------------------------------------------------------------------------
-- Death camera
--------------------------------------------------------------------------------

local function resolveDeathTarget(killerUserId: number?): BasePart?
	if killerUserId then
		local killer = Players:GetPlayerByUserId(killerUserId)
		local character = killer and killer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			return root
		end
	end

	-- No killer (fall damage, kill plane, disconnect) — watch our own body drop.
	local ownCharacter = player.Character
	local ownRoot = ownCharacter and ownCharacter:FindFirstChild("HumanoidRootPart")
	if ownRoot and ownRoot:IsA("BasePart") then
		return ownRoot
	end

	return nil
end

local function stopDeathCam()
	if not deathCamActive then
		return
	end

	deathCamActive = false
	deathTargetPart = nil
	deathLastCFrame = nil
	deathGeneration += 1
	restoreCamera()
end

local function startDeathCam(killerUserId: number?, respawnSeconds: number)
	local cam = CameraController.getCamera()
	if not cam then
		return
	end

	deathTargetPart = resolveDeathTarget(killerUserId)
	deathLastCFrame = cam.CFrame
	deathCamActive = true

	cam.CameraType = Enum.CameraType.Scriptable

	-- Safety net: if Respawned never arrives (character load failure) the player
	-- must not be stuck in a scriptable camera forever.
	deathGeneration += 1
	local generation = deathGeneration
	task.delay((respawnSeconds or Constants.RESPAWN_SECONDS) + 2, function()
		if deathGeneration == generation then
			stopDeathCam()
		end
	end)
end

--[[
	Frames the death target and eases the camera toward it. When the target
	despawns mid-animation the last good pose is kept as the goal, so the view
	settles where the body was instead of snapping to the world origin.
]]
local function updateDeathCam(cam: Camera, deltaTime: number)
	local target = deathTargetPart
	if target and target.Parent then
		local targetCFrame = target.CFrame
		local focus = targetCFrame.Position + Vector3.new(0, 1.5, 0)
		local eye = targetCFrame * CFrame.new(0, DEATH_CAM_UP, DEATH_CAM_BACK)
		deathLastCFrame = CFrame.lookAt(eye.Position, focus)
	elseif target then
		deathTargetPart = nil
	end

	local goal = deathLastCFrame
	if not goal then
		return
	end

	-- Framerate-independent easing: the same visual convergence at 30 and 240 fps.
	local alpha = 1 - math.exp(-DEATH_CAM_STIFFNESS * deltaTime)
	cam.CFrame = cam.CFrame:Lerp(goal, alpha)
end

--------------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------------

local function onRender(deltaTime: number)
	local cam = CameraController.getCamera()
	if not cam then
		return
	end

	if deathCamActive then
		updateDeathCam(cam, deltaTime)
		return
	end

	if recoilPitch == 0 and recoilYaw == 0 then
		return
	end

	cam.CFrame = cam.CFrame * CFrame.Angles(math.rad(recoilPitch), math.rad(recoilYaw), 0)

	local decay = math.exp(-recoveryRate * deltaTime)
	recoilPitch *= decay
	recoilYaw *= decay

	-- Snap the tail of the exponential to zero so the offset stops costing a
	-- CFrame multiply every frame for the rest of the round.
	if math.abs(recoilPitch) < 0.01 and math.abs(recoilYaw) < 0.01 then
		recoilPitch = 0
		recoilYaw = 0
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CameraController.init()
	ClientState.init()

	trove:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		camera = workspace.CurrentCamera
		if not deathCamActive then
			restoreCamera()
		end
	end)

	trove:Add(ClientState.Died:Connect(function(killerUserId: number?, respawnSeconds: number)
		startDeathCam(killerUserId, respawnSeconds)
	end))

	trove:Add(ClientState.Respawned:Connect(function()
		CameraController.resetRecoil()
		stopDeathCam()
		restoreCamera()
	end))

	trove:Connect(player.CharacterAdded, function()
		CameraController.resetRecoil()
	end)

	RunService:BindToRenderStep(RENDER_BINDING, RENDER_PRIORITY, onRender)
	trove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_BINDING)
	end)
end

function CameraController.start()
	restoreCamera()
end

function CameraController.stop()
	stopDeathCam()
	trove:Clean()
end

return CameraController
