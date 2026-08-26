--!nonstrict
--[[
	Balance.spec.luau
	The design intent behind the weapon numbers, written down as assertions.

	Three weapons are only interesting if each one is the right answer somewhere.
	Before falloff existed they were not: the rifle led on both rate of fire and
	magazine, so it was the correct pick at every distance on every map and the
	other two had no reason to exist. That is not a bug any type checker or unit
	test would have caught — the numbers were individually sensible and collectively
	pointless.

	So the bands are asserted here. Any future tuning that hands one weapon every
	range again fails this file, with a message saying which range it took.

	Distances are in studs. For scale, the arenas are 200-220 studs across, so a
	fight past 200 studs is a lane duel and one inside 30 is a room.
]]

local DamageCalc = require("../src/server/Combat/DamageCalc")
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

local MAX_HEALTH = 100

-- Where each weapon is meant to win, and where it is meant to lose.
local CLOSE = 20
local MID = 120
local LONG = 240

--[[
	Seconds from the first hit to the killing hit at `distance`. The first shot
	costs no time, so a three-shot kill is two gaps.
]]
local function timeToKill(weaponId: string, distance: number): number?
	local weapon = WeaponConfig.Weapons[weaponId]
	if distance > weapon.range then
		return nil -- cannot reach at all
	end

	local damage = DamageCalc.perShot(weapon, false, distance)
	return (math.ceil(MAX_HEALTH / damage) - 1) * weapon.fireRate
end

local function fastestAt(distance: number): (string, number)
	local bestId, bestTime = "", math.huge
	for _, weaponId in WeaponConfig.Order do
		local ttk = timeToKill(weaponId, distance)
		if ttk and ttk < bestTime then
			bestId, bestTime = weaponId, ttk
		end
	end
	return bestId, bestTime
end

return function(t)
	-- Each band belongs to somebody ---------------------------------------

	local closeWinner = fastestAt(CLOSE)
	local midWinner = fastestAt(MID)
	local longWinner = fastestAt(LONG)

	t.equal(closeWinner, "Pistol", `the pistol is the fastest kill at {CLOSE} studs`)
	t.equal(midWinner, "Rifle", `the rifle is the fastest kill at {MID} studs`)
	t.equal(longWinner, "Lance", `the lance is the fastest kill at {LONG} studs`)

	-- ...and nobody owns two bands, which is the failure this file exists for.
	t.expect(
		closeWinner ~= midWinner and midWinner ~= longWinner and closeWinner ~= longWinner,
		"no weapon is the fastest kill in more than one band"
	)

	-- Falloff shape --------------------------------------------------------

	for _, weaponId in WeaponConfig.Order do
		local weapon = WeaponConfig.Weapons[weaponId]
		local falloff = weapon.falloff

		if falloff then
			t.expect(
				type(falloff.start) == "number" and falloff.start >= 0,
				`{weaponId} falloff starts at a real distance`
			)
			t.expect(falloff.finish > falloff.start, `{weaponId} falloff finishes after it starts`)
			t.expect(
				falloff.minFactor > 0 and falloff.minFactor < 1,
				`{weaponId} falloff actually reduces damage without erasing it`
			)

			-- Damage must not fall below the point where the magazine cannot
			-- kill even once: a weapon that literally cannot finish a target is
			-- a bug rather than a trade-off.
			local worst = DamageCalc.perShot(weapon, false, falloff.finish)
			t.expect(
				worst * weapon.magSize >= MAX_HEALTH,
				`{weaponId} can still kill on one magazine at its worst range ({worst} x {weapon.magSize})`
			)
		end
	end

	-- The lance's whole claim is that it does not fade.
	t.equal(
		WeaponConfig.Weapons.Lance.falloff,
		nil,
		"the lance has no falloff — that is what makes it the long answer"
	)

	-- Falloff maths --------------------------------------------------------

	local rifle = WeaponConfig.Weapons.Rifle
	t.equal(DamageCalc.rangeFactor(rifle, 0), 1, "point blank is full damage")
	t.equal(DamageCalc.rangeFactor(rifle, rifle.falloff.start), 1, "damage is still full where falloff begins")
	t.equal(
		DamageCalc.rangeFactor(rifle, rifle.falloff.finish),
		rifle.falloff.minFactor,
		"damage reaches the floor exactly where falloff finishes"
	)
	t.equal(
		DamageCalc.rangeFactor(rifle, rifle.falloff.finish * 10),
		rifle.falloff.minFactor,
		"damage never drops below the floor, however far the shot travels"
	)

	local midpoint = (rifle.falloff.start + rifle.falloff.finish) / 2
	local expected = 1 - 0.5 * (1 - rifle.falloff.minFactor)
	t.expect(
		math.abs(DamageCalc.rangeFactor(rifle, midpoint) - expected) < 1e-9,
		"falloff is a straight line between its two ends"
	)

	-- A shot with no distance, or a nonsense one, must never be weakened: that
	-- would turn a mangled raycast into a silent damage nerf.
	t.equal(DamageCalc.rangeFactor(rifle, nil), 1, "an unknown distance does not reduce damage")
	t.equal(DamageCalc.rangeFactor(rifle, 0 / 0), 1, "a NaN distance does not reduce damage")
	t.equal(
		DamageCalc.perShot(rifle, false),
		DamageCalc.perShot(rifle, false, 0),
		"omitting distance means point blank"
	)

	-- Nobody is strictly worse than somebody else ---------------------------
	-- A weapon behind on every axis at once has no reason to be picked, which is
	-- the same failure as owning every band, seen from the other side.

	local axes = {
		{
			name = "close TTK",
			value = function(id)
				return -(timeToKill(id, CLOSE) or math.huge)
			end,
		},
		{
			name = "long TTK",
			value = function(id)
				return -(timeToKill(id, LONG) or math.huge)
			end,
		},
		{
			name = "magazine damage",
			value = function(id)
				local w = WeaponConfig.Weapons[id]
				return w.damage * w.magSize
			end,
		},
		{
			name = "reload speed",
			value = function(id)
				return -WeaponConfig.Weapons[id].reloadTime
			end,
		},
	}

	for _, a in WeaponConfig.Order do
		for _, b in WeaponConfig.Order do
			if a ~= b then
				local behindEverywhere = true
				for _, axis in axes do
					if axis.value(a) > axis.value(b) then
						behindEverywhere = false
						break
					end
				end
				t.expect(not behindEverywhere, `{a} is not strictly worse than {b} on every axis`)
			end
		end
	end

	-- Kills stay inside a window -------------------------------------------
	-- Anything much faster stops being a fight; anything much slower and players
	-- disengage instead of committing.

	for _, weaponId in WeaponConfig.Order do
		local ttk = timeToKill(weaponId, CLOSE)
		t.expect(ttk ~= nil and ttk >= 0.25, `{weaponId} does not kill instantly at close range`)
		t.expect(ttk ~= nil and ttk <= 0.8, `{weaponId} still kills in under a second at close range`)
	end
end
