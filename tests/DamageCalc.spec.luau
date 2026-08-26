--!nonstrict
local DamageCalc = require("../src/server/Combat/DamageCalc")
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

return function(t)
	local rifle = WeaponConfig.Weapons.Rifle
	local pistol = WeaponConfig.Weapons.Pistol
	local lance = WeaponConfig.Weapons.Lance
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

	-- Pistol: 50 body, 100 head (x2.0) — exactly lethal, which is the two-tap
	-- stated as one shot.
	damage, headshot = DamageCalc.compute(pistol, "LeftLeg")
	t.equal(damage, 50, "a pistol body shot deals 50")
	t.expect(not headshot, "LeftLeg is not a headshot")

	damage, headshot = DamageCalc.compute(pistol, "Head")
	t.equal(damage, 100, "a pistol headshot deals 100")
	t.expect(headshot, "a pistol Head hit is a headshot")

	-- Lance: 55 body, 104 head — 55 x 1.9 is 104.5 and must floor, not round.
	-- Rounding here would be invisible until MAX_HEALTH moved and a headshot
	-- quietly stopped killing.
	t.equal(DamageCalc.compute(lance, "Torso"), 55, "a lance body shot deals 55")
	t.equal(DamageCalc.compute(lance, "Head"), 104, "a lance headshot floors 104.5 to 104")

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
	t.equal(DamageCalc.shotsToKill(pistol, MAX_HEALTH, false), 2, "the pistol needs 2 body shots")
	t.equal(DamageCalc.shotsToKill(pistol, MAX_HEALTH, true), 1, "one pistol headshot is lethal")
	t.equal(DamageCalc.shotsToKill(lance, MAX_HEALTH, false), 2, "the lance needs 2 body shots")
	t.equal(DamageCalc.shotsToKill(lance, MAX_HEALTH, true), 1, "one lance headshot is lethal")

	t.equal(DamageCalc.shotsToKill(rifle, 1, false), 1, "one shot finishes a target on 1 health")
	t.equal(DamageCalc.shotsToKill(rifle, 22, false), 1, "an exact multiple does not need a spare shot")
	t.equal(DamageCalc.shotsToKill(rifle, 23, false), 2, "one health over a multiple needs another shot")
	t.equal(DamageCalc.shotsToKill(rifle, 0, false), 0, "a target already down needs no shots")
	t.equal(DamageCalc.shotsToKill(rifle, -5, false), 0, "negative health needs no shots")
	t.equal(DamageCalc.shotsToKill(rifle, 0 / 0, false), 0, "NaN health needs no shots")

	-- Distance reaches the damage ---------------------------------------------
	-- Balance.spec asserts the shape of the falloff curve; what matters here is
	-- that `distance` is actually threaded through every entry point, because a
	-- caller that silently drops it turns falloff off without failing anything.

	t.equal(DamageCalc.compute(pistol, "Torso", nil, pistol.falloff.finish), 20, "compute applies falloff at range")
	t.equal(DamageCalc.compute(pistol, "Head", nil, pistol.falloff.finish), 40, "a headshot is reduced by range too")
	t.equal(
		DamageCalc.shotsToKill(pistol, MAX_HEALTH, false, pistol.falloff.finish),
		5,
		"range turns a two-tap into five"
	)
	t.equal(DamageCalc.shotsToKill(pistol, MAX_HEALTH, false, 0), 2, "point blank is still a two-tap")

	-- The lance carries no falloff block, so distance must not touch it at all.
	t.equal(DamageCalc.compute(lance, "Torso", nil, 10000), 55, "the lance ignores distance entirely")
	t.equal(DamageCalc.rangeFactor(lance, 10000), 1, "a weapon with no falloff never fades")

	-- A malformed falloff block must be inert rather than lethal in either
	-- direction: a typo in the config should cost a weapon its falloff, not its
	-- damage.
	local MALFORMED = {
		{ start = 10, finish = 5, minFactor = 0.5 }, -- finishes before it starts
		{ start = 10, minFactor = 0.5 }, -- no finish
		{ start = "near", finish = 100, minFactor = 0.5 }, -- not a number
		{ start = 10, finish = 100, minFactor = 0 / 0 }, -- NaN floor
	}
	for index, falloff in MALFORMED do
		local weapon = { damage = 40, falloff = falloff }
		t.equal(DamageCalc.compute(weapon, "Torso", nil, 500), 40, `malformed falloff {index} is ignored`)
	end

	-- Even a floor of zero cannot produce a hit that registers and does nothing.
	t.equal(
		DamageCalc.compute({ damage = 40, falloff = { start = 1, finish = 2, minFactor = 0 } }, "Torso", nil, 500),
		1,
		"falloff never reduces a landed hit below the minimum"
	)

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
