--!nonstrict
--[[
	EconomyConfig.luau
	Coin rewards. Pure data — the server is the only thing that may act on it.
]]

local EconomyConfig = {}

-- Enough to feel like a welcome, deliberately not enough to buy anything: the
-- cheapest skin is still most of a match away, so the shop is a goal during the
-- first session rather than a formality cleared before the first fight.
EconomyConfig.STARTING_COINS = 250

EconomyConfig.REWARDS = {
	KILL = 25,
	HEADSHOT_BONUS = 10, -- added on top of KILL for a headshot kill

	-- The end-of-match award used to be 150/50, which made winning worth four
	-- kills. In a mode scored by TEAM kills that is backwards: it paid better to
	-- farm a losing fight than to close out a won one. At 400/100 a win is worth
	-- twelve kills — about as much as an average player's entire kill income for
	-- the match — so playing the score is the better way to earn.
	MATCH_WIN = 400,
	MATCH_PARTICIPATION = 100,
	MATCH_DRAW = 200,
}

--[[
	Seconds a player has to have been in a match for its win or draw bonus to be
	theirs. The award used to depend on the scoreline alone, so a player seated
	five seconds before the clock ran out was paid the same 400 as someone who
	played the ten minutes, and two accounts could take turns being the one who
	joined late. Kept small on purpose: joining a game that is already running
	should still be worth doing. GameConfig.LATE_JOIN_CUTOFF_SECONDS stops seating
	anyone who could not reach it.
]]
EconomyConfig.MATCH_BONUS_MIN_SECONDS = 60

--[[
	Kills of one particular victim by one particular killer that are paid in a
	single match; the rest still score for the team but earn nothing. A real
	match spreads kills over the enemy team, so this is only reached by a killer
	who keeps taking the same one of several enemies, which is the shape of
	alt-account farming (an average player takes 15 kills in a full match).

	It applies only while the killer's enemy team has two players or more
	(PairLimiter.MIN_OPPONENTS). A 1v1 is a single pair from the first kill to the
	last, and its winner takes 18 of them (GameConfig.SCORE_LIMIT_PER_PLAYER), so a
	limit of 12 there would stop paying an honest player six kills before the match
	ends: the score limit is that match's bound. The count is per match and per
	UserId, so rejoining does not start it again.
]]
EconomyConfig.MAX_PAID_KILLS_PER_PAIR = 12

-- Hard sanity cap on any single coin award; anything larger is a bug or an
-- exploit attempt and is rejected with a warning rather than granted.
EconomyConfig.MAX_SINGLE_AWARD = 10000

return EconomyConfig
