--!nonstrict
--[[
	PairLimiter.luau
	How many kills of the same victim by the same killer are paid in one match.

	Pure — no Roblox API — so it is testable off Roblox (tests/PairLimiter.spec.luau).
	Ids are whatever the caller has (the runtime passes Player objects); they are
	only ever used as table keys.

	Two accounts in a 1v1 can trade kills as fast as the respawn timer lets them,
	and every kill on its own is legitimate. So the limit is on the PAIR: past
	`limit` kills of one victim by one killer the kills still score for the team,
	but they stop paying coins and stop counting towards lifetime kills. In a real
	match the kills spread over several enemies and the limit is never reached.

	The counter is per match and is the caller's to reset when a new one starts.
]]

local PairLimiter = {}

-- Mirrors EconomyConfig.MAX_PAID_KILLS_PER_PAIR. This module cannot require the
-- config (a Roblox require path would stop the off-Roblox runner loading it),
-- so the spec asserts the two still agree.
PairLimiter.DEFAULT_LIMIT = 12

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
]]
function PairLimiter.record(limiter: Limiter, killer: any, victim: any): boolean
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
	return total <= limiter.limit
end

function PairLimiter.reset(limiter: Limiter)
	table.clear(limiter.counts)
end

return PairLimiter
