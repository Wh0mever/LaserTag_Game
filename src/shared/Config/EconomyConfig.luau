--!nonstrict
--[[
	EconomyConfig.luau
	Coin rewards. Pure data — the server is the only thing that may act on it.
]]

local EconomyConfig = {}

EconomyConfig.STARTING_COINS = 100

EconomyConfig.REWARDS = {
	KILL = 25,
	HEADSHOT_BONUS = 10, -- added on top of KILL for a headshot kill
	MATCH_WIN = 150,
	MATCH_PARTICIPATION = 50,
	MATCH_DRAW = 75,
}

-- Hard sanity cap on any single coin award; anything larger is a bug or an
-- exploit attempt and is rejected with a warning rather than granted.
EconomyConfig.MAX_SINGLE_AWARD = 10000

return EconomyConfig
