--!nonstrict
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

return function(t)
	-- Every weapon exists at the slot the hotbar expects.
	t.equal(WeaponConfig.fromSlot(1), "Rifle", "slot 1 is the rifle")
	t.equal(WeaponConfig.fromSlot(2), "Pistol", "slot 2 is the pistol")
	t.equal(WeaponConfig.fromSlot(3), "Lance", "slot 3 is the lance")
	t.equal(WeaponConfig.fromSlot(#WeaponConfig.Order + 1), nil, "there is no slot past the last weapon")

	t.expect(WeaponConfig.exists("Rifle"), "exists accepts a real weapon")
	t.expect(not WeaponConfig.exists("RocketLauncher"), "exists rejects an unknown weapon")
	t.expect(not WeaponConfig.exists(nil), "exists rejects nil")
	t.expect(not WeaponConfig.exists(42), "exists rejects a non-string")

	for id, weapon in pairs(WeaponConfig.Weapons) do
		t.equal(weapon.id, id, `{id} carries its own id`)
		t.expect(weapon.damage > 0, `{id} deals damage`)
		t.expect(weapon.fireRate > 0, `{id} has a positive fire interval`)
		t.expect(weapon.magSize > 0, `{id} has a magazine`)
		t.expect(weapon.reloadTime > 0, `{id} takes time to reload`)
		t.expect(weapon.range > 0, `{id} has range`)
		t.expect(weapon.headshotMultiplier > 1, `{id} rewards headshots`)
	end

	local rifle = WeaponConfig.Weapons.Rifle
	local pistol = WeaponConfig.Weapons.Pistol

	-- Design intent: the rifle wins on sustained fire, the pistol on per-shot
	-- punishment. If these ever flip, the weapons no longer play differently.
	t.expect(rifle.automatic, "the rifle is full auto")
	t.expect(not pistol.automatic, "the pistol is semi auto")
	t.expect(rifle.fireRate < pistol.fireRate, "the rifle fires faster")
	t.expect(pistol.damage > rifle.damage, "the pistol hits harder per shot")
	t.expect(rifle.magSize > pistol.magSize, "the rifle holds more ammo")
	t.expect(rifle.reloadTime > pistol.reloadTime, "the rifle reloads slower")
	t.expect(rifle.range > pistol.range, "the rifle reaches further")

	-- Shots to kill a full-health target at point blank.
	local MAX_HEALTH = 100
	t.equal(math.ceil(MAX_HEALTH / rifle.damage), 5, "the rifle needs 5 body shots")
	t.equal(math.ceil(MAX_HEALTH / pistol.damage), 2, "the pistol needs 2 body shots")
	t.equal(math.ceil(MAX_HEALTH / (rifle.damage * rifle.headshotMultiplier)), 3, "the rifle needs 3 headshots")
	t.equal(math.ceil(MAX_HEALTH / (pistol.damage * pistol.headshotMultiplier)), 1, "one pistol headshot is lethal")

	-- Who actually kills faster is deliberately NOT asserted here. It depends on
	-- range, which depends on falloff, which lives in DamageCalc — and the answer
	-- is meant to differ per band rather than be a fixed ranking. tests/
	-- Balance.spec.luau owns that, and owns it with the right arithmetic: the
	-- first shot costs no time, so an N-shot kill is N-1 intervals, not N. The
	-- version that used to sit here counted N and therefore reported the rifle as
	-- the faster weapon at every distance — which is the exact conclusion the
	-- falloff pass was undoing.

	-- Every weapon either fades with distance or is the one that does not, and
	-- the marksman weapon is the one that does not.
	local fadeless = {}
	for id, weapon in pairs(WeaponConfig.Weapons) do
		if weapon.falloff == nil then
			table.insert(fadeless, id)
		end
	end
	t.equal(#fadeless, 1, "exactly one weapon holds its damage at any range")
	t.equal(fadeless[1], "Lance", "and it is the lance")

	-- Origin tolerance must be generous enough for lag but far below a teleport.
	t.expect(
		WeaponConfig.MAX_ORIGIN_DEVIATION >= 4 and WeaponConfig.MAX_ORIGIN_DEVIATION <= 20,
		"origin tolerance is in a sane range"
	)
	t.expect(WeaponConfig.HEAD_PARTS.Head == true, "the Head part counts as a headshot")
end
