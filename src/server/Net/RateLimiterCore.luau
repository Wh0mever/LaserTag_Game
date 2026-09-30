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
		violations    how many times this key has hit the limit recently (see
		              DEFAULT_VIOLATION_DECAY_SECONDS) or since the last reset
		lastViolationAt `now` of the newest violation, what the decay measures from
		cooldownUntil `now` value before which every request is dropped flat
]]

local RateLimiterCore = {}

export type Config = {
	maxRequests: number,
	windowSeconds: number,
	cooldownSeconds: number?,
	violationDecaySeconds: number?,
}

export type Entry = {
	timestamps: { number },
	violations: number,
	lastViolationAt: number?,
	cooldownUntil: number,
}

--[[
	How long a violation is remembered. Five of them end in a kick, and they used
	to be kept for the whole session: a player who tapped a button too fast a few
	times an evening, minutes apart, was eventually disconnected for it. A
	violation says something about the last minute of a player's behaviour and
	nothing about the last hour. Abuse that keeps going is unaffected, because
	each violation is recent when the next arrives.
]]
RateLimiterCore.DEFAULT_VIOLATION_DECAY_SECONDS = 60

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
		local decay = config.violationDecaySeconds or RateLimiterCore.DEFAULT_VIOLATION_DECAY_SECONDS
		if entry.lastViolationAt and now - entry.lastViolationAt > decay then
			entry.violations = 0
		end
		entry.violations += 1
		entry.lastViolationAt = now

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
	Text that is safe to put in a log line when a client chose it.

	A rejection reason can carry whatever the client sent, so it is cut to
	`maxLength` and stripped of control characters: without the first one packet
	could write a page of console, and without the second a newline inside it
	could forge a second line that looks like the server's own.
]]
function RateLimiterCore.cleanForLog(text: any, maxLength: number): string
	local cleaned = string.sub(tostring(text), 1, maxLength)
	cleaned = string.gsub(cleaned, "%c", "?")
	return cleaned
end

--[[
	A budget of one log line per key per interval.

	Every rejected request used to log, and a client can send them as fast as its
	rate limit lets it: the console filled with one player's noise and the lines
	that mattered scrolled away. The first rejection in an interval is logged; the
	rest are only counted, and the count comes out with the next line that is
	allowed so nothing is hidden, just summarised.

	Returns (shouldLog, suppressed): `suppressed` is how many were held back since
	the last line that was logged.
]]
function RateLimiterCore.newLogGate(): { [string]: { lastAt: number, suppressed: number } }
	return {}
end

function RateLimiterCore.logGate(gate, key: string, now: number, intervalSeconds: number): (boolean, number)
	local slot = gate[key]
	if not slot then
		gate[key] = { lastAt = now, suppressed = 0 }
		return true, 0
	end

	if now - slot.lastAt < intervalSeconds then
		slot.suppressed += 1
		return false, 0
	end

	local suppressed = slot.suppressed
	slot.lastAt = now
	slot.suppressed = 0
	return true, suppressed
end

--[[
	Forget everything about one key: window, violations and any open cooldown.
]]
function RateLimiterCore.reset(state: State, key: string)
	state.entries[key] = nil
end

return RateLimiterCore
