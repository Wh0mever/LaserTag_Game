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

-- Coin cost of an extra spin once the free one is used. Deliberately about one
-- match's income, so the trade a player is offered is legible: play a match, or
-- gamble a match's worth on the wheel.
SpinConfig.EXTRA_SPIN_COST = 600

-- After this many consecutive spins without winning a skin, the next spin is
-- forced onto a skin segment.
SpinConfig.PITY_THRESHOLD = 10

-- A skin the player already owns converts to coins at this fraction of price.
--
-- This is what stops the wheel becoming a coin shredder for its best customers.
-- At 0.5 a player who owned the wheel's skins got back 0.69 coins per coin
-- spent — the paid spin was a straight loss for exactly the people most likely
-- to buy one, and nothing on screen said so. At 0.6 the paid spin stays
-- (slightly) worth taking even with the whole wheel already owned.
SpinConfig.DUPLICATE_REFUND_RATIO = 0.6

--[[
	Wheel segments. `weight` is the displayed percentage chance.

	The skin segments are deliberately only Common and Rare items. The wheel's
	job is to speed up the start of a collection, not to replace the grind that
	makes an Epic or a Legendary mean anything — and at the current price ladder
	a single Legendary segment, at any weight worth showing, would make spinning
	strictly better than playing.

	Weight falls as price rises, so the wheel reads honestly: the thing you most
	want off it is the thing you are least likely to get.
]]
SpinConfig.Segments = {
	{ id = "coins_200", kind = "coins", label = "200 монет", weight = 30, coins = 200 },
	{ id = "coins_400", kind = "coins", label = "400 монет", weight = 25, coins = 400 },
	{ id = "coins_800", kind = "coins", label = "800 монет", weight = 15, coins = 800 },
	{ id = "coins_1500", kind = "coins", label = "1 500 монет", weight = 10, coins = 1500 },
	{ id = "skin_crimson", kind = "skin", label = "Скин «Багровый»", weight = 8, skinId = "crimson" },
	{ id = "skin_arctic", kind = "skin", label = "Скин «Арктика»", weight = 6, skinId = "arctic" },
	{ id = "skin_cyan", kind = "skin", label = "Скин «Глубокий циан»", weight = 4, skinId = "cyan" },
	{ id = "skin_toxic", kind = "skin", label = "Скин «Токсичный»", weight = 2, skinId = "toxic" },
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
