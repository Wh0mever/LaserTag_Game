--!nonstrict
--[[
	IdleTracker.luau
	Who has stopped playing, decided from position samples alone.

	An idle player in a team mode costs more than their own experience. They are
	free kills for the other side, they make it seven against eight, they raise
	the kill target for BOTH teams (it scales off the larger roster, and never
	falls again once raised), and they collect the end-of-match payout for
	standing still — which quietly breaks the economy's assumption that coins
	come from playing.

	Pure — no Roblox API, no clock, no Player — so the awkward parts are
	testable off Roblox. Positions are {x, y, z} tables and `now` is supplied by
	the caller, exactly as MapDefs and MatchStateMachine work.

	WHAT COUNTS AS MOVING
	A delta below `moveEpsilon` is standing still: physics jitter and the sway of
	a character doing nothing are both well under a stud.

	A delta ABOVE `maxStep` is a teleport, not movement, and deliberately does
	NOT count as activity. This is the case that makes position sampling work at
	all: a player being farmed at their spawn respawns every few seconds, and
	each respawn moves them a hundred studs. Counting that would make the most
	obviously idle player in the match look like the busiest one. The tracker
	re-baselines to the new spot and keeps the clock running.

	Between the two is walking, which is activity.

	Explicit signals — firing a shot — go through `markActive`, so a marksman
	holding an angle without moving is not mistaken for an absent player. That
	matters here specifically: the Arc Lance is designed to be played by holding
	a lane, and punishing exactly the playstyle the weapon exists for would be a
	own goal.
]]

local IdleTracker = {}

IdleTracker.Actions = {
	Warn = "warn",
	Remove = "remove",
}

IdleTracker.DEFAULTS = {
	-- Studs. Below this the player has not moved.
	moveEpsilon = 2,
	-- Studs in one sample. Above this it is a teleport rather than a walk.
	maxStep = 40,
	-- Seconds of no activity before the player is told, and then removed.
	warnAfter = 45,
	removeAfter = 75,
}

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPosition(value: any): boolean
	return type(value) == "table" and isFiniteNumber(value.x) and isFiniteNumber(value.y) and isFiniteNumber(value.z)
end

local function distance(a, b): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

--[[
	A fresh tracker. `config` may override any of DEFAULTS; a non-numeric or
	non-positive override falls back, so a bad config cannot produce a tracker
	that removes everybody on the first tick.
]]
function IdleTracker.new(config: { [string]: any }?)
	local resolved = {}
	for key, fallback in IdleTracker.DEFAULTS do
		local override = config and config[key]
		resolved[key] = if isFiniteNumber(override) and override > 0 then override else fallback
	end

	-- A warn threshold at or past the removal one would mean nobody is ever
	-- warned before being removed, which is the one thing this must not do.
	if resolved.warnAfter >= resolved.removeAfter then
		resolved.warnAfter = IdleTracker.DEFAULTS.warnAfter
		resolved.removeAfter = IdleTracker.DEFAULTS.removeAfter
	end

	return { config = resolved, entries = {} }
end

local function entryFor(tracker, id, now)
	local entry = tracker.entries[id]
	if not entry then
		entry = { lastActiveAt = now, position = nil, warned = false }
		tracker.entries[id] = entry
	end
	return entry
end

--[[
	Record that `id` did something that only a present player does.
	Clears the warning latch, so a player who comes back and drifts off again is
	warned a second time rather than removed without notice.
]]
function IdleTracker.markActive(tracker, id: any, now: number)
	if id == nil or not isFiniteNumber(now) then
		return
	end

	local entry = entryFor(tracker, id, now)
	entry.lastActiveAt = now
	entry.warned = false
end

--[[
	Feed one position sample. `position` may be nil — a dead player between
	respawns has no character — in which case nothing is learned and the clock
	simply keeps running, which is the correct reading of "cannot be seen to be
	doing anything".
]]
function IdleTracker.observe(tracker, id: any, position: any, now: number)
	if id == nil or not isFiniteNumber(now) then
		return
	end

	local entry = entryFor(tracker, id, now)
	if not isPosition(position) then
		return
	end

	local previous = entry.position
	entry.position = { x = position.x, y = position.y, z = position.z }

	if not previous then
		-- First sighting: nothing to compare against, and the entry was created
		-- with `now` as its last activity, so they start with a clean slate.
		return
	end

	local moved = distance(previous, position)
	if moved > tracker.config.maxStep then
		-- A teleport: a respawn, a match placement, a portal. Re-baselined
		-- above; deliberately not activity.
		return
	end

	if moved >= tracker.config.moveEpsilon then
		entry.lastActiveAt = now
		entry.warned = false
	end
end

--[[
	Start `id` fresh at `now`, discarding any position history. Used when a
	player enters a match: their previous whereabouts say nothing about whether
	they are playing this one.
]]
function IdleTracker.reset(tracker, id: any, now: number)
	if id == nil or not isFiniteNumber(now) then
		return
	end
	tracker.entries[id] = { lastActiveAt = now, position = nil, warned = false }
end

function IdleTracker.forget(tracker, id: any)
	if id ~= nil then
		tracker.entries[id] = nil
	end
end

function IdleTracker.idleSeconds(tracker, id: any, now: number): number
	local entry = tracker.entries[id]
	if not entry or not isFiniteNumber(now) then
		return 0
	end
	return math.max(now - entry.lastActiveAt, 0)
end

--[[
	Seconds until `id` is removed, for a warning that says how long is left.
	Zero once they are due.
]]
function IdleTracker.secondsUntilRemoval(tracker, id: any, now: number): number
	local entry = tracker.entries[id]
	if not entry then
		return tracker.config.removeAfter
	end
	return math.max(tracker.config.removeAfter - IdleTracker.idleSeconds(tracker, id, now), 0)
end

--[[
	What to do about each tracked id, as { {id, action} }.

	A player past `removeAfter` is removed whether or not they were warned: a
	sample can be missed, and the alternative is somebody idling forever because
	the tick that should have warned them never ran. Warnings latch, so a player
	is told once per idle stretch rather than every second.

	The caller is expected to `forget` anyone it removes.
]]
function IdleTracker.step(tracker, now: number): { { id: any, action: string } }
	local actions = {}
	if not isFiniteNumber(now) then
		return actions
	end

	for id, entry in tracker.entries do
		local idle = math.max(now - entry.lastActiveAt, 0)

		if idle >= tracker.config.removeAfter then
			table.insert(actions, { id = id, action = IdleTracker.Actions.Remove })
		elseif idle >= tracker.config.warnAfter and not entry.warned then
			entry.warned = true
			table.insert(actions, { id = id, action = IdleTracker.Actions.Warn })
		end
	end

	return actions
end

return IdleTracker
