--!nonstrict
--[[
	VFXController.luau
	The public face of combat feedback, and the only place that knows which
	remote or Signal turns into which effect. The effects themselves live in
	VFX/: WorldEffects (beams, muzzle flashes, impacts, damage numbers),
	ScreenEffects (hitmarker, damage indicator), EffectPool (pooling and the one
	per-frame step loop) and VFXSound.

	The split matters because everything here is on the hot path. One Heartbeat
	drives every live effect, every instance comes from a fixed-size pool, and an
	empty pool DROPS the effect rather than allocating — a client already drawing
	eighteen beams gains nothing from a nineteenth.

	Local shots are drawn immediately from WeaponClient without waiting for the
	server; the raycast in playLocalShot is cosmetic and decides only where the
	beam stops. Other players' shots are replayed from the ShotFired remote,
	which already carries the server's muzzle and hit positions, so nothing is
	re-simulated.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local EffectPool = require(script.Parent.VFX.EffectPool)
local ScreenEffects = require(script.Parent.VFX.ScreenEffects)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local Trove = require(Shared.Util.Trove)
local VFXSound = require(script.Parent.VFX.VFXSound)
local ViewmodelController = require(script.Parent.ViewmodelController)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local WorldEffects = require(script.Parent.VFX.WorldEffects)

local VFXController = {}
-- After ViewmodelController (7), whose muzzle this module draws beams from.
VFXController.Priority = 8

--------------------------------------------------------------------------------
-- SOUND SOURCES — drop real asset ids in here
--------------------------------------------------------------------------------
--[[
	This build ships with no uploaded audio, so every `id` below is an
	engine-local `rbxasset://` path: a placeholder chosen only because it exists
	offline, then pitched and gated to stand in for the real sound.

	To use real audio, replace `id` with an `rbxassetid://...` value and set
	`speed` back to 1. Nothing outside this table has to change.

	  volume  0-10, passed straight to Sound.Volume
	  speed   base Sound.PlaybackSpeed
	  jitter  random +/- applied to speed on every play, so a sustained burst of
	          the same sample does not phase-lock into a machine tone
]]
local SOUNDS = {
	Rifle = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.4, speed = 2.6, jitter = 0.08 },
	Pistol = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.5, speed = 1.8, jitter = 0.1 },
	-- Pitched well below the others and louder: the Lance has to be audible
	-- across the map, because knowing a marksman is holding an angle is most of
	-- how you avoid walking into one.
	Lance = { id = "rbxasset://sounds/electronicpingshort.wav", volume = 0.7, speed = 0.75, jitter = 0.04 },
	Impact = { id = "rbxasset://sounds/snap.mp3", volume = 0.3, speed = 1.7, jitter = 0.18 },
	Hitmarker = { id = "rbxasset://sounds/clickfast.wav", volume = 0.55, speed = 1.9, jitter = 0.04 },
	Kill = { id = "rbxasset://sounds/clickfast.wav", volume = 0.75, speed = 1.15, jitter = 0 },
	Reload = { id = "rbxasset://sounds/switch.wav", volume = 0.45, speed = 1, jitter = 0.05 },
	Equip = { id = "rbxasset://sounds/switch.wav", volume = 0.35, speed = 1.6, jitter = 0 },
	Empty = { id = "rbxasset://sounds/clickfast.wav", volume = 0.35, speed = 0.7, jitter = 0 },
	Hurt = { id = "rbxasset://sounds/bass.wav", volume = 0.35, speed = 1.4, jitter = 0.1 },
}

local FALLBACK_BEAM_COLOR = Color3.fromRGB(0, 229, 255)

local player = Players.LocalPlayer
local trove = Trove.new()

-- Reused rather than rebuilt per shot: allocating RaycastParams on a path that
-- runs ten times a second per firing player is the classic hitscan waste.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
local filterList: { Instance } = {}

--------------------------------------------------------------------------------
-- Shots
--------------------------------------------------------------------------------

local function skinColorFor(weaponId: string): Color3
	local skin = SkinCatalog.get(ClientState.equippedSkins[weaponId]) or SkinCatalog.get(SkinCatalog.DEFAULT_SKIN_ID)
	return Color3.fromRGB(skin.color.r, skin.color.g, skin.color.b)
end

--[[
	The local player's own shot, drawn on the frame the trigger was pulled.

	The raycast here is COSMETIC ONLY. It decides where the beam stops and
	nothing else — damage is resolved by the server from its own ray in
	Combat/ShotResolver, against the server's own eye position and spread.
]]
function VFXController.playLocalShot(weaponId: string, origin: Vector3, direction: Vector3)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return
	end

	local character = player.Character
	filterList[1] = character
	raycastParams.FilterDescendantsInstances = filterList

	local result = if character then workspace:Raycast(origin, direction * weapon.range, raycastParams) else nil
	local hitPos = if result then result.Position else origin + direction * weapon.range
	local color = skinColorFor(weaponId)

	-- The beam starts at the viewmodel muzzle so it lines up with the gun on
	-- screen; the camera position is only the fallback for a frame where the
	-- model has not been built yet.
	WorldEffects.beam(ViewmodelController.getMuzzlePosition() or origin, hitPos, color, weapon.beamWidth, nil)
	if result then
		WorldEffects.impact(hitPos, result.Normal, color)
	end
	VFXSound.playLocal(weaponId)
end

--[[
	Another player's shot, replayed from ShotFired. Both endpoints and the skin
	colour come from the server, so nothing here has to be re-derived.
]]
function VFXController.playRemoteShot(
	_shooterUserId: number,
	weaponId: string,
	muzzlePos: Vector3,
	hitPos: Vector3,
	color: Color3
)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon or typeof(muzzlePos) ~= "Vector3" or typeof(hitPos) ~= "Vector3" then
		return
	end

	local tint = if typeof(color) == "Color3" then color else FALLBACK_BEAM_COLOR
	WorldEffects.beam(muzzlePos, hitPos, tint, weapon.beamWidth, weaponId)
	-- No surface normal on the wire, so the burst faces back at the shooter.
	WorldEffects.impact(hitPos, muzzlePos - hitPos, tint)
end

--------------------------------------------------------------------------------
-- Feedback
--------------------------------------------------------------------------------

function VFXController.showDamageNumber(position: Vector3, damage: number, isHeadshot: boolean)
	if typeof(position) ~= "Vector3" or type(damage) ~= "number" then
		return
	end
	WorldEffects.damageNumber(position, damage, isHeadshot == true)
end

function VFXController.showHitmarker(killed: boolean, isHeadshot: boolean)
	ScreenEffects.hitmarker(killed == true, isHeadshot == true)
end

function VFXController.showDamageIndicator(fromPosition: Vector3)
	if typeof(fromPosition) ~= "Vector3" then
		return
	end
	ScreenEffects.damageIndicator(fromPosition)
end

function VFXController.playReloadSound()
	VFXSound.playLocal("Reload")
end

function VFXController.playSwitchSound()
	VFXSound.playLocal("Equip")
end

function VFXController.playEmptySound()
	VFXSound.playLocal("Empty")
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function onHeartbeat()
	local now = os.clock()
	EffectPool.step(now)
	ScreenEffects.step(now)
end

function VFXController.init()
	ClientState.init()

	trove:Add(ClientState.ShotFired:Connect(VFXController.playRemoteShot))

	trove:Add(ClientState.HitConfirmed:Connect(function(payload)
		VFXController.showHitmarker(payload.killed, payload.isHeadshot)
		if payload.hitPos then
			VFXController.showDamageNumber(payload.hitPos, payload.damage, payload.isHeadshot)
		end
	end))

	trove:Add(ClientState.DamageTaken:Connect(function(payload)
		if payload.fromPosition then
			VFXController.showDamageIndicator(payload.fromPosition)
		end
		VFXSound.playLocal("Hurt")
	end))
end

function VFXController.start()
	-- Pools are built here rather than in init() so ~150 instance creations do
	-- not sit inside the synchronous boot pass.
	trove:Add(VFXSound.setup(SOUNDS))
	trove:Add(WorldEffects.setup())
	trove:Add(RunService.Heartbeat:Connect(onHeartbeat))
end

function VFXController.stop()
	EffectPool.clear()
	ScreenEffects.teardown()
	WorldEffects.teardown()
	VFXSound.teardown()
	trove:Clean()
end

return VFXController
