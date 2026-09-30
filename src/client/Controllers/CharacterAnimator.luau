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

	  - in third person the body is turned to face where the camera looks (see
	    "Facing" below), so the pose above and the beam agree with the body

	R6 and R15 are both handled: the joint names differ, everything else does not.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local MouseLockController = require(script.Parent.MouseLockController)
local PerspectiveController = require(script.Parent.PerspectiveController)
local RecoilController = require(script.Parent.RecoilController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)
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

-- Below this length the camera's horizontal look is too short to name a
-- direction (pitch within ~3 degrees of straight up or down), and normalising
-- it would spin the body on noise.
local MIN_FLAT_LOOK = 0.05
-- Cosine of the yaw error left alone (~0.25 degrees), so a still camera writes
-- nothing and the character's CFrame is not replicated every frame for nothing.
local FACING_SETTLED = 0.99999

local player = Players.LocalPlayer
local trove = Trove.new()
local characterTrove = Trove.new()

local joints: { { motor: Motor6D, base: CFrame, side: number } } = {}
-- The character being turned, and whether AutoRotate is currently off because
-- of us. Restoring only what this module switched off keeps it from overriding
-- a script (a seat, an emote) that turned AutoRotate off for its own reasons.
local currentHumanoid: Humanoid? = nil
local currentRoot: BasePart? = nil
local currentCharacter: Model? = nil
local rotationHeld = false

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
-- Facing
--
-- Roblox turns a character to face the way it WALKS, and in third person the
-- camera looks somewhere else: stand still and swing the mouse, and the body
-- stays put while the beam leaves the head toward the crosshair; strafe, and
-- the body is turned sideways to its own gun. Everyone else reads a player's aim
-- off their body, so this is the same competitive-readability problem the arm
-- pose solves for pitch. Shift-lock solves it in the engine; this game turns
-- shift-lock off (EnableMouseLockOption), so the same thing is done here.
--
-- AutoRotate is switched off and the root is yawed to the camera's horizontal
-- look every frame, after the camera has moved. Movement is untouched: the
-- move direction is camera-relative on every device, so the thumbstick and
-- WASD still walk where they point, and the body simply strafes.
--
-- Roblox's own route (UserGameSettings.RotationType) was not used because the
-- camera module restores that setting itself whenever it believes the view
-- left first person or shift-lock, so it would need re-asserting every frame
-- anyway, without the exclusions below.
--------------------------------------------------------------------------------

local function releaseFacing()
	if not rotationHeld then
		return
	end
	rotationHeld = false

	local humanoid = currentHumanoid
	if humanoid and humanoid.Parent then
		humanoid.AutoRotate = true
	end
end

--[[
	Whether the body should be following the camera right now. Every exclusion
	is a case where somebody else should be steering:

	  * not in a match: the hub is for wandering, and turning to the walk is the
	    natural thing there
	  * dead or seated: the character is not being aimed
	  * first person: the engine already faces the camera, and two writers to one
	    CFrame is how a body jitters
	  * a menu open or the cursor freed: the player is reading a panel, not
	    aiming, and dragging the view over the shop must not spin the character
]]
local function wantsFacing(): boolean
	local humanoid = currentHumanoid
	local character = currentCharacter
	if not humanoid or not character or not humanoid.Parent then
		return false
	end

	if not currentRoot or not currentRoot.Parent then
		-- The rig can still be arriving when the character first appears.
		local found = character:FindFirstChild("HumanoidRootPart")
		currentRoot = if found and found:IsA("BasePart") then found else nil
		if not currentRoot then
			return false
		end
	end

	return ClientState.isInMatch()
		and not ClientState.isDead
		and humanoid.Health > 0
		and not humanoid.Sit
		and not PerspectiveController.isFirstPerson()
		and not UIController.isAnyMenuOpen()
		and not MouseLockController.isUnlocked()
end

local function updateFacing()
	if not wantsFacing() then
		releaseFacing()
		return
	end

	local humanoid = currentHumanoid :: Humanoid
	local root = currentRoot :: BasePart

	-- Asserted every frame rather than once: anything that turns it back on
	-- would otherwise start a fight with the yaw below.
	rotationHeld = true
	if humanoid.AutoRotate then
		humanoid.AutoRotate = false
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < MIN_FLAT_LOOK then
		return
	end
	flat = flat.Unit

	local facing = root.CFrame.LookVector
	local facingFlat = Vector3.new(facing.X, 0, facing.Z)
	if facingFlat.Magnitude > 1e-6 and facingFlat.Unit:Dot(flat) > FACING_SETTLED then
		return
	end

	-- A pure yaw about the root's own position: upright, and not moved.
	local position = root.Position
	root.CFrame = CFrame.lookAt(position, position + flat)
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
	updateFacing()

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
	releaseFacing()
	currentCharacter = character
	currentHumanoid = nil
	currentRoot = nil

	firePunch = 0
	reloadStartedAt = 0
	reloadDuration = 0

	-- The rig is assembled a moment after the character arrives, so wait for a
	-- part that only exists once it is.
	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if not humanoid then
		return
	end

	currentHumanoid = humanoid
	local root = character:FindFirstChild("HumanoidRootPart")
	currentRoot = if root and root:IsA("BasePart") then root else nil

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
		releaseFacing()
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
	releaseFacing()
	characterTrove:Clean()
	trove:Clean()
	joints = {}
	currentCharacter = nil
	currentHumanoid = nil
	currentRoot = nil
end

return CharacterAnimator
