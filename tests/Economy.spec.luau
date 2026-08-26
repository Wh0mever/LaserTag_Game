--!nonstrict
--[[
	Economy.spec.luau
	The shape of the coin economy, written down as assertions.

	Prices and rewards are only meaningful relative to each other, and every
	number here was individually defensible while the economy as a whole was not:

	  * The full catalogue cost 9.4 hours of play. A player bought out every
	    cosmetic in the game over a weekend, after which coins accrued forever
	    with nothing to spend them on.
	  * Rarity had come loose from price. Epic ran 1200-3200 internally (2.7x)
	    while the cheapest Legendary was only 1.56x the dearest Epic, so the
	    badge on a card told you nothing about the number under it.
	  * The paid spin returned 1.01x for a new player and 0.69x for one who
	    already owned the wheel's skins — a straight loss aimed at exactly the
	    people most likely to buy one, with nothing on screen saying so.
	  * A match win paid four kills' worth in a mode scored by team kills, so
	    farming a lost fight beat closing out a won one.

	None of that is visible in any single config file, which is why it lives
	here. The model below is deliberately crude — one average player, one average
	match — because the failures it catches are order-of-magnitude failures, not
	tuning.
]]

local EconomyConfig = require("../src/shared/Config/EconomyConfig")
local GameConfig = require("../src/shared/Config/GameConfig")
local SkinCatalog = require("../src/shared/Config/SkinCatalog")
local SpinConfig = require("../src/shared/Config/SpinConfig")

local R = EconomyConfig.REWARDS

-- The average player this file reasons about: fifteen kills in a ten-minute
-- match, a fifth of them headshots, winning half the time. Not a measurement —
-- there is nothing to measure yet — but a stated assumption that every number
-- below is relative to, so changing it changes the whole file honestly.
local AVERAGE_KILLS = 15
local HEADSHOT_SHARE = 0.2
local WIN_RATE = 0.5

local RARITY_ORDER = { "Common", "Rare", "Epic", "Legendary" }

local function coinsPerMatch(): number
	local kills = AVERAGE_KILLS * R.KILL + AVERAGE_KILLS * HEADSHOT_SHARE * R.HEADSHOT_BONUS
	local outcome = WIN_RATE * R.MATCH_WIN + (1 - WIN_RATE) * R.MATCH_PARTICIPATION
	return kills + outcome
end

--[[
	Expected value of one spin, in coins, split by whether the player already
	owns the wheel's skins. Both matter: the first decides whether the wheel is
	worth discovering, the second whether it stays worth using.
]]
local function spinValue(): (number, number)
	local fresh, owned = 0, 0

	for _, segment in SpinConfig.Segments do
		local share = segment.weight / 100

		if segment.kind == "coins" then
			fresh += share * segment.coins
			owned += share * segment.coins
		elseif segment.kind == "skin" then
			local skin = SkinCatalog.get(segment.skinId)
			fresh += share * skin.price
			owned += share * math.floor(skin.price * SpinConfig.DUPLICATE_REFUND_RATIO)
		end
	end

	return fresh, owned
end

return function(t)
	local perMatch = coinsPerMatch()
	t.expect(perMatch > 0, "an average match pays something")

	-- Rarity predicts price ------------------------------------------------

	local band = {}
	for _, id in SkinCatalog.Order do
		local skin = SkinCatalog.Skins[id]
		if not skin.isDefault then
			local limits = SkinCatalog.PriceBands[skin.rarity]
			t.expect(limits ~= nil, `{id} has a price band for its rarity`)
			t.expect(
				skin.price >= limits.min and skin.price <= limits.max,
				`{id} is priced inside the {skin.rarity} band ({skin.price} in {limits.min}-{limits.max})`
			)

			local entry = band[skin.rarity] or { min = math.huge, max = 0, sum = 0, count = 0 }
			entry.min = math.min(entry.min, skin.price)
			entry.max = math.max(entry.max, skin.price)
			entry.sum += skin.price
			entry.count += 1
			band[skin.rarity] = entry
		end
	end

	-- Every tier is populated, its prices cluster, and it clearly outranks the
	-- tier below. Without the last check the bands could each be internally
	-- tidy while still overlapping into nonsense.
	local previousAverage, previousMax, previousName = nil, nil, nil
	for _, rarity in RARITY_ORDER do
		local entry = band[rarity]
		t.expect(entry ~= nil and entry.count > 0, `{rarity} has at least one skin`)

		if entry then
			t.expect(
				entry.max / entry.min <= 1.6,
				`{rarity} prices cluster rather than sprawl ({entry.max / entry.min}x)`
			)

			local average = entry.sum / entry.count
			if previousAverage then
				t.expect(
					average >= previousAverage * 2.5,
					`{rarity} costs meaningfully more than {previousName} ({average} vs {previousAverage})`
				)
				t.expect(
					entry.min > previousMax,
					`the cheapest {rarity} outprices the dearest {previousName} ({entry.min} vs {previousMax})`
				)
			end
			previousAverage, previousMax, previousName = average, entry.max, rarity
		end
	end

	-- The first purchase is a goal, not a formality --------------------------

	local cheapest = math.huge
	local total = 0
	for _, id in SkinCatalog.Order do
		local skin = SkinCatalog.Skins[id]
		if not skin.isDefault then
			cheapest = math.min(cheapest, skin.price)
			total += skin.price
		end
	end

	t.expect(
		cheapest > EconomyConfig.STARTING_COINS,
		`the starting grant cannot buy a skin outright ({EconomyConfig.STARTING_COINS} vs {cheapest})`
	)

	local matchesToFirst = (cheapest - EconomyConfig.STARTING_COINS) / perMatch
	t.expect(matchesToFirst >= 1, `the first skin takes at least a match to afford ({matchesToFirst})`)
	t.expect(matchesToFirst <= 3, `the first skin is reachable in a first session ({matchesToFirst} matches)`)

	-- ...and the collection is not ------------------------------------------
	-- The failure this catches is the catalogue being consumable in an
	-- afternoon, which ends progression and makes the currency meaningless.

	local matchesToAll = total / perMatch
	t.expect(matchesToAll >= 100, `the full catalogue is a long-term goal ({matchesToAll} matches)`)

	local dearest = 0
	for _, id in SkinCatalog.Order do
		dearest = math.max(dearest, SkinCatalog.Skins[id].price)
	end
	t.expect(dearest / perMatch >= 40, `the top skin is genuinely aspirational ({dearest / perMatch} matches)`)

	-- Winning is the better way to earn --------------------------------------
	-- This is a team mode scored by team kills. If a win is worth only a few
	-- kills then the paying strategy is to farm a losing fight, which is the
	-- opposite of the objective.

	t.expect(R.MATCH_WIN > R.MATCH_DRAW, "a win pays more than a draw")
	t.expect(R.MATCH_DRAW > R.MATCH_PARTICIPATION, "a draw pays more than a loss")

	local winSwingInKills = (R.MATCH_WIN - R.MATCH_PARTICIPATION) / R.KILL
	t.expect(winSwingInKills >= 8, `winning is worth at least eight kills ({winSwingInKills})`)

	t.expect(R.HEADSHOT_BONUS > 0, "a headshot kill pays more than a body kill")
	t.expect(R.HEADSHOT_BONUS < R.KILL, "but a headshot is a bonus, not a second kill")

	-- The wheel is never a trap ----------------------------------------------

	local fresh, owned = spinValue()
	local cost = SpinConfig.EXTRA_SPIN_COST

	t.expect(fresh > cost, `a paid spin is worth taking ({fresh} value for {cost})`)
	t.expect(
		owned >= cost,
		`a paid spin stays worth taking once the wheel's skins are owned ({owned} value for {cost})`
	)
	-- ...but not so generous that spinning replaces playing, which would make
	-- the shop decorative.
	t.expect(fresh <= cost * 2, `spinning does not dominate playing ({fresh / cost}x)`)

	t.expect(
		SpinConfig.DUPLICATE_REFUND_RATIO > 0 and SpinConfig.DUPLICATE_REFUND_RATIO < 1,
		"a duplicate refunds part of a price, never none and never all of it"
	)

	-- The wheel carries entry-level skins only. A single Epic or Legendary
	-- segment, at any weight worth displaying, is worth more than the spin cost
	-- by itself and makes the wheel strictly better than the shop.
	local previousWeight, previousPrice = math.huge, 0
	local skinSegments = 0
	for _, segment in SpinConfig.Segments do
		if segment.kind == "skin" then
			local skin = SkinCatalog.get(segment.skinId)
			t.expect(skin ~= nil, `the wheel segment {segment.id} names a real skin`)
			t.expect(
				skin.rarity == "Common" or skin.rarity == "Rare",
				`{segment.skinId} is entry-level enough for the wheel (is {skin.rarity})`
			)

			-- Rarer means less likely, so the wheel reads honestly.
			t.expect(
				segment.weight <= previousWeight,
				`wheel odds fall as prices rise ({segment.skinId} at {segment.weight}%)`
			)
			t.expect(skin.price >= previousPrice, `wheel skins are listed cheapest first ({segment.skinId})`)
			previousWeight, previousPrice = segment.weight, skin.price
			skinSegments += 1
		end
	end
	t.expect(skinSegments >= 2, "the wheel has skins on it at all")

	-- A free spin is a daily bonus, not a substitute for a session.
	local freeSpinsPerWeek = (7 * 24 * 60 * 60) / SpinConfig.FREE_SPIN_INTERVAL
	local freeCoinsPerWeek = freeSpinsPerWeek * fresh
	t.expect(
		freeCoinsPerWeek / perMatch <= 20,
		`a week of free spins is worth under 20 matches ({freeCoinsPerWeek / perMatch})`
	)
	t.expect(fresh / perMatch >= 0.5, `a free spin is worth collecting ({fresh / perMatch} matches)`)

	-- Nothing legitimate trips the anti-exploit cap --------------------------
	-- MAX_SINGLE_AWARD rejects an award rather than granting it, so a legitimate
	-- payout that grew past it would be silently withheld from players.

	local largest = math.max(R.MATCH_WIN, R.KILL + R.HEADSHOT_BONUS)
	for _, segment in SpinConfig.Segments do
		if segment.kind == "coins" then
			largest = math.max(largest, segment.coins)
		elseif segment.kind == "skin" then
			local skin = SkinCatalog.get(segment.skinId)
			largest = math.max(largest, math.floor(skin.price * SpinConfig.DUPLICATE_REFUND_RATIO))
		end
	end
	t.expect(
		EconomyConfig.MAX_SINGLE_AWARD > largest,
		`the anti-exploit cap clears every legitimate award ({EconomyConfig.MAX_SINGLE_AWARD} vs {largest})`
	)

	-- The match cycle the earn rate assumes ----------------------------------
	-- If a match ever got much shorter, every "matches to afford" number above
	-- would still pass while meaning something completely different in hours.
	t.expect(GameConfig.MATCH_DURATION >= 300, "a match is long enough for the earn rate to mean what it says")
end
