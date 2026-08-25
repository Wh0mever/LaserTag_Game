--!nonstrict
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

return function(t)
	-- Both weapons exist with the slots the hotbar expects.
	t.equal(WeaponConfig.fromSlot(1), "Rifle", "slot 1 is the rifle")
	t.equal(WeaponConfig.fromSlot(2), "Pistol", "slot 2 is the pistol")
	t.equal(WeaponConfig.fromSlot(3), nil, "there is no third slot")

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

	-- Time to kill a full-health target with body shots.
	local MAX_HEALTH = 100
	local rifleShots = math.ceil(MAX_HEALTH / rifle.damage)
	local pistolShots = math.ceil(MAX_HEALTH / pistol.damage)
	t.equal(rifleShots, 5, "the rifle needs 5 body shots")
	t.equal(pistolShots, 3, "the pistol needs 3 body shots")

	-- Headshot kills.
	t.equal(math.ceil(MAX_HEALTH / (rifle.damage * rifle.headshotMultiplier)), 3, "the rifle needs 3 headshots")
	t.equal(math.ceil(MAX_HEALTH / (pistol.damage * pistol.headshotMultiplier)), 2, "the pistol needs 2 headshots")

	-- The rifle still kills faster overall despite the lower per-shot damage.
	t.expect(rifleShots * rifle.fireRate < pistolShots * pistol.fireRate, "the rifle has the lower time-to-kill")

	-- Origin tolerance must be generous enough for lag but far below a teleport.
	t.expect(
		WeaponConfig.MAX_ORIGIN_DEVIATION >= 4 and WeaponConfig.MAX_ORIGIN_DEVIATION <= 20,
		"origin tolerance is in a sane range"
	)
	t.expect(WeaponConfig.HEAD_PARTS.Head == true, "the Head part counts as a headshot")
end
