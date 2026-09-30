--!nonstrict
--[[
	PairLimiter.luau
	How many kills of the same victim by the same killer are paid in one match.

	Pure — no Roblox API — so it is testable off Roblox (tests/PairLimiter.spec.luau).
	Ids are whatever the caller has; they are only ever used as table keys. The
	runtime passes UserIds, not Player objects: leaving and coming back is a new
	Player object, and a count kept against the old one would start again.

	Two accounts can trade kills as fast as the respawn timer lets them, and every
	kill on its own is legitimate. So the limit is on the PAIR: past `limit` kills
	of one victim by one killer the kills still score for the team, but they stop
	paying coins and stop counting towards lifetime kills. In a real match the
	kills spread over several enemies and the limit is never reached.

	It only applies when the killer HAS several enemies to spread them over (see
	MIN_OPPONENTS). Against a single enemy every kill of the match is the same
	pair, so an honest 1v1 winner would be cut off part-way to the score limit; the
	score limit is that match's own bound.

	The counter is per match and is the caller's to reset when a match ends.
]]

local PairLimiter = {}

-- Mirrors EconomyConfig.MAX_PAID_KILLS_PER_PAIR. This module cannot require the
-- config (a Roblox require path would stop the off-Roblox runner loading it),
-- so the spec asserts the two still agree.
PairLimiter.DEFAULT_LIMIT = 12

-- Enemies the killer must be facing for the limit to apply. With fewer, the pair
-- is the whole match and there is nobody else to farm.
PairLimiter.MIN_OPPONENTS = 2

export type Limiter = {
	limit: number,
	-- killer -> victim -> kills so far
	counts: { [any]: { [any]: number } },
}

function PairLimiter.new(limit: number?): Limiter
	local resolved = PairLimiter.DEFAULT_LIMIT
	if type(limit) == "number" and limit == limit and limit >= 0 then
		resolved = limit
	end
	return { limit = resolved, counts = {} }
end

function PairLimiter.count(limiter: Limiter, killer: any, victim: any): number
	local perKiller = limiter.counts[killer]
	return if perKiller then perKiller[victim] or 0 else 0
end

--[[
	Count one kill and say whether it is paid. A kill with no killer or victim, or
	of oneself, is never paid and is not counted.

	`opponents` is how many players the killer's enemy team has right now. Below
	MIN_OPPONENTS the kill is counted but always paid. A caller that cannot say
	leaves it out and gets the limit, never the exemption.
]]
function PairLimiter.record(limiter: Limiter, killer: any, victim: any, opponents: number?): boolean
	if killer == nil or victim == nil or killer == victim then
		return false
	end

	local perKiller = limiter.counts[killer]
	if not perKiller then
		perKiller = {}
		limiter.counts[killer] = perKiller
	end

	local total = (perKiller[victim] or 0) + 1
	perKiller[victim] = total

	if type(opponents) == "number" and opponents < PairLimiter.MIN_OPPONENTS then
		return true
	end
	return total <= limiter.limit
end

function PairLimiter.reset(limiter: Limiter)
	table.clear(limiter.counts)
end

return PairLimiter
