--!nonstrict
--[[
	ViewmodelController.luau
	The first-person gun. A GunModelFactory model is cloned into
	workspace.CurrentCamera and re-posed from the camera's own CFrame every frame,
	which is what welds it to the view at zero network cost: nothing parented to
	the Camera is replicated, simulated or visible to anyone else.

	Four offsets are summed into one pose each frame:
	  * sway  — lags the view's angular velocity, so a flick throws the gun wide
	            and it settles back
	  * bob   — a figure-eight driven by horizontal walk speed
	  * dip   — the reload animation
	  * punch — RecoilController's decaying kick, plus a counter-rotation against
	            the camera's recoil offset so the muzzle visibly lags the view

	Every part is anchored and posed with Model:PivotTo, so the factory's
	WeldConstraints are disabled rather than left to fight the assignment. Parts
	are also stripped of collision, query and shadow: an unlit, non-colliding
	model a stud from the near plane would otherwise drop a shadow across the
	whole screen.

	The hub has no weapons (PlayerService.clearWeapons runs on a hub spawn), so
	the viewmodel only exists while the InMatch attribute names a map.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local GunModelFactory = require(Shared.GunModelFactory)
local PerspectiveController = require(script.Parent.PerspectiveController)
local RecoilController = require(script.Parent.RecoilController)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ViewmodelController = {}
-- After RecoilController (6), whose punch this module reads every frame.
ViewmodelController.Priority = 7

local RENDER_BINDING = "LaserTagViewmodel"
-- CameraController poses the camera at Camera+1 and CharacterVisualsController
-- hides the body at Camera+2; posing the gun last means it is attached to this
-- frame's view instead of the previous frame's.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 3

-- Where the Handle sits in camera space, per weapon. The rifle is longer, so it
-- is held further back and lower to keep the stock out of the near plane.
local HOLD = {
	Rifle = Vector3.new(0.95, -0.95, -1.15),
	Pistol = Vector3.new(0.78, -0.82, -1.0),
}
local DEFAULT_HOLD = Vector3.new(0.9, -0.9, -1.1)

-- Sway. SCALE converts radians/second of view rotation into studs of lag;
-- LIMIT caps a 180-degree flick so the gun cannot leave the screen.
local SWAY_SCALE = 0.05
local SWAY_LIMIT = 0.22
local SWAY_STIFFNESS = 9
local SWAY_ROT_PER_STUD = 0.9
local SWAY_ROLL_PER_STUD = 1.0

-- Bob. Frequency is in radians/second at full walk speed; the amplitudes are
-- studs at that speed and scale linearly down to a standstill.
local BOB_FREQUENCY = 11
local BOB_AMPLITUDE_X = 0.055
local BOB_AMPLITUDE_Y = 0.04
local BOB_BLEND = 6
local BOB_MIN_SPEED = 1.5

-- Reload dip: down over the first quarter, held, back up over the last quarter.
local RELOAD_RAMP = 0.25
local RELOAD_DIP = 0.55
local RELOAD_PITCH = 0.5

-- Equip raise, in seconds. Matches WeaponClient's switch lockout so the gun is
-- on screen exactly when it becomes fireable.
local EQUIP_TIME = 0.35
local EQUIP_DROP = 0.9

-- Fraction of the camera's recoil offset the gun rotates *against*. The camera
-- has already been kicked by the time this binding runs, so this is what makes
-- the muzzle appear to trail the view instead of moving rigidly with it.
local RECOIL_LAG = 0.35
-- Studs of rearward travel and radians of muzzle flip per stud of punch. A
-- sustained rifle burst settles around 0.13 punch, so these land at roughly
-- 0.13 studs back and 7 degrees up; RecoilController's ceiling caps the worst
-- case at about 15 degrees, which is a shudder rather than a gun to the sky.
local PUNCH_BACK = 1.0
local PUNCH_PITCH = 0.9

-- Clamp for the per-frame delta used to derive angular velocity. Without it a
-- single long frame (level streaming, alt-tab) divides by a tiny number and
-- throws the gun across the screen.
local MIN_DELTA = 1 / 240

-- How often the render loop re-checks for a missing gun. The character's
-- Humanoid can arrive a frame or two after CharacterAdded, which means a
-- refresh triggered by that event can legitimately find nothing to build; this
-- is the retry that stops such a race from leaving the player empty-handed for
-- a whole life.
local REBUILD_RETRY = 0.25

local player = Players.LocalPlayer
local trove = Trove.new()

local viewmodel: Model? = nil
local muzzle: Attachment? = nil
local builtWeaponId: string? = nil
local builtSkinId: string? = nil

local currentWeaponId = Constants.SLOTS[Constants.DEFAULT_SLOT]
local lastCameraCF = CFrame.identity
local swayX, swayY = 0, 0
local bobPhase, bobStrength = 0, 0
local reloadStart, reloadDuration = 0, 0
local equipStart = 0
local nextRebuildAt = 0

--------------------------------------------------------------------------------
-- Build / teardown
--------------------------------------------------------------------------------

local function equippedSkinFor(weaponId: string): string
	local skinId = ClientState.equippedSkins[weaponId]
	return if SkinCatalog.exists(skinId) then skinId else SkinCatalog.DEFAULT_SKIN_ID
end

local function destroyViewmodel()
	if viewmodel then
		viewmodel:Destroy()
	end
	viewmodel = nil
	muzzle = nil
	builtWeaponId = nil
	builtSkinId = nil
end

local function isAlive(): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return not ClientState.isDead and humanoid ~= nil and humanoid.Health > 0
end

--[[
	Rebuild from scratch. Cheap enough to do on a weapon or skin change (a dozen
	parts) and far simpler than mutating a live model, but never called per frame.
]]
local function rebuild()
	destroyViewmodel()

	local camera = workspace.CurrentCamera
	if not camera or not WeaponConfig.exists(currentWeaponId) then
		return
	end
	if not ClientState.isInMatch() or not isAlive() then
		return
	end

	local skinId = equippedSkinFor(currentWeaponId)
	local model = GunModelFactory.build(currentWeaponId, skinId)
	if not model then
		return
	end

	model.Name = "Viewmodel"
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.CastShadow = false
			descendant.Massless = true
		elseif descendant:IsA("WeldConstraint") then
			-- PivotTo drives every part directly; a live weld would fight it.
			descendant.Enabled = false
		end
	end

	local handle = model.PrimaryPart
	if handle then
		handle.Anchored = true
		handle.CanCollide = false
		handle.CanQuery = false
		handle.CanTouch = false
		handle.CastShadow = false
	end

	model.Parent = camera
	viewmodel = model
	muzzle = GunModelFactory.getMuzzle(model)
	builtWeaponId = currentWeaponId
	builtSkinId = skinId

	lastCameraCF = camera.CFrame
	equipStart = os.clock()
end

--[[
	Rebuild only when the model on screen no longer matches what should be there.
]]
local function refresh()
	-- In third person the gun the player sees is the real welded one on their
	-- character, put there by the server. Keeping this camera-parented copy as
	-- well would draw a second gun floating in front of the lens.
	local wantModel = ClientState.isInMatch() and isAlive() and PerspectiveController.isFirstPerson()
	if not wantModel then
		destroyViewmodel()
		return
	end

	if not viewmodel or viewmodel.Parent == nil then
		rebuild()
		return
	end

	if builtWeaponId ~= currentWeaponId or builtSkinId ~= equippedSkinFor(currentWeaponId) then
		rebuild()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Swap the gun on screen. WeaponClient calls this from its own local prediction
	so the model changes on the keypress rather than on the server round trip.
]]
function ViewmodelController.setWeapon(weaponId: string)
	if not WeaponConfig.exists(weaponId) or weaponId == currentWeaponId then
		return
	end

	currentWeaponId = weaponId
	reloadStart = 0
	refresh()
end

--[[
	Play the reload dip for `duration` seconds (the weapon's reloadTime).
]]
function ViewmodelController.playReload(duration: number)
	if type(duration) ~= "number" or duration <= 0 then
		return
	end
	reloadStart = os.clock()
	reloadDuration = duration
end

function ViewmodelController.cancelReload()
	reloadStart = 0
end

--[[
	Replay the raise animation without rebuilding (used when a swap is refused
	server-side and the same weapon comes back).
]]
function ViewmodelController.playEquip()
	equipStart = os.clock()
end

function ViewmodelController.getModel(): Model?
	return viewmodel
end

function ViewmodelController.getMuzzleAttachment(): Attachment?
	return muzzle
end

--[[
	World position of the viewmodel muzzle, or nil when there is no gun on screen.
	VFXController draws the local player's beam from here.
]]
function ViewmodelController.getMuzzlePosition(): Vector3?
	local attachment = muzzle
	if not attachment or attachment.Parent == nil then
		return nil
	end
	return attachment.WorldPosition
end

--[[
	Re-evaluate what should be on screen. Public so a shop screen can call it the
	moment an EquipSkinRequest returns, instead of waiting for ProfileLoaded.
]]
function ViewmodelController.refresh()
	refresh()
end

--------------------------------------------------------------------------------
-- Per-frame pose
--------------------------------------------------------------------------------

local function updateSway(deltaTime: number, cameraCF: CFrame)
	-- Angular velocity rather than a raw per-frame delta: the same flick has to
	-- produce the same sway at 30 and at 240 fps.
	local delta = lastCameraCF:ToObjectSpace(cameraCF)
	local pitchDelta, yawDelta = delta:ToEulerAnglesYXZ()
	lastCameraCF = cameraCF

	-- Turning right is a negative yaw delta and the gun trails to the left, so
	-- the sign passes straight through.
	local targetX = math.clamp(yawDelta / deltaTime * SWAY_SCALE, -SWAY_LIMIT, SWAY_LIMIT)
	local targetY = math.clamp(-pitchDelta / deltaTime * SWAY_SCALE, -SWAY_LIMIT, SWAY_LIMIT)

	local blend = 1 - math.exp(-SWAY_STIFFNESS * deltaTime)
	swayX += (targetX - swayX) * blend
	swayY += (targetY - swayY) * blend
end

local function updateBob(deltaTime: number)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")

	local speed = 0
	if root and root:IsA("BasePart") then
		local velocity = root.AssemblyLinearVelocity
		speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	end

	-- Airborne movement must not bob: there are no footfalls in a jump.
	local grounded = humanoid == nil or humanoid.FloorMaterial ~= Enum.Material.Air
	local target = if grounded and speed > BOB_MIN_SPEED then math.clamp(speed / Constants.WALK_SPEED, 0, 1) else 0

	bobStrength += (target - bobStrength) * (1 - math.exp(-BOB_BLEND * deltaTime))
	bobPhase = (bobPhase + deltaTime * BOB_FREQUENCY * math.max(bobStrength, 0.15)) % (2 * math.pi)
end

--[[
	0 outside a reload, ramping to 1 while the magazine is being swapped and back
	to 0 as the gun comes up. Smoothstepped so the turn-around has no visible
	corner.
]]
local function reloadCurve(now: number): number
	if reloadStart <= 0 or reloadDuration <= 0 then
		return 0
	end

	local progress = (now - reloadStart) / reloadDuration
	if progress >= 1 then
		reloadStart = 0
		return 0
	end

	local raw = math.clamp(math.min(progress / RELOAD_RAMP, (1 - progress) / RELOAD_RAMP), 0, 1)
	return raw * raw * (3 - 2 * raw)
end

local function onRender(deltaTime: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local now = os.clock()
	local model = viewmodel

	if not model or model.Parent == nil then
		-- Throttled self-heal. Every event that should have produced a gun has
		-- already fired by now, so this only ever runs after one of them lost a
		-- race with the character load.
		if now >= nextRebuildAt then
			nextRebuildAt = now + REBUILD_RETRY
			refresh()
		end
		return
	end

	local dt = math.max(deltaTime, MIN_DELTA)
	local cameraCF = camera.CFrame

	updateSway(dt, cameraCF)
	updateBob(dt)

	local bobX = math.sin(bobPhase) * BOB_AMPLITUDE_X * bobStrength
	local bobY = math.sin(bobPhase * 2) * BOB_AMPLITUDE_Y * bobStrength

	local dip = reloadCurve(now)
	local equip = math.clamp(1 - (now - equipStart) / EQUIP_TIME, 0, 1)
	local punch = RecoilController.getPunch()
	local recoilPitch, recoilYaw = RecoilController.getOffset()

	local hold = HOLD[builtWeaponId] or DEFAULT_HOLD
	local offset = CFrame.new(
		hold.X + swayX + bobX,
		hold.Y + swayY + bobY - dip * RELOAD_DIP - equip * EQUIP_DROP,
		hold.Z + punch * PUNCH_BACK
	) * CFrame.Angles(
		swayY * SWAY_ROT_PER_STUD + punch * PUNCH_PITCH - math.rad(recoilPitch * RECOIL_LAG) - dip * RELOAD_PITCH,
		-swayX * SWAY_ROT_PER_STUD - math.rad(recoilYaw * RECOIL_LAG),
		-swayX * SWAY_ROLL_PER_STUD - equip * 0.6
	)

	model:PivotTo(cameraCF * offset)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ViewmodelController.init()
	ClientState.init()

	local attributeWeapon = player:GetAttribute("CurrentWeapon")
	if WeaponConfig.exists(attributeWeapon) then
		currentWeaponId = attributeWeapon
	end

	trove:Add(ClientState.SlotChanged:Connect(function(_slot: number, weaponId: string)
		ViewmodelController.setWeapon(weaponId)
	end))

	-- Switching perspective mid-match either builds this gun or throws it away,
	-- and doing nothing would leave the wrong one on screen until the next
	-- respawn or weapon swap.
	trove:Add(PerspectiveController.Changed:Connect(refresh))

	-- A skin purchase or equip arrives as a fresh profile snapshot.
	trove:Add(ClientState.ProfileChanged:Connect(refresh))

	-- Entering or leaving a match decides whether there is a gun at all.
	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name == "InMatch" then
			refresh()
		end
	end))

	trove:Add(ClientState.Died:Connect(destroyViewmodel))
	trove:Add(ClientState.Respawned:Connect(refresh))

	trove:Connect(player.CharacterRemoving, destroyViewmodel)
	trove:Connect(player.CharacterAdded, function()
		-- The gun is rebuilt against the new camera, not carried over: a respawn
		-- swaps the Camera's CameraSubject and resets the view.
		swayX, swayY, bobStrength = 0, 0, 0
		refresh()
	end)

	trove:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), function()
		destroyViewmodel()
		refresh()
	end)

	RunService:BindToRenderStep(RENDER_BINDING, RENDER_PRIORITY, onRender)
	trove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_BINDING)
	end)
end

function ViewmodelController.start()
	refresh()
end

function ViewmodelController.stop()
	destroyViewmodel()
	trove:Clean()
end

return ViewmodelController
