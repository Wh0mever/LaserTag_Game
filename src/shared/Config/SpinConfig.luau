--!nonstrict
--[[
	SpinConfig.luau
	Daily reward wheel.

	Odds are published to the player verbatim in the spin screen — the weights
	below ARE the displayed percentages and must always sum to 100. There is a
	free spin on a timer, so a player never has to pay to reach any reward, and
	a pity counter guarantees a skin after enough spins without one.
]]

local SpinConfig = {}

-- Seconds between free spins (20 hours: generous enough to catch a daily
-- session that drifts a few hours earlier each day).
SpinConfig.FREE_SPIN_INTERVAL = 20 * 60 * 60

-- Coin cost of an extra spin once the free one is used.
SpinConfig.EXTRA_SPIN_COST = 300

-- After this many consecutive spins without winning a skin, the next spin is
-- forced onto a skin segment.
SpinConfig.PITY_THRESHOLD = 10

-- A skin the player already owns converts to coins at this fraction of price.
SpinConfig.DUPLICATE_REFUND_RATIO = 0.5

-- Wheel segments. `weight` is the displayed percentage chance.
SpinConfig.Segments = {
	{ id = "coins_50", kind = "coins", label = "50 Coins", weight = 30, coins = 50 },
	{ id = "coins_100", kind = "coins", label = "100 Coins", weight = 25, coins = 100 },
	{ id = "coins_200", kind = "coins", label = "200 Coins", weight = 15, coins = 200 },
	{ id = "coins_400", kind = "coins", label = "400 Coins", weight = 10, coins = 400 },
	{ id = "skin_cyan", kind = "skin", label = "Deep Cyan Skin", weight = 8, skinId = "cyan" },
	{ id = "skin_toxic", kind = "skin", label = "Toxic Skin", weight = 6, skinId = "toxic" },
	{ id = "skin_magenta", kind = "skin", label = "Magenta Pulse Skin", weight = 4, skinId = "magenta" },
	{ id = "skin_galaxy", kind = "skin", label = "Galaxy Skin", weight = 2, skinId = "galaxy" },
}

function SpinConfig.totalWeight(): number
	local total = 0
	for _, segment in SpinConfig.Segments do
		total += segment.weight
	end
	return total
end

function SpinConfig.skinSegments()
	local result = {}
	for index, segment in ipairs(SpinConfig.Segments) do
		if segment.kind == "skin" then
			table.insert(result, { index = index, segment = segment })
		end
	end
	return result
end

return SpinConfig
