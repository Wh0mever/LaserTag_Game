--!nonstrict
--[[
	Payout.spec.luau
	What a player is paid when a match ends, given how long they were in it.

	The award used to depend only on the scoreline: a player seated five seconds
	before the clock ran out, or left alone thirty seconds after an alt account
	disconnected, was paid the same 400 coins as someone who played the ten
	minutes. Two accounts could farm that in a loop. The rule here is that the
	WIN bonus is for having been part of the win.
]]

local EconomyConfig = require("../src/shared/Config/EconomyConfig")
local GameConfig = require("../src/shared/Config/GameConfig")
local Payout = require("../src/server/Match/Payout")

local R = EconomyConfig.REWARDS
local DURATION = GameConfig.MATCH_DURATION

-- A player on the winning side of a match that ran `matchSeconds`, in it for
-- `playedSeconds`.
local function win(playedSeconds: number, matchSeconds: number, reason: string?)
	return Payout.compute({
		winnerTeam = "A",
		teamId = "A",
		reason = reason,
		playedSeconds = playedSeconds,
		matchSeconds = matchSeconds,
		matchDuration = DURATION,
		rewards = R,
		minSeconds = EconomyConfig.MATCH_BONUS_MIN_SECONDS,
	})
end

return function(t)
	t.expect(EconomyConfig.MATCH_BONUS_MIN_SECONDS > 0, "there is a minimum time to be part of a result")
	t.expect(
		EconomyConfig.MATCH_BONUS_MIN_SECONDS < DURATION / 2,
		"and it is a small part of a match, so joining a running game is still worth doing"
	)
	t.equal(
		GameConfig.LATE_JOIN_CUTOFF_SECONDS,
		EconomyConfig.MATCH_BONUS_MIN_SECONDS,
		"nobody is seated who could not yet have earned the bonus"
	)

	--------------------------------------------------------------------------
	-- The ordinary cases stay as they were
	--------------------------------------------------------------------------

	local full = win(DURATION, DURATION)
	t.equal(full.amount, R.MATCH_WIN, "a player who played the whole match and won is paid the win")
	t.equal(full.outcome, "win", "and it is reported as a win")
	t.expect(full.won, "and counts towards their wins")

	local loser = Payout.compute({
		winnerTeam = "B",
		teamId = "A",
		playedSeconds = DURATION,
		matchSeconds = DURATION,
		matchDuration = DURATION,
		rewards = R,
		minSeconds = 60,
	})
	t.equal(loser.amount, R.MATCH_PARTICIPATION, "the losing side is paid for taking part")
	t.equal(loser.outcome, "played", "as a played match")
	t.expect(not loser.won, "which is not a win")

	local draw = Payout.compute({
		winnerTeam = nil,
		teamId = "A",
		playedSeconds = DURATION,
		matchSeconds = DURATION,
		matchDuration = DURATION,
		rewards = R,
		minSeconds = 60,
	})
	t.equal(draw.amount, R.MATCH_DRAW, "a draw pays the draw award")
	t.equal(draw.outcome, "draw", "and is reported as one")
	t.expect(not draw.won, "and is not a win")

	--------------------------------------------------------------------------
	-- Time in the match
	--------------------------------------------------------------------------

	local sniper = win(5, DURATION)
	t.equal(sniper.amount, R.MATCH_PARTICIPATION, "seated five seconds before the end is paid as taking part")
	t.expect(not sniper.won, "and does not get a win they were not there for")

	local justEnough = win(60, DURATION)
	t.equal(justEnough.amount, R.MATCH_WIN, "a minute in the match is enough to have been part of the win")
	t.expect(justEnough.won, "and counts as a win")
	t.equal(win(59, DURATION).amount, R.MATCH_PARTICIPATION, "a second short is not")

	local lateDraw = Payout.compute({
		winnerTeam = nil,
		teamId = "A",
		playedSeconds = 10,
		matchSeconds = DURATION,
		matchDuration = DURATION,
		rewards = R,
		minSeconds = 60,
	})
	t.equal(lateDraw.amount, R.MATCH_PARTICIPATION, "the draw award needs the time too")

	-- A match the score limit ended in forty seconds was played by everybody
	-- there for all of it. The minimum cannot be longer than the match.
	local shortMatch = win(40, 40)
	t.equal(shortMatch.amount, R.MATCH_WIN, "a player there for the whole of a short match is paid the win")
	t.expect(shortMatch.won, "and it counts")
	t.equal(win(20, 40).amount, R.MATCH_PARTICIPATION, "but a joiner who missed half of it is not")

	--------------------------------------------------------------------------
	-- A win handed over by the other side leaving
	--------------------------------------------------------------------------

	local farmed = win(40, 40, "forfeit")
	t.equal(
		farmed.amount,
		R.MATCH_PARTICIPATION,
		"an opponent who left within the minute leaves the survivor the ordinary award"
	)
	t.expect(not farmed.won, "and no win")

	local halfway = win(DURATION / 2, DURATION / 2, "forfeit")
	local expectedHalf = R.MATCH_PARTICIPATION + math.floor((R.MATCH_WIN - R.MATCH_PARTICIPATION) * 0.5)
	t.equal(halfway.amount, expectedHalf, "a forfeit halfway through pays halfway between taking part and winning")
	t.expect(halfway.won, "and counts as a win, having been played for")
	t.expect(halfway.amount < R.MATCH_WIN, "but not the full one")

	t.equal(win(DURATION, DURATION, "forfeit").amount, R.MATCH_WIN, "a forfeit at the very end is a whole win")

	local previous = 0
	for seconds = 60, DURATION, 30 do
		local paid = win(seconds, seconds, "forfeit").amount
		t.expect(paid >= previous, `waiting longer never pays a forfeit less ({seconds} s)`)
		t.expect(paid >= R.MATCH_PARTICIPATION and paid <= R.MATCH_WIN, `and it stays between the two ({seconds} s)`)
		previous = paid
	end

	-- The 30 second grace is the point: a 1v1 where the other account leaves at
	-- once must not pay anywhere near a win.
	t.expect(
		win(GameConfig.EMPTY_TEAM_GRACE + 5, GameConfig.EMPTY_TEAM_GRACE + 5, "forfeit").amount < R.MATCH_WIN / 2,
		"leaving at once and waiting out the grace pays less than half a win"
	)

	--------------------------------------------------------------------------
	-- Bad input pays the ordinary award, never more
	--------------------------------------------------------------------------

	local broken = Payout.compute({
		winnerTeam = "A",
		teamId = "A",
		playedSeconds = 0 / 0,
		matchSeconds = DURATION,
		matchDuration = DURATION,
		rewards = R,
		minSeconds = 60,
	})
	t.equal(broken.amount, R.MATCH_PARTICIPATION, "an unusable time falls back to the participation award")

	local missing = Payout.compute({
		winnerTeam = "A",
		teamId = "A",
		rewards = R,
	})
	t.equal(missing.amount, R.MATCH_PARTICIPATION, "so does a call with no times at all")
end
