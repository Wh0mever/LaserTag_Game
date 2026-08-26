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
-- SOUND SOURCES
--------------------------------------------------------------------------------
--[[
	Every id below is a real Creator Store asset, and each was checked against
	Roblox's own catalogue before being written here: sound effect rather than
	music, free, published and purchasable. An id that fails any of those loads
	as silence in a published place, and silence is invisible in code review —
	so none of these are guesses.

	Where there was a choice, the pick came from ProSoundEffects: it is Roblox's
	licensed library, which means it is professionally produced and will not
	disappear under moderation. Much of the rest of the audio catalogue is ripped
	from commercial games, and building a published experience on that is a
	takedown waiting to happen.

	  volume  0-10, passed straight to Sound.Volume
	  speed   base Sound.PlaybackSpeed — 1 plays the sample as recorded
	  jitter  random +/- applied to speed on every play, so a sustained burst of
	          the same sample does not phase-lock into a machine tone

	To audition or replace one: open the id on the Creator Store, or swap in
	another `rbxassetid://` value. Nothing outside this table has to change.
]]
local SOUNDS = {
	-- Weapons. The rifle and pistol come from one creator so they sound like
	-- they belong to the same armoury; a mismatched pair reads as two games.
	Rifle = { id = "rbxassetid://8964303934", volume = 0.5, speed = 1, jitter = 0.06 }, -- Laser Assault Rifle Shot
	Pistol = { id = "rbxassetid://8969857660", volume = 0.55, speed = 1.05, jitter = 0.08 }, -- Laser Pistol Shot

	-- Slightly slowed and the loudest of the three: the Lance has to carry
	-- across the map, because knowing a marksman is holding an angle is most of
	-- how you avoid walking into one.
	Lance = { id = "rbxassetid://9118786206", volume = 0.75, speed = 0.9, jitter = 0.03 }, -- Sci-Fi Weapon 5 (ProSoundEffects)

	Impact = { id = "rbxassetid://201858087", volume = 0.35, speed = 1.15, jitter = 0.15 }, -- laser_impact

	-- Two tiers of confirmation: a tick for a hit, something fuller for a kill,
	-- so a player knows which happened without looking away from the fight.
	Hitmarker = { id = "rbxassetid://7167425696", volume = 0.5, speed = 1, jitter = 0.03 }, -- hitmarker
	Kill = { id = "rbxassetid://208341701", volume = 0.7, speed = 1, jitter = 0 }, -- Headshot Hitmarker

	Reload = { id = "rbxassetid://8561502124", volume = 0.5, speed = 1, jitter = 0.04 }, -- laser gun reload
	Equip = { id = "rbxassetid://9118139406", volume = 0.4, speed = 1.1, jitter = 0 }, -- Relay Clicks 23 (ProSoundEffects)

	-- Deliberately dry and mechanical against the energy weapons: an empty
	-- magazine should sound like nothing fired, not like a weak shot.
	Empty = { id = "rbxassetid://9116321197", volume = 0.4, speed = 1, jitter = 0 }, -- Locking Wrench 10 (ProSoundEffects)

	Hurt = { id = "rbxassetid://78164261999660", volume = 0.45, speed = 1, jitter = 0.08 }, -- Zapped Power
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
