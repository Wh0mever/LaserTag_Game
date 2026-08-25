--!nonstrict
local ShopLogic = require("../src/server/Economy/ShopLogic")
local SkinCatalog = require("../src/shared/Config/SkinCatalog")
local TableUtil = require("../src/shared/Util/TableUtil")

-- The real catalog, not a fixture: the whole point of injecting it is that the
-- rules under test price skins exactly the way the running game does.
ShopLogic.setCatalog(SkinCatalog)

local PAID_SKIN = "crimson"
local OTHER_SKIN = "gold"
local DEFAULT_SKIN = SkinCatalog.DEFAULT_SKIN_ID

local function newProfile(coins: number, owned: { [string]: boolean }?)
	return {
		Coins = coins,
		Stats = { Kills = 3, Deaths = 1, Wins = 0, MatchesPlayed = 1, BestKillsInMatch = 3 },
		OwnedSkins = owned or {},
		EquippedSkins = { Rifle = DEFAULT_SKIN, Pistol = DEFAULT_SKIN },
		Spin = { LastFreeSpinAt = 0, Pity = 0, TotalSpins = 0 },
	}
end

local function countOwned(data): number
	local total = 0
	for _ in pairs(data.OwnedSkins) do
		total += 1
	end
	return total
end

return function(t)
	local price = SkinCatalog.get(PAID_SKIN).price
	t.expect(price > 0, "the fixture skin has a real price")

	----------------------------------------------------------------------------
	-- Successful purchase
	----------------------------------------------------------------------------

	local data = newProfile(price + 137)
	local ok, err = ShopLogic.applyBuy(data, PAID_SKIN)

	t.expect(ok, "buying an affordable, unowned skin succeeds")
	t.equal(err, nil, "a successful buy reports no error")
	t.equal(data.Coins, 137, "buying deducts exactly the price and nothing more")
	t.equal(data.OwnedSkins[PAID_SKIN], true, "buying grants the skin")
	t.equal(countOwned(data), 1, "buying grants exactly one skin")
	t.equal(data.EquippedSkins.Rifle, DEFAULT_SKIN, "buying does not equip anything")

	-- Buying a second skin stacks rather than replacing.
	local secondPrice = SkinCatalog.get(OTHER_SKIN).price
	data.Coins = secondPrice
	t.expect(ShopLogic.applyBuy(data, OTHER_SKIN), "a second purchase succeeds")
	t.equal(data.Coins, 0, "the second purchase spends the exact price")
	t.equal(countOwned(data), 2, "a second purchase keeps the first skin")

	-- Spending down to exactly zero is affordable; one coin short is not.
	local exact = newProfile(price)
	t.expect(ShopLogic.applyBuy(exact, PAID_SKIN), "a balance exactly equal to the price is enough")
	t.equal(exact.Coins, 0, "an exact-price purchase leaves a zero balance")

	----------------------------------------------------------------------------
	-- Rejections: each one must leave the profile deep-equal to a pre-made copy
	----------------------------------------------------------------------------

	local function rejects(label: string, profile, skinId: any): string
		local before = TableUtil.deepClone(profile)

		local canOk, canErr = ShopLogic.canBuy(profile, skinId)
		t.expect(not canOk, `canBuy rejects {label}`)
		t.deepEqual(profile, before, `canBuy leaves the profile untouched for {label}`)

		local applyOk, applyErr = ShopLogic.applyBuy(profile, skinId)
		t.expect(not applyOk, `applyBuy rejects {label}`)
		t.expect(type(applyErr) == "string" and #applyErr > 0, `{label} reports an error string`)
		t.equal(applyErr, canErr, `canBuy and applyBuy agree on the reason for {label}`)
		t.deepEqual(profile, before, `applyBuy leaves the profile untouched for {label}`)

		return applyErr
	end

	local unknownErr = rejects("an unknown skin", newProfile(99999), "not_a_real_skin")
	local defaultErr = rejects("the default skin", newProfile(99999), DEFAULT_SKIN)
	local ownedErr = rejects("an already-owned skin", newProfile(99999, { [PAID_SKIN] = true }), PAID_SKIN)
	local poorErr = rejects("an unaffordable skin", newProfile(price - 1), PAID_SKIN)

	-- A non-string id is still an unknown skin, not a crash.
	rejects("a numeric skin id", newProfile(99999), 12345)
	rejects("a nil skin id", newProfile(99999), nil)

	local reasons = { unknownErr, defaultErr, ownedErr, poorErr }
	local labels = { "unknown", "default", "owned", "unaffordable" }
	for i = 1, #reasons do
		for j = i + 1, #reasons do
			t.expect(reasons[i] ~= reasons[j], `the {labels[i]} and {labels[j]} rejections read differently`)
		end
	end

	-- A profile that is still loading must not be written into either.
	local halfLoaded = { Coins = 99999 }
	local halfLoadedCopy = TableUtil.deepClone(halfLoaded)
	t.expect(not ShopLogic.applyBuy(halfLoaded, PAID_SKIN), "a profile without OwnedSkins cannot buy")
	t.deepEqual(halfLoaded, halfLoadedCopy, "a rejected buy does not create missing sub-tables")

	----------------------------------------------------------------------------
	-- Equipping
	----------------------------------------------------------------------------

	local wardrobe = newProfile(0, { [PAID_SKIN] = true })

	t.expect(ShopLogic.canEquip(wardrobe, "Rifle", PAID_SKIN), "an owned skin is equippable")
	t.expect(ShopLogic.applyEquip(wardrobe, "Rifle", PAID_SKIN), "equipping an owned skin succeeds")
	t.equal(wardrobe.EquippedSkins.Rifle, PAID_SKIN, "equipping writes the skin onto the weapon")
	t.equal(wardrobe.EquippedSkins.Pistol, DEFAULT_SKIN, "equipping one weapon leaves the other alone")

	-- The default skin never appears in OwnedSkins, and is always wearable.
	t.equal(wardrobe.OwnedSkins[DEFAULT_SKIN], nil, "the default skin is not recorded as owned")
	t.expect(ShopLogic.canEquip(wardrobe, "Pistol", DEFAULT_SKIN), "the default skin is always equippable")
	t.expect(ShopLogic.applyEquip(wardrobe, "Rifle", DEFAULT_SKIN), "reverting to the default skin succeeds")
	t.equal(wardrobe.EquippedSkins.Rifle, DEFAULT_SKIN, "reverting writes the default skin back")

	local function rejectsEquip(label: string, profile, weaponId: any, skinId: any): string
		local before = TableUtil.deepClone(profile)

		local canOk = ShopLogic.canEquip(profile, weaponId, skinId)
		t.expect(not canOk, `canEquip rejects {label}`)

		local applyOk, applyErr = ShopLogic.applyEquip(profile, weaponId, skinId)
		t.expect(not applyOk, `applyEquip rejects {label}`)
		t.expect(type(applyErr) == "string" and #applyErr > 0, `{label} reports an error string`)
		t.deepEqual(profile, before, `applyEquip leaves the profile untouched for {label}`)

		return applyErr
	end

	local unownedErr = rejectsEquip("an unowned skin", newProfile(0), "Rifle", OTHER_SKIN)
	local unknownSkinErr = rejectsEquip("an unknown skin", newProfile(0), "Rifle", "not_a_real_skin")
	local unknownWeaponErr =
		rejectsEquip("an unknown weapon", newProfile(0, { [PAID_SKIN] = true }), "Bazooka", PAID_SKIN)

	t.expect(unownedErr ~= unknownSkinErr, "an unowned skin reads differently from an unknown one")
	t.expect(unknownWeaponErr ~= unownedErr, "an unknown weapon reads differently from an unowned skin")

	-- Owning a skin is not the same as being allowed to wear it on a weapon that
	-- the profile does not track.
	t.expect(
		not ShopLogic.canEquip(newProfile(0, { [PAID_SKIN] = true }), 7, PAID_SKIN),
		"a non-string weapon id is rejected"
	)

	----------------------------------------------------------------------------
	-- Prices
	----------------------------------------------------------------------------

	t.equal(ShopLogic.priceOf(PAID_SKIN), price, "priceOf reports the catalog price")
	t.equal(ShopLogic.priceOf(DEFAULT_SKIN), 0, "the default skin costs nothing")
	t.equal(ShopLogic.priceOf("not_a_real_skin"), 0, "an unknown skin costs nothing")
end
