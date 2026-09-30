--!nonstrict
--[[
	PairLimiter.spec.luau
	How many times the same player can be paid for killing the same victim in one
	match.

	Two accounts in a 1v1 can trade kills as fast as the respawn timer allows.
	Nothing about the kill is illegitimate one at a time, so the limit is on the
	pair: past a point the same victim is worth nothing. Kills against a spread of
	different enemies, which is what a real team match produces, never reach it.
]]

local EconomyConfig = require("../src/shared/Config/EconomyConfig")
local PairLimiter = require("../src/server/Match/PairLimiter")

return function(t)
	t.equal(
		PairLimiter.DEFAULT_LIMIT,
		EconomyConfig.MAX_PAID_KILLS_PER_PAIR,
		"the module's default tracks EconomyConfig"
	)
	t.expect(EconomyConfig.MAX_PAID_KILLS_PER_PAIR >= 5, "an honest duel is paid for a fair number of kills")
	t.expect(
		EconomyConfig.MAX_PAID_KILLS_PER_PAIR <= 20,
		"but a farm is cut off well inside the score limit of a two player match"
	)

	local limiter = PairLimiter.new(3)
	local ann, bob, cat = { "ann" }, { "bob" }, { "cat" }

	for kill = 1, 3 do
		t.expect(PairLimiter.record(limiter, ann, bob), `kill {kill} of the same victim is paid`)
	end
	t.expect(not PairLimiter.record(limiter, ann, bob), "the fourth is not")
	t.expect(not PairLimiter.record(limiter, ann, bob), "nor the fifth")
	t.equal(PairLimiter.count(limiter, ann, bob), 5, "every kill is still counted")

	-- The limit belongs to the pair, in one direction.
	t.expect(PairLimiter.record(limiter, ann, cat), "a different victim is paid in full")
	t.expect(PairLimiter.record(limiter, bob, ann), "and so is the victim killing back")
	t.expect(PairLimiter.record(limiter, cat, bob), "and a different killer of the same victim")

	-- A new match starts every pair afresh.
	PairLimiter.reset(limiter)
	t.equal(PairLimiter.count(limiter, ann, bob), 0, "reset forgets the counts")
	t.expect(PairLimiter.record(limiter, ann, bob), "and the pair is paid again")

	-- Misuse does not pay.
	t.expect(not PairLimiter.record(limiter, nil, bob), "a kill with no killer is not a paid kill")
	t.expect(not PairLimiter.record(limiter, ann, nil), "nor one with no victim")
	t.expect(not PairLimiter.record(limiter, ann, ann), "nor killing yourself")

	-- A limit of nothing pays nothing; a bad limit falls back rather than
	-- silently paying every kill.
	local none = PairLimiter.new(0)
	t.expect(not PairLimiter.record(none, ann, bob), "a limit of zero pays no kill")
	local fallback = PairLimiter.new("many")
	for _ = 1, EconomyConfig.MAX_PAID_KILLS_PER_PAIR do
		PairLimiter.record(fallback, ann, bob)
	end
	t.expect(not PairLimiter.record(fallback, ann, bob), "a non-numeric limit falls back to the configured one")
end
