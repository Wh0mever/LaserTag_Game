--!nonstrict
--[[
	PairLimiter.spec.luau
	How many times the same player can be paid for killing the same victim in one
	match.

	Two accounts can trade kills as fast as the respawn timer allows. Nothing
	about the kill is illegitimate one at a time, so the limit is on the pair:
	past a point the same victim is worth nothing. Kills against a spread of
	different enemies, which is what a real team match produces, never reach it.

	The limit only means something when the killer HAS other enemies to spread
	the kills over. In a 1v1 every kill of the match is the same pair, an honest
	winner takes as many as the score limit asks for, and cutting their pay off
	part-way through would punish exactly the player it is not aimed at.
]]

local EconomyConfig = require("../src/shared/Config/EconomyConfig")
local GameConfig = require("../src/shared/Config/GameConfig")
local MatchStateMachine = require("../src/server/Match/MatchStateMachine")
local PairLimiter = require("../src/server/Match/PairLimiter")

return function(t)
	t.equal(
		PairLimiter.DEFAULT_LIMIT,
		EconomyConfig.MAX_PAID_KILLS_PER_PAIR,
		"the module's default tracks EconomyConfig"
	)
	t.expect(EconomyConfig.MAX_PAID_KILLS_PER_PAIR >= 5, "an honest duel is paid for a fair number of kills")
	t.expect(
		EconomyConfig.MAX_PAID_KILLS_PER_PAIR < MatchStateMachine.scoreLimitFor(2, GameConfig.SCORE_LIMIT_PER_PLAYER),
		"but a farm is cut off well inside the score limit of a 2v2, the smallest match it applies to"
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

	-- A killer with a single enemy has nobody else to farm, so the pair is the
	-- whole match and only the match's own score limit bounds it.
	t.equal(PairLimiter.MIN_OPPONENTS, 2, "the limit applies from two enemies up")
	local duel = PairLimiter.new(3)
	local duelKills = MatchStateMachine.scoreLimitFor(1, GameConfig.SCORE_LIMIT_PER_PLAYER)
	t.expect(duelKills > EconomyConfig.MAX_PAID_KILLS_PER_PAIR, "a 1v1 is won with more kills than the pair limit")
	local unpaid = 0
	for _ = 1, duelKills do
		if not PairLimiter.record(duel, ann, bob, 1) then
			unpaid += 1
		end
	end
	t.equal(unpaid, 0, "every kill of a 1v1 winner is paid, however many there are")
	t.equal(PairLimiter.count(duel, ann, bob), duelKills, "and they are still counted")

	-- The count carries over when the match grows: it is the same match.
	t.expect(not PairLimiter.record(duel, ann, bob, 2), "a second enemy arriving puts the pair limit back in force")
	t.expect(PairLimiter.record(duel, ann, cat, 2), "on the pair only")

	local team = PairLimiter.new(3)
	for kill = 1, 3 do
		t.expect(PairLimiter.record(team, ann, bob, 3), `kill {kill} of one of three enemies is paid`)
	end
	t.expect(not PairLimiter.record(team, ann, bob, 3), "the fourth of the same one is not")

	-- Unknown is treated as the strict case, so a caller that cannot say never
	-- opens the limit by mistake.
	local unknown = PairLimiter.new(1)
	PairLimiter.record(unknown, ann, bob)
	t.expect(not PairLimiter.record(unknown, ann, bob), "no head count given: the limit applies")
	t.expect(not PairLimiter.record(unknown, ann, bob, "one"), "and so does a head count that is not a number")
end
