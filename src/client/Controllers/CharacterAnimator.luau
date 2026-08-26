--!nonstrict
--[[
	CharacterAnimator.luau
	Makes your character move the way you are actually playing — for everyone else.

	This game ships no animation assets. Uploading them needs a Roblox account
	and an asset id per clip, which a repository cannot carry, so without this
	the character stands in the default idle pose: arms level no matter where you
	are aiming, no reaction when you fire, no reload. An enemy shooting at the
	floor and an enemy aiming at your head look identical, which is a real
	competitive problem and not only a cosmetic one.

	So the pose is computed rather than played back. Each frame it writes the
	shoulder joints directly:

	  - the arms follow your camera pitch, so where a player is looking is
	    visible from across the map
	  - firing kicks the arms up and decays, driven by the same recoil the
	    camera uses, so the gun visibly jumps
	  - reloading dips the arms and rotates them back over the weapon's real
	    reload time, so an enemy caught reloading is readable

	Only the local character is touched. A player owns their own character's
	joints, so Roblox replicates these to everyone else — which is what makes
	this visible at all — and no server work or remote traffic is involved.

	R6 and R15 are both handled: the joint names differ, everything else does not.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local RecoilController = require(script.Parent.RecoilController)
local Trove = require(Shared.Util.Trove)
local WeaponClient = require(script.Parent.WeaponClient)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local CharacterAnimator = {}
CharacterAnimator.Priority = 12

local RENDER_NAME = "LaserTagCharacterPose"

-- How much of the camera's pitch the arms take. Full pitch looks broken at
-- extremes because the shoulder has no elbow to compensate with.
local PITCH_FOLLOW = 0.75
local MAX_PITCH_RAD = math.rad(60)

local FIRE_KICK_RAD = math.rad(9)
local FIRE_DECAY = 9

local RELOAD_DIP_RAD = math.rad(35)

local player = Players.LocalPlayer
local trove = Trove.new()
local characterTrove = Trove.new()

local joints: { { motor: Motor6D, base: CFrame, side: number } } = {}
local firePunch = 0
local reloadStartedAt = 0
local reloadDuration = 0

--------------------------------------------------------------------------------
-- Rig
--------------------------------------------------------------------------------

--[[
	Collect the shoulder joints for whichever rig this character uses, recording
	each joint's resting transform so every pose is expressed relative to it
	rather than accumulating drift.
]]
local function collectJoints(character: Model)
	joints = {}

	-- R15: the shoulder Motor6D lives inside the upper arm.
	local r15 = {
		{ part = "RightUpperArm", motor = "RightShoulder", side = 1 },
		{ part = "LeftUpperArm", motor = "LeftShoulder", side = -1 },
	}
	for _, entry in r15 do
		local limb = character:FindFirstChild(entry.part)
		local motor = limb and limb:FindFirstChild(entry.motor)
		if motor and motor:IsA("Motor6D") then
			table.insert(joints, { motor = motor, base = motor.C0, side = entry.side })
		end
	end

	if #joints > 0 then
		return
	end

	-- R6: both shoulders hang off the torso, under names with a space.
	local torso = character:FindFirstChild("Torso")
	if not torso then
		return
	end
	for _, entry in { { name = "Right Shoulder", side = 1 }, { name = "Left Shoulder", side = -1 } } do
		local motor = torso:FindFirstChild(entry.name)
		if motor and motor:IsA("Motor6D") then
			table.insert(joints, { motor = motor, base = motor.C0, side = entry.side })
		end
	end
end

--------------------------------------------------------------------------------
-- Pose
--------------------------------------------------------------------------------

local function cameraPitch(): number
	local camera = Workspace.CurrentCamera
	if not camera then
		return 0
	end

	-- LookVector.Y is the sine of the pitch, so asin recovers the angle.
	local pitch = math.asin(math.clamp(camera.CFrame.LookVector.Y, -1, 1))
	return math.clamp(pitch * PITCH_FOLLOW, -MAX_PITCH_RAD, MAX_PITCH_RAD)
end

local function reloadProgress(): number
	if reloadDuration <= 0 then
		return 0
	end

	local elapsed = os.clock() - reloadStartedAt
	if elapsed >= reloadDuration then
		return 0
	end

	-- One up-and-back arc across the reload rather than a linear slide, so the
	-- motion reads as a reload instead of the arms drifting.
	return math.sin((elapsed / reloadDuration) * math.pi)
end

local function onRender(deltaTime: number)
	if #joints == 0 then
		return
	end

	firePunch = math.max(0, firePunch - firePunch * FIRE_DECAY * deltaTime)

	local pitch = cameraPitch()
	local dip = reloadProgress() * RELOAD_DIP_RAD
	local kick = firePunch * FIRE_KICK_RAD

	-- Aiming and recoil raise the arms; a reload drops them.
	local xRotation = -pitch - kick + dip

	for _, joint in joints do
		if joint.motor.Parent then
			-- The reload roll goes opposite ways on the two arms so they close
			-- toward the weapon rather than both swinging the same direction.
			local roll = dip * 0.4 * joint.side
			joint.motor.C0 = joint.base * CFrame.Angles(xRotation, 0, roll)
		end
	end
end

--------------------------------------------------------------------------------
-- Character lifecycle
--------------------------------------------------------------------------------

local function onCharacterAdded(character: Model)
	characterTrove:Clean()

	firePunch = 0
	reloadStartedAt = 0
	reloadDuration = 0

	-- The rig is assembled a moment after the character arrives, so wait for a
	-- part that only exists once it is.
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	collectJoints(character)
	if #joints == 0 then
		-- Wait for the rig rather than giving up: on a slow join the limbs can
		-- still be replicating when the character first appears.
		characterTrove:Add(character.ChildAdded:Connect(function()
			if #joints == 0 then
				collectJoints(character)
			end
		end))
	end

	characterTrove:Add(humanoid.Died:Connect(function()
		joints = {}
	end))
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function CharacterAnimator.init()
	if player.Character then
		onCharacterAdded(player.Character)
	end
	trove:Add(player.CharacterAdded:Connect(onCharacterAdded))
end

function CharacterAnimator.start()
	trove:Add(WeaponClient.Fired:Connect(function()
		-- Taken from the shared recoil model rather than a constant, so a weapon
		-- that kicks harder on the camera also kicks harder on the body.
		firePunch = math.clamp(1 + RecoilController.getPunch(), 1, 2.5)
	end))

	trove:Add(ClientState.AmmoChanged:Connect(function(ammo)
		if not ammo or not ammo.reloading then
			return
		end
		if reloadProgress() > 0 then
			return -- already animating this reload
		end

		local weapon = WeaponConfig.get(ammo.weaponId)
		reloadDuration = if weapon then weapon.reloadTime else 0
		reloadStartedAt = os.clock()
	end))

	-- After Character priority: the default animate script writes the same
	-- joints, and running before it would have our pose overwritten every frame.
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Character.Value + 1, onRender)
	trove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_NAME)
	end)
end

function CharacterAnimator.stop()
	characterTrove:Clean()
	trove:Clean()
	joints = {}
end

return CharacterAnimator
