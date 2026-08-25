--!nonstrict
--[[
	WeaponState.luau
	Server-owned ammunition, reload and spray state — one entry per player, per
	weapon.

	The magazine lives here and nowhere else. The client keeps its own count so
	the HUD can react on the same frame as the trigger, but that number is a
	prediction: every shot is spent against this table and the corrected value is
	pushed back over AmmoSync. A client that lies about its magazine gets its
	shots dropped, not its magazine believed.

	Timestamps are supplied by the caller rather than read from a clock here, so
	one handler can gate the fire rate, the spray reset and the reload against a
	single consistent `now` instead of three slightly different ones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local SprayPatterns = require(Shared.Config.SprayPatterns)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local WeaponState = {}

export type Entry = {
	mag: number,
	reloadingUntil: number,
	lastShotAt: number,
	sprayIndex: number,
	lastSeq: number,
	reloadToken: number,
}

-- "Has never fired." Any real timestamp minus this exceeds every spray reset
-- window and every fire-rate interval, which is what makes the first shot of a
-- life start the recoil pattern at index 1 and never be gated.
local NEVER = -math.huge

-- Slack on the fire-rate gate. A client schedules shots on its own render loop
-- and the network adds jitter on top, so consecutive requests arrive a frame
-- early about as often as a frame late; without this the server would eat
-- roughly one rifle shot in six from a player doing nothing wrong. Sustained
-- rate is capped by the ShootRequest rate limit, not by this number, so the
-- slack cannot be spent as a permanent fire-rate increase.
local FIRE_RATE_GRACE = 0.015

local states: { [Player]: { [string]: Entry } } = {}

local function freshEntry(weaponId: string): Entry
	local weapon = WeaponConfig.get(weaponId)
	return {
		mag = if weapon then weapon.magSize else 0,
		reloadingUntil = 0,
		lastShotAt = NEVER,
		sprayIndex = 0,
		lastSeq = 0,
		reloadToken = 0,
	}
end

-- The entry for a player who is already being tracked, without creating one.
-- Used by the paths that must not resurrect state for a player who has left.
local function existingEntry(player: Player, weaponId: string): Entry?
	local perPlayer = states[player]
	return perPlayer and perPlayer[weaponId] or nil
end

--[[
	The state for one weapon, created on first access so a caller never has to
	check for nil.
]]
function WeaponState.get(player: Player, weaponId: string): Entry
	local perPlayer = states[player]
	if not perPlayer then
		perPlayer = {}
		states[player] = perPlayer
	end

	local entry = perPlayer[weaponId]
	if not entry then
		entry = freshEntry(weaponId)
		perPlayer[weaponId] = entry
	end

	return entry
end

--[[
	Full magazines, spray index 0, sequence counter 0. Called on every spawn:
	a life always starts with a fresh loadout, and resetting the sequence counter
	here is safe because the client's counter only ever moves forward.
]]
function WeaponState.reset(player: Player)
	local perPlayer = {}
	for _, weaponId in WeaponConfig.Order do
		perPlayer[weaponId] = freshEntry(weaponId)
	end
	states[player] = perPlayer
end

function WeaponState.clear(player: Player)
	states[player] = nil
end

function WeaponState.isReloading(player: Player, weaponId: string, now: number): boolean
	local entry = existingEntry(player, weaponId)
	return entry ~= nil and entry.reloadingUntil > now
end

--[[
	Spend one round.

	Returns (false, 0) when the shot is not owed: empty magazine, mid-reload, or
	faster than the weapon's fire rate. On success returns the spray index the
	shot was fired at, which is what the caller feeds to
	SprayPatterns.getServerSpreadDeg.
]]
function WeaponState.consumeShot(player: Player, weaponId: string, now: number): (boolean, number)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return false, 0
	end

	local entry = WeaponState.get(player, weaponId)

	if entry.reloadingUntil > now then
		return false, 0
	end

	if entry.mag <= 0 then
		return false, 0
	end

	local sinceLastShot = now - entry.lastShotAt
	if sinceLastShot < weapon.fireRate - FIRE_RATE_GRACE then
		return false, 0
	end

	entry.sprayIndex = SprayPatterns.nextIndex(weaponId, entry.sprayIndex, sinceLastShot, weapon.sprayResetTime)
	entry.mag -= 1
	entry.lastShotAt = now

	return true, entry.sprayIndex
end

--[[
	Start a reload. Returns (started, token); the token identifies this
	particular reload so the timer that finishes it can be told apart from one
	left over by a cancelled reload.

	A reload of a full magazine is refused rather than accepted-and-ignored: the
	client uses the AmmoSync that follows a successful start to play its reload
	animation, and animating a reload that never happened desyncs the HUD.
]]
function WeaponState.beginReload(player: Player, weaponId: string, now: number): (boolean, number)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return false, 0
	end

	local entry = WeaponState.get(player, weaponId)
	if entry.reloadingUntil > now or entry.mag >= weapon.magSize then
		return false, 0
	end

	entry.reloadingUntil = now + weapon.reloadTime
	entry.reloadToken += 1

	return true, entry.reloadToken
end

--[[
	Complete a reload. `token` is optional; when given, a token that no longer
	matches means the reload it belonged to was cancelled (weapon switch, death,
	respawn) and the magazine is left alone.

	Returns whether the magazine was actually refilled, so the caller only pushes
	an AmmoSync when something changed.
]]
function WeaponState.finishReload(player: Player, weaponId: string, token: number?): boolean
	local weapon = WeaponConfig.get(weaponId)
	local entry = existingEntry(player, weaponId)
	if not weapon or not entry then
		return false
	end

	if entry.reloadingUntil <= 0 then
		return false
	end

	if token ~= nil and token ~= entry.reloadToken then
		return false
	end

	entry.mag = weapon.magSize
	entry.reloadingUntil = 0
	-- A fresh magazine restarts the recoil pattern; carrying the old index over
	-- would put the first shot after a reload at full spray.
	entry.sprayIndex = 0

	return true
end

--[[
	Abandon a reload in flight, leaving the magazine where it was. Bumping the
	token orphans the timer the cancelled reload scheduled, so it cannot come
	back later and complete a *different* reload early.
]]
function WeaponState.cancelReload(player: Player, weaponId: string)
	local entry = existingEntry(player, weaponId)
	if entry then
		entry.reloadingUntil = 0
		entry.reloadToken += 1
	end
end

function WeaponState.cancelAllReloads(player: Player)
	local perPlayer = states[player]
	if not perPlayer then
		return
	end

	for weaponId in perPlayer do
		WeaponState.cancelReload(player, weaponId)
	end
end

--[[
	Commit an accepted shot's sequence number. Every later shot on this weapon
	must carry a strictly larger one, which is what makes a captured ShootRequest
	worthless when it is replayed.
]]
function WeaponState.recordSeq(player: Player, weaponId: string, seq: number)
	local entry = WeaponState.get(player, weaponId)
	if seq > entry.lastSeq then
		entry.lastSeq = seq
	end
end

return WeaponState
