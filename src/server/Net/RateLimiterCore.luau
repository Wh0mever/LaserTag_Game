--!nonstrict
--[[
	RateLimiterCore.luau
	Sliding-window rate limiting policy, with zero Roblox API surface so the whole
	thing can be exercised by the off-Roblox test runner
	(tests/RateLimiterCore.spec.luau). Net/RateLimiter.luau is the thin
	Player-keyed wrapper that supplies the clock and performs the kick.

	Time is injected as `now` instead of being read from a clock: a test has to be
	able to step across a window without sleeping, and the caller must be free to
	choose a monotonic source. Callers on the server pass os.clock() — a wall
	clock that can jump backwards would hand a client a free extra window.

	State layout, per key:
		timestamps    ascending list of accepted request times still in-window
		violations    how many times this key has hit the limit since the last reset
		cooldownUntil `now` value before which every request is dropped flat
]]

local RateLimiterCore = {}

export type Config = {
	maxRequests: number,
	windowSeconds: number,
	cooldownSeconds: number?,
}

export type Entry = {
	timestamps: { number },
	violations: number,
	cooldownUntil: number,
}

export type State = {
	entries: { [string]: Entry },
}

function RateLimiterCore.newState(): State
	return { entries = {} }
end

local function getEntry(state: State, key: string): Entry
	local entry = state.entries[key]
	if not entry then
		entry = { timestamps = {}, violations = 0, cooldownUntil = 0 }
		state.entries[key] = entry
	end
	return entry
end

--[[
	Drop every timestamp that has fallen out of the trailing window, compacting in
	place. The list is written in ascending order, so a single forward pass is
	enough and no allocation is needed on the hot path.
]]
local function prune(entry: Entry, windowStart: number)
	local timestamps = entry.timestamps
	local kept = 0

	for index = 1, #timestamps do
		local timestamp = timestamps[index]
		if timestamp > windowStart then
			kept += 1
			timestamps[kept] = timestamp
		end
	end

	for index = #timestamps, kept + 1, -1 do
		timestamps[index] = nil
	end
end

--[[
	Account for one request.

	Returns (allowed, violation):
	  allowed    the caller may run the action
	  violation  this specific call is what pushed the key over the limit, i.e.
	             it is worth logging and counting towards a kick

	Requests made while a cooldown is open are dropped but deliberately do NOT
	count as fresh violations: a client that keeps hammering during its own
	cooldown would otherwise reach any kick threshold in a single frame, turning
	a burst of lag-induced retries into a disconnect.
]]
function RateLimiterCore.check(state: State, key: string, now: number, config: Config): (boolean, boolean)
	local entry = getEntry(state, key)

	if now < entry.cooldownUntil then
		return false, false
	end

	prune(entry, now - config.windowSeconds)

	if #entry.timestamps >= config.maxRequests then
		entry.violations += 1

		local cooldownSeconds = config.cooldownSeconds
		if cooldownSeconds and cooldownSeconds > 0 then
			entry.cooldownUntil = now + cooldownSeconds
		end

		return false, true
	end

	table.insert(entry.timestamps, now)
	return true, false
end

function RateLimiterCore.violations(state: State, key: string): number
	local entry = state.entries[key]
	return if entry then entry.violations else 0
end

--[[
	Forget everything about one key: window, violations and any open cooldown.
]]
function RateLimiterCore.reset(state: State, key: string)
	state.entries[key] = nil
end

return RateLimiterCore
