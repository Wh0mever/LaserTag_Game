--!nonstrict
local DamageCalc = require("../src/server/Combat/DamageCalc")
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

return function(t)
	local rifle = WeaponConfig.Weapons.Rifle
	local pistol = WeaponConfig.Weapons.Pistol
	local MAX_HEALTH = 100

	-- DamageCalc keeps its own head-part table so it can be required off Roblox;
	-- the server passes WeaponConfig.HEAD_PARTS. If the two ever disagree, the
	-- unit tests would be measuring a different weapon to the live game.
	t.deepEqual(DamageCalc.HEAD_PARTS, WeaponConfig.HEAD_PARTS, "the head-part fallback matches WeaponConfig")

	-- Rifle: 22 body, 44 head (x2.0).
	local damage, headshot = DamageCalc.compute(rifle, "Torso")
	t.equal(damage, 22, "a rifle body shot deals 22")
	t.expect(not headshot, "Torso is not a headshot")

	damage, headshot = DamageCalc.compute(rifle, "Head")
	t.equal(damage, 44, "a rifle headshot deals 44")
	t.expect(headshot, "Head is a headshot")

	-- Pistol: 34 body, 59 head — 34 x 1.75 is 59.5 and must floor, not round.
	damage, headshot = DamageCalc.compute(pistol, "LeftLeg")
	t.equal(damage, 34, "a pistol body shot deals 34")
	t.expect(not headshot, "LeftLeg is not a headshot")

	damage, headshot = DamageCalc.compute(pistol, "Head")
	t.equal(damage, 59, "a pistol headshot floors 59.5 to 59")
	t.expect(headshot, "a pistol Head hit is a headshot")

	-- The explicit head-part table is the path CombatService actually takes.
	t.equal(DamageCalc.compute(rifle, "Head", WeaponConfig.HEAD_PARTS), 44, "an injected head-part table works")
	t.equal(DamageCalc.compute(rifle, "Torso", WeaponConfig.HEAD_PARTS), 22, "an injected table still allows body hits")

	-- Anything the table does not list is a body hit. A raycast can land on an
	-- accessory, an R15 part or a welded gun piece, and none of those may pay
	-- more than a known body part.
	local UNKNOWN_PARTS = { "UpperTorso", "LowerTorso", "RightHand", "LeftFoot", "Handle", "Hat", "" }
	for _, partName in UNKNOWN_PARTS do
		local unknownDamage, unknownHeadshot = DamageCalc.compute(rifle, partName)
		t.equal(unknownDamage, 22, `"{partName}" counts as a body hit`)
		t.expect(not unknownHeadshot, `"{partName}" is not a headshot`)
	end

	t.equal(DamageCalc.compute(rifle, nil), 22, "a nil part name counts as a body hit")
	t.equal(DamageCalc.compute(rifle, 42), 22, "a non-string part name counts as a body hit")
	t.expect(not DamageCalc.isHeadshot(nil), "isHeadshot rejects nil")
	t.expect(not DamageCalc.isHeadshot({ Head = true }), "isHeadshot rejects a table")
	t.expect(DamageCalc.isHeadshot("Head"), "isHeadshot accepts Head")

	-- Shots to kill a full-health target.
	t.equal(DamageCalc.shotsToKill(rifle, MAX_HEALTH, false), 5, "the rifle needs 5 body shots")
	t.equal(DamageCalc.shotsToKill(rifle, MAX_HEALTH, true), 3, "the rifle needs 3 headshots")
	t.equal(DamageCalc.shotsToKill(pistol, MAX_HEALTH, false), 3, "the pistol needs 3 body shots")
	t.equal(DamageCalc.shotsToKill(pistol, MAX_HEALTH, true), 2, "the pistol needs 2 headshots")

	t.equal(DamageCalc.shotsToKill(rifle, 1, false), 1, "one shot finishes a target on 1 health")
	t.equal(DamageCalc.shotsToKill(rifle, 22, false), 1, "an exact multiple does not need a spare shot")
	t.equal(DamageCalc.shotsToKill(rifle, 23, false), 2, "one health over a multiple needs another shot")
	t.equal(DamageCalc.shotsToKill(rifle, 0, false), 0, "a target already down needs no shots")
	t.equal(DamageCalc.shotsToKill(rifle, -5, false), 0, "negative health needs no shots")
	t.equal(DamageCalc.shotsToKill(rifle, 0 / 0, false), 0, "NaN health needs no shots")

	-- Damage is always a positive integer, for every weapon and every part.
	local PARTS = { "Head", "Torso", "HumanoidRootPart", "LeftFoot", "Nonsense" }
	for id, weapon in pairs(WeaponConfig.Weapons) do
		for _, partName in PARTS do
			local value = DamageCalc.compute(weapon, partName)
			t.expect(value >= 1, `{id} deals at least 1 damage to {partName}`)
			t.equal(math.floor(value), value, `{id} deals whole-number damage to {partName}`)
		end

		t.expect(
			DamageCalc.compute(weapon, "Head") > DamageCalc.compute(weapon, "Torso"),
			`{id} rewards a headshot over a body shot`
		)
	end

	-- Degenerate weapon definitions must still resolve to a usable number rather
	-- than a zero-damage hit that registers on screen and does nothing.
	t.equal(DamageCalc.compute({ damage = 0.4 }, "Torso"), 1, "sub-1 damage floors to the minimum")
	t.equal(DamageCalc.compute({ damage = -10 }, "Torso"), 1, "negative damage floors to the minimum")
	t.equal(DamageCalc.compute(nil, "Torso"), 1, "a missing weapon definition still costs the minimum")
	t.equal(
		DamageCalc.compute({ damage = 10, headshotMultiplier = math.huge }, "Head"),
		10,
		"an infinite multiplier is ignored"
	)
	t.equal(DamageCalc.compute({ damage = 10, headshotMultiplier = 0 }, "Head"), 10, "a zero multiplier is ignored")
	t.equal(DamageCalc.shotsToKill({ damage = 0 }, MAX_HEALTH, false), 100, "minimum damage still kills eventually")
end
