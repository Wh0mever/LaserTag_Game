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
	-- Where the fire-rate schedule stands: the slot the last accepted shot
	-- occupied. Not when it arrived (see MAX_LATE).
	lastShotAt: number,
	-- When the last accepted shot actually arrived, which is what the spray
	-- reset measures its pause against.
	lastArrivalAt: number,
	sprayIndex: number,
	lastSeq: number,
	reloadToken: number,
}

-- "Has never fired." Any real timestamp minus this exceeds every spray reset
-- window and every fire-rate interval, which is what makes the first shot of a
-- life start the recoil pattern at index 1 and never be gated.
local NEVER = -math.huge

--[[
	Slack on the fire-rate gate. A client schedules shots on its own render loop
	and the network adds jitter on top, so consecutive requests arrive a frame
	early about as often as a frame late; with the slack under one 60 Hz frame
	the server dropped about one honest rifle shot in five at 20 ms of jitter.
	Two frames covers it.

	The slack is not a faster weapon. The gate is anchored to the cadence, not to
	when packets happened to arrive: an accepted shot occupies the slot it was
	due in, so an early one borrows from the next interval instead of shifting the
	schedule earlier. However the arrivals are spaced, the rate that can be
	sustained never exceeds one shot per fireRate.
]]
local FIRE_RATE_GRACE = 0.04

--[[
	How far behind the schedule a shot may arrive before the schedule moves for
	it.

	A phone's connection holds a packet up now and then, and the next one, sent on
	time, lands closer behind it than a rifle's interval. If a late shot were
	booked where it arrived, the honest shot after it would be early against that
	booking and refused; at 60 to 100 ms of delay that was one shot in five. So a
	shot that arrives late still occupies the slot it was due in, and only
	lateness beyond this pushes the schedule later.

	It also bounds the catch-up. A shot due long ago (the client sat quiet, or the
	link stalled and delivered what it had queued) is booked this far before its
	arrival, so the shots behind it may arrive that much ahead of the cadence.
	Together with FIRE_RATE_GRACE no shot lands more than 0.19 s before its slot:
	for the rifle that is one extra round at the start of a burst, and a stalled
	link's queue is honoured only that far. Keep the sum under twice the rifle's
	interval or it gains a second one. The rate itself is untouched: a slot is a
	full interval wide.
]]
local MAX_LATE = 0.15

-- Extra time past a weapon's sprayResetTime before the server treats a pause as
-- a real one. The client resets on its own gap between shots; the server sees
-- that gap plus network jitter, so without this a burst the client draws as
-- unbroken restarts on the server about half the time it sits near the boundary.
local SPRAY_RESET_GRACE = 0.05

-- How early a shot may arrive and still find the reload finished. The client
-- starts its reload one trip before the server hears of it and its first shot
-- after it takes one trip back, so the two land on the same server instant
-- give or take jitter; a shot exactly on the line is refused half the time
-- without this.
local RELOAD_GRACE = 0.08

-- The same tolerance for the weapon-swap lockout. The client waits out
-- WeaponConfig.SWITCH_TIME from the key press; the server measures from when the
-- request arrived and to when the shot arrived, and both had a trip to make.
local SWITCH_GRACE = 0.08

local states: { [Player]: { [string]: Entry } } = {}

-- When each player last changed weapon by asking the server to, on the server's
-- clock. Kept beside the per-weapon entries rather than inside them: the swap is
-- a fact about the player, and the entries are keyed by weapon id.
local switchedAt: { [Player]: number } = {}

local function freshEntry(weaponId: string): Entry
	local weapon = WeaponConfig.get(weaponId)
	return {
		mag = if weapon then weapon.magSize else 0,
		reloadingUntil = 0,
		lastShotAt = NEVER,
		lastArrivalAt = NEVER,
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
	local previous = states[player]
	local perPlayer = {}

	for _, weaponId in WeaponConfig.Order do
		local entry = freshEntry(weaponId)

		-- Everything else starts over on a new life, but the accepted sequence
		-- number carries across: the client's counter never restarts, so zeroing
		-- this would both re-open a window for replaying a captured shot from the
		-- previous life and leave the client unable to tell a correction from a
		-- sync that predates its latest shots.
		local carried = previous and previous[weaponId]
		if carried then
			entry.lastSeq = carried.lastSeq
			-- The reload token carries across for the same reason, in the other
			-- direction: a timer scheduled on the previous life is still pending
			-- and holds the token it was given. Restarting the count at zero let
			-- the new life's first reload hand out that same number, and the old
			-- timer then finished it early. One past the old value is a number no
			-- pending timer can hold.
			entry.reloadToken = carried.reloadToken + 1
		end

		perPlayer[weaponId] = entry
	end

	states[player] = perPlayer
	-- A fresh spawn owes nothing to the last life's swap: the client clears its
	-- own lockout on respawn, so an honest player may fire straight away.
	switchedAt[player] = nil
end

function WeaponState.clear(player: Player)
	states[player] = nil
	switchedAt[player] = nil
end

--[[
	Note that the player asked to change weapon, at `now`. Firing is refused for
	most of WeaponConfig.SWITCH_TIME afterwards. Without it the per-weapon fire
	rates are independent, so a modified client could swap weapons and fire each
	one in the same frame and land all three shots at once.
]]
function WeaponState.markSwitch(player: Player, now: number)
	switchedAt[player] = now
end

function WeaponState.isReloading(player: Player, weaponId: string, now: number): boolean
	local entry = existingEntry(player, weaponId)
	return entry ~= nil and entry.reloadingUntil > now
end

--[[
	Finish a reload whose time has come but whose timer has not run yet.

	The timer is a task.delay, which fires on the first frame after the reload's
	time is up. A shot or a reload request arriving inside that gap saw a
	magazine that was still empty and was refused for it. Settling here means the
	state is right whenever it is read; the timer then finds nothing left to do
	and CombatService's next AmmoSync carries the news.
]]
local function settleReload(entry: Entry, weapon: any, now: number)
	if entry.reloadingUntil > 0 and entry.reloadingUntil - RELOAD_GRACE <= now then
		entry.mag = weapon.magSize
		entry.reloadingUntil = 0
		entry.sprayIndex = 0
	end
end

--[[
	Spend one round.

	Returns (false, 0) when the shot is not owed: empty magazine, mid-reload,
	just after a weapon swap, or faster than the weapon's fire rate. On success
	returns the spray index the shot was fired at, which is what the caller feeds
	to SprayPatterns.getServerSpreadDeg.
]]
function WeaponState.consumeShot(player: Player, weaponId: string, now: number): (boolean, number)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return false, 0
	end

	local entry = WeaponState.get(player, weaponId)

	settleReload(entry, weapon, now)
	if entry.reloadingUntil > 0 then
		return false, 0
	end

	if entry.mag <= 0 then
		return false, 0
	end

	local swapped = switchedAt[player]
	if swapped and now - swapped < WeaponConfig.SWITCH_TIME - SWITCH_GRACE then
		return false, 0
	end

	local dueAt = entry.lastShotAt + weapon.fireRate
	if now < dueAt - FIRE_RATE_GRACE then
		return false, 0
	end

	-- The pause is measured between arrivals, as the client measures its own
	-- between shots. The schedule's slot would overstate it by up to MAX_LATE.
	-- Never negative: a clock that steps back would read as "fired in the past".
	local sinceLastShot = math.max(now - entry.lastArrivalAt, 0)
	entry.sprayIndex =
		SprayPatterns.nextIndex(weaponId, entry.sprayIndex, sinceLastShot, weapon.sprayResetTime, SPRAY_RESET_GRACE)
	entry.mag -= 1
	entry.lastArrivalAt = now
	entry.lastShotAt = math.max(dueAt, now - MAX_LATE)

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
	settleReload(entry, weapon, now)
	if entry.reloadingUntil > 0 or entry.mag >= weapon.magSize then
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
