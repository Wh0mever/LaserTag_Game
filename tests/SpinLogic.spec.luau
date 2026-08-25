--!nonstrict
local SkinCatalog = require("../src/shared/Config/SkinCatalog")
local SpinConfig = require("../src/shared/Config/SpinConfig")
local SpinLogic = require("../src/server/Economy/SpinLogic")
local TableUtil = require("../src/shared/Util/TableUtil")

-- The real config and catalog: the odds and refunds under test are the ones the
-- running game rolls and pays.
SpinLogic.configure(SpinConfig, SkinCatalog)

local function newProfile(coins: number, owned: { [string]: boolean }?, pity: number?)
	return {
		Coins = coins,
		Stats = { Kills = 0, Deaths = 0, Wins = 0, MatchesPlayed = 0, BestKillsInMatch = 0 },
		OwnedSkins = owned or {},
		EquippedSkins = { Rifle = SkinCatalog.DEFAULT_SKIN_ID, Pistol = SkinCatalog.DEFAULT_SKIN_ID },
		Spin = { LastFreeSpinAt = 0, Pity = pity or 0, TotalSpins = 0 },
	}
end

local function firstSegmentOfKind(kind: string)
	for index, segment in ipairs(SpinConfig.Segments) do
		if segment.kind == kind then
			return segment, index
		end
	end
	return nil, 0
end

return function(t)
	local total = SpinConfig.totalWeight()

	----------------------------------------------------------------------------
	-- The published odds
	----------------------------------------------------------------------------

	-- The weights ARE the percentages shown to the player, so they have to sum
	-- to exactly 100 or the spin screen is lying.
	t.equal(total, 100, "the segment weights sum to 100")

	for index, segment in ipairs(SpinConfig.Segments) do
		t.expect(segment.weight > 0, `segment {index} ({segment.id}) has a positive weight`)
		t.expect(segment.kind == "coins" or segment.kind == "skin", `segment {index} ({segment.id}) has a known kind`)
		if segment.kind == "skin" then
			t.expect(SkinCatalog.exists(segment.skinId), `segment {index} names a skin that exists`)
		else
			t.expect(segment.coins > 0, `segment {index} pays a positive number of coins`)
		end
	end

	----------------------------------------------------------------------------
	-- roll: rngValue boundaries map to the expected segment
	----------------------------------------------------------------------------

	-- Bands are half-open, so probe each edge from just inside and just outside
	-- rather than exactly on it: a value like 0.30 is not representable and
	-- multiplying it back up by 100 lands on either side of 30 by chance.
	local EDGE = 1e-9
	local lower = 0

	for index, segment in ipairs(SpinConfig.Segments) do
		local upper = lower + segment.weight

		local midSegment, midIndex = SpinLogic.roll((lower + upper) / 2 / total, 0)
		t.equal(midIndex, index, `the middle of band {index} rolls segment {index}`)
		t.equal(midSegment.id, segment.id, `the middle of band {index} rolls "{segment.id}"`)

		local _, justInside = SpinLogic.roll(lower / total + EDGE, 0)
		t.equal(justInside, index, `just inside the start of band {index} rolls segment {index}`)

		if index > 1 then
			local _, justBefore = SpinLogic.roll(lower / total - EDGE, 0)
			t.equal(justBefore, index - 1, `just before the start of band {index} still rolls segment {index - 1}`)
		end

		lower = upper
	end

	local firstSegment, firstIndex = SpinLogic.roll(0, 0)
	t.equal(firstIndex, 1, "a roll of 0 lands on the first segment")
	t.equal(firstSegment.id, SpinConfig.Segments[1].id, "a roll of 0 lands on the first segment by id")

	local _, lastIndex = SpinLogic.roll(1 - 1e-6, 0)
	t.equal(lastIndex, #SpinConfig.Segments, "a roll just under 1 lands on the last segment")

	-- Out-of-range input is clamped onto the wheel instead of falling off it.
	local _, atOne = SpinLogic.roll(1, 0)
	t.equal(atOne, #SpinConfig.Segments, "a roll of exactly 1 stays on the last segment")
	local _, negative = SpinLogic.roll(-5, 0)
	t.equal(negative, 1, "a negative roll is pulled back to the first segment")

	----------------------------------------------------------------------------
	-- Pity
	----------------------------------------------------------------------------

	for _, sample in { 0, 0.05, 0.3, 0.5, 0.75, 0.99 } do
		local segment = SpinLogic.roll(sample, SpinConfig.PITY_THRESHOLD)
		t.equal(segment.kind, "skin", `pity at the threshold forces a skin at rng {sample}`)
	end

	local aboveThreshold = SpinLogic.roll(0, SpinConfig.PITY_THRESHOLD + 5)
	t.equal(aboveThreshold.kind, "skin", "pity past the threshold still forces a skin")

	-- One short of the threshold the full wheel is still in play, and rng 0 is
	-- the first band, which is a coin segment.
	local belowThreshold, belowIndex = SpinLogic.roll(0, SpinConfig.PITY_THRESHOLD - 1)
	t.equal(belowIndex, 1, "one spin below the threshold still rolls the full wheel")
	t.equal(belowThreshold.kind, "coins", "one spin below the threshold can still roll coins")

	-- A forced skin roll must still spread across every skin segment.
	local seenSkins = {}
	for step = 0, 99 do
		local segment = SpinLogic.roll(step / 100, SpinConfig.PITY_THRESHOLD)
		seenSkins[segment.id] = true
	end
	t.equal(TableUtil.count(seenSkins), #SpinConfig.skinSegments(), "a forced roll can reach every skin segment")

	----------------------------------------------------------------------------
	-- applyResult: coins
	----------------------------------------------------------------------------

	local coinSegment = firstSegmentOfKind("coins")
	local coinsProfile = newProfile(500, nil, 3)
	local kind, awarded, label = SpinLogic.applyResult(coinsProfile, coinSegment)

	t.equal(kind, SpinLogic.RewardKinds.Coins, "a coin segment reports a coin reward")
	t.equal(awarded, coinSegment.coins, "a coin segment awards its face value")
	t.equal(coinsProfile.Coins, 500 + coinSegment.coins, "a coin segment adds to the balance")
	t.equal(label, coinSegment.label, "a coin segment reports its own label")
	t.equal(coinsProfile.Spin.Pity, 4, "a coin segment advances pity")
	t.equal(coinsProfile.Spin.TotalSpins, 1, "a coin segment counts as a spin")
	t.equal(TableUtil.count(coinsProfile.OwnedSkins), 0, "a coin segment grants no skin")

	----------------------------------------------------------------------------
	-- applyResult: a new skin
	----------------------------------------------------------------------------

	local skinSegment = firstSegmentOfKind("skin")
	local skin = SkinCatalog.get(skinSegment.skinId)

	local newSkinProfile = newProfile(120, nil, 7)
	local newKind, newCoins = SpinLogic.applyResult(newSkinProfile, skinSegment)

	t.equal(newKind, SpinLogic.RewardKinds.Skin, "an unowned skin segment reports a skin reward")
	t.equal(newCoins, 0, "an unowned skin pays no coins")
	t.equal(newSkinProfile.Coins, 120, "an unowned skin leaves the balance alone")
	t.equal(newSkinProfile.OwnedSkins[skinSegment.skinId], true, "an unowned skin is granted")
	t.equal(newSkinProfile.Spin.Pity, 0, "winning a skin resets pity")
	t.equal(newSkinProfile.Spin.TotalSpins, 1, "a skin win counts as a spin")

	----------------------------------------------------------------------------
	-- applyResult: a duplicate skin
	----------------------------------------------------------------------------

	local expectedRefund = math.floor(skin.price * SpinConfig.DUPLICATE_REFUND_RATIO)
	t.expect(expectedRefund > 0, "the duplicate refund is worth something")

	local dupeProfile = newProfile(120, { [skinSegment.skinId] = true }, 7)
	local dupeKind, dupeCoins, dupeLabel = SpinLogic.applyResult(dupeProfile, skinSegment)

	t.equal(dupeKind, SpinLogic.RewardKinds.Duplicate, "an owned skin segment reports a duplicate")
	t.equal(dupeCoins, expectedRefund, "a duplicate pays the configured fraction of the price")
	t.equal(dupeProfile.Coins, 120 + expectedRefund, "a duplicate adds the refund to the balance")
	t.equal(TableUtil.count(dupeProfile.OwnedSkins), 1, "a duplicate does not grant a second copy")
	t.equal(dupeProfile.Spin.Pity, 0, "a duplicate still counts as a skin win and resets pity")
	t.equal(dupeProfile.Spin.TotalSpins, 1, "a duplicate counts as a spin")
	t.expect(type(dupeLabel) == "string" and #dupeLabel > 0, "a duplicate reports a label")

	-- Malformed input must not half-apply anything.
	local untouched = newProfile(50)
	local untouchedCopy = TableUtil.deepClone(untouched)
	local badKind, badCoins = SpinLogic.applyResult(untouched, nil)
	t.equal(badKind, SpinLogic.RewardKinds.None, "a missing segment yields no reward")
	t.equal(badCoins, 0, "a missing segment pays nothing")
	t.deepEqual(untouched, untouchedCopy, "a missing segment leaves the profile untouched")

	----------------------------------------------------------------------------
	-- The free-spin gate
	----------------------------------------------------------------------------

	local interval = SpinConfig.FREE_SPIN_INTERVAL
	local spinState = { LastFreeSpinAt = 1_000_000, Pity = 0, TotalSpins = 0 }

	t.equal(SpinLogic.nextFreeAt(spinState), 1_000_000 + interval, "the next free spin is one interval later")
	t.expect(not SpinLogic.canSpinFree(spinState, 1_000_000), "a spin just taken is not immediately free again")
	t.expect(not SpinLogic.canSpinFree(spinState, 1_000_000 + interval - 1), "one second early is not free")
	t.expect(SpinLogic.canSpinFree(spinState, 1_000_000 + interval), "the free spin unlocks exactly on the interval")
	t.expect(SpinLogic.canSpinFree(spinState, 1_000_000 + interval * 3), "a long absence leaves the spin free")

	-- A profile that has never spun starts with its free spin available: server
	-- time is a unix epoch, so LastFreeSpinAt = 0 is decades in the past.
	local fresh = newProfile(0)
	t.equal(SpinLogic.nextFreeAt(fresh.Spin), interval, "a fresh profile unlocks at one interval past zero")
	t.expect(SpinLogic.canSpinFree(fresh.Spin, 1_700_000_000), "a fresh profile has a free spin waiting")

	t.expect(not SpinLogic.canSpinFree(fresh.Spin, nil), "a missing clock value is never free")
	t.expect(not SpinLogic.canSpinFree(fresh.Spin, 0 / 0), "a NaN clock value is never free")

	-- markFreeSpin is what consumes it.
	t.expect(SpinLogic.markFreeSpin(fresh.Spin, 1_700_000_000), "marking a free spin succeeds")
	t.equal(fresh.Spin.LastFreeSpinAt, 1_700_000_000, "marking records when the free spin was taken")
	t.expect(not SpinLogic.canSpinFree(fresh.Spin, 1_700_000_000), "the free spin is spent once marked")
	t.expect(
		SpinLogic.canSpinFree(fresh.Spin, 1_700_000_000 + interval),
		"the free spin comes back one interval after it was taken"
	)
	t.expect(not SpinLogic.markFreeSpin(nil, 1_700_000_000), "marking a missing spin state fails")
end
