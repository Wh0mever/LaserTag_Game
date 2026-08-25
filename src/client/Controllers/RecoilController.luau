--!nonstrict
--[[
	RecoilController.luau
	Owns the client's recoil pattern: which shot of the spray we are on, the kick
	that shot is worth, and the decaying "punch" the viewmodel animates against.

	Determinism is the whole point. Shot N of a spray always produces exactly
	SprayPatterns.getKick(weaponId, N) — no randomness anywhere in this file — so
	a player can learn the pattern and pull down against it. The randomness that
	decides whether a sprayed shot actually connects lives on the server
	(SprayPatterns.getServerSpreadDeg), where a client cannot see or cancel it.

	The spray index is advanced with exactly the rule the server uses in
	Combat/WeaponState.consumeShot — SprayPatterns.nextIndex against the same
	sprayResetTime — so the kick the player fights matches the cone the server
	rolled for that same shot. Any divergence here would make the pattern
	unlearnable, which is worse than no pattern at all.

	Applying the kick is CameraController's job; this module only decides the
	numbers and hands them over.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local CameraController = require(script.Parent.CameraController)
local ClientState = require(script.Parent.Parent.ClientState)
local Signal = require(Shared.Util.Signal)
local SprayPatterns = require(Shared.Config.SprayPatterns)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local RecoilController = {}
-- After CameraController (3), which owns the offset this module pushes into.
RecoilController.Priority = 6

-- The viewmodel punch is a cosmetic overlay on top of the camera kick, so it
-- settles much faster than the aim does — the gun snaps back to the hip while
-- the crosshair is still walking down.
local PUNCH_DECAY = 11
-- Studs of viewmodel kick per degree of camera kick. Tuned against the rifle's
-- ~1.5 degree peak so a full-auto burst reads as a visible shudder rather than
-- the gun leaving the screen.
local PUNCH_PER_DEGREE = 0.055
-- Hard ceiling on the accumulated punch. A held rifle burst settles near 0.13
-- (one shot's 0.088 against an exp(-11 * 0.1) decay per shot); the ceiling only
-- exists so a hypothetical faster weapon cannot walk the gun off screen.
local PUNCH_CEILING = 0.3

-- "Has never fired." Any real timestamp minus this exceeds every spray reset
-- window, so the first shot of a life always starts the pattern at index 1.
local NEVER = -math.huge

local trove = Trove.new()

-- weaponId -> {index, lastShotAt}. Per weapon, because switching guns must not
-- carry the rifle's spray depth onto the pistol.
local spray: { [string]: { index: number, lastShotAt: number } } = {}

local punch = 0
local punchAt = 0

-- (pitchDeg, yawDeg, shotIndex) for every shot. The HUD crosshair listens to
-- this so its bloom animates on the same frame the gun kicks.
RecoilController.Kicked = Signal.new()

local function entryFor(weaponId: string)
	local entry = spray[weaponId]
	if not entry then
		entry = { index = 0, lastShotAt = NEVER }
		spray[weaponId] = entry
	end
	return entry
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Register a shot: advances the spray, pushes the kick into the camera and
	returns the 1-based pattern index the shot was fired at.

	`now` should be the same timestamp the caller used to gate the fire rate, so
	the spray reset and the fire-rate gate agree on when the shot happened.
]]
function RecoilController.onShot(weaponId: string, now: number?): number
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return 0
	end

	local at = now or os.clock()
	local entry = entryFor(weaponId)
	local index = SprayPatterns.nextIndex(weaponId, entry.index, at - entry.lastShotAt, weapon.sprayResetTime)

	entry.index = index
	entry.lastShotAt = at

	local kick = SprayPatterns.getKick(weaponId, index)
	CameraController.addRecoilOffset(kick.pitch, kick.yaw, weapon.recoilRecovery)

	-- Accumulate onto whatever is left of the previous shot's punch, not onto the
	-- raw stored value, or a fast burst would stack decayed kicks as if fresh.
	punch = math.min(
		RecoilController.getPunch() + (math.abs(kick.pitch) + math.abs(kick.yaw)) * PUNCH_PER_DEGREE,
		PUNCH_CEILING
	)
	punchAt = at

	RecoilController.Kicked:Fire(kick.pitch, kick.yaw, index)
	return index
end

--[[
	The camera's current accumulated recoil offset in degrees, as
	(pitch, yaw). Read by ViewmodelController to counter-rotate the gun and by the
	HUD to offset the crosshair.
]]
function RecoilController.getOffset(): (number, number)
	return CameraController.getRecoilOffset()
end

--[[
	Decaying 0..PUNCH_CEILING kick magnitude, in studs, for the viewmodel.
	Evaluated lazily from the last shot's timestamp so this controller needs no
	per-frame binding of its own.
]]
function RecoilController.getPunch(): number
	if punch <= 0 then
		return 0
	end
	return punch * math.exp(-PUNCH_DECAY * (os.clock() - punchAt))
end

function RecoilController.getSprayIndex(weaponId: string): number
	return entryFor(weaponId).index
end

--[[
	The index the NEXT shot would land on, without advancing anything. Lets a
	crosshair preview the coming bloom before the trigger is pulled.
]]
function RecoilController.peekIndex(weaponId: string, now: number?): number
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return 1
	end

	local entry = entryFor(weaponId)
	return SprayPatterns.nextIndex(weaponId, entry.index, (now or os.clock()) - entry.lastShotAt, weapon.sprayResetTime)
end

--[[
	Crosshair bloom in degrees: the server's inaccuracy cone for where the spray
	currently sits, floored at the weapon's base spread so a resting crosshair is
	never drawn as a perfect point.

	The reset is applied here as well as in nextIndex because a player who has
	stopped firing must see the crosshair tighten immediately, even though no shot
	has advanced the stored index.
]]
function RecoilController.getBloomDeg(weaponId: string): number
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return 0
	end

	local entry = entryFor(weaponId)
	if os.clock() - entry.lastShotAt > weapon.sprayResetTime then
		return weapon.baseSpreadDeg
	end

	return math.max(weapon.baseSpreadDeg, SprayPatterns.getServerSpreadDeg(weaponId, entry.index))
end

--[[
	Restart the pattern. Mirrors WeaponState.finishReload, which zeroes the spray
	index so the first shot out of a fresh magazine is not at full bloom. Omit
	`weaponId` to reset every weapon (respawn).
]]
function RecoilController.resetSpray(weaponId: string?)
	if weaponId then
		local entry = entryFor(weaponId)
		entry.index = 0
		entry.lastShotAt = NEVER
		return
	end

	for _, entry in spray do
		entry.index = 0
		entry.lastShotAt = NEVER
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function RecoilController.init()
	ClientState.init()

	for _, id in WeaponConfig.Order do
		entryFor(id)
	end

	local function clearAll()
		RecoilController.resetSpray()
		punch = 0
		punchAt = 0
	end

	-- The server calls WeaponState.reset on every spawn; matching it here keeps
	-- the first shot of a new life at pattern index 1 on both sides.
	trove:Add(ClientState.Respawned:Connect(clearAll))
	trove:Add(ClientState.Died:Connect(clearAll))
end

function RecoilController.stop()
	trove:Clean()
	RecoilController.Kicked:DisconnectAll()
end

return RecoilController
