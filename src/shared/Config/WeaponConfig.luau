--!nonstrict
--[[
	WeaponConfig.luau
	Weapon stat blocks. Pure data — no Roblox API — so the server, the client
	and the off-Roblox test runner all read the exact same numbers.

	The server is the only authority: it reads `damage`, `fireRate`, `magSize`
	and `range` from here when validating a shot. The client reads the same
	values purely for prediction and HUD display.
]]

local WeaponConfig = {}

WeaponConfig.Weapons = {
	Rifle = {
		id = "Rifle",
		displayName = "PULSE RIFLE",
		slot = 1,
		automatic = true,

		damage = 22,
		headshotMultiplier = 2.0, -- 44 to the head: 3 headshots kill
		fireRate = 0.1, -- 600 RPM
		magSize = 30,
		reloadTime = 2.2,
		range = 400,

		baseSpreadDeg = 0.15,
		sprayResetTime = 0.3,
		recoilRecovery = 10,

		beamWidth = 0.28,
		muzzleOffset = { x = 0, y = 0, z = -2.4 },
	},

	Pistol = {
		id = "Pistol",
		displayName = "ION PISTOL",
		slot = 2,
		automatic = false,

		damage = 34,
		headshotMultiplier = 1.75, -- 59.5 to the head: 2 headshots kill
		fireRate = 0.35,
		magSize = 12,
		reloadTime = 1.4,
		range = 300,

		baseSpreadDeg = 0.3,
		sprayResetTime = 0.5,
		recoilRecovery = 8,

		beamWidth = 0.22,
		muzzleOffset = { x = 0, y = 0, z = -1.4 },
	},

	Lance = {
		id = "Lance",
		displayName = "ARC LANCE",
		slot = 3,
		automatic = false,

		-- The long-range answer to the rifle, and priced in tempo rather than
		-- damage-per-second: two body shots kill, but at barely three shots a
		-- second, so a miss costs more than any other weapon here. Spamming it
		-- is punished hard by the spread table below, which opens up almost
		-- immediately — this rewards holding an angle, not duelling up close.
		damage = 55,
		headshotMultiplier = 1.9, -- 104.5: a headshot kills outright
		fireRate = 0.62,
		magSize = 6,
		reloadTime = 2.6,
		range = 600,

		baseSpreadDeg = 0.04, -- the tightest first shot in the game
		sprayResetTime = 0.9, -- and the longest wait to get it back
		recoilRecovery = 5,

		beamWidth = 0.36,
		muzzleOffset = { x = 0, y = 0, z = -3.2 },
	},
}

WeaponConfig.Order = { "Rifle", "Pistol", "Lance" }

-- Extra inaccuracy while moving faster than this (studs/second).
WeaponConfig.MOVING_SPEED_THRESHOLD = 8
WeaponConfig.MOVING_SPREAD_PENALTY_DEG = 0.5

-- The server allows a shot origin to differ from the server-known eye position
-- by at most this many studs, which tolerates normal latency but rejects
-- teleport/origin-spoof exploits.
WeaponConfig.MAX_ORIGIN_DEVIATION = 8

-- Body part name -> whether it counts as a headshot. Anything not listed is
-- treated as a body hit.
WeaponConfig.HEAD_PARTS = {
	Head = true,
}

function WeaponConfig.get(weaponId: string)
	return WeaponConfig.Weapons[weaponId]
end

function WeaponConfig.exists(weaponId: any): boolean
	return type(weaponId) == "string" and WeaponConfig.Weapons[weaponId] ~= nil
end

function WeaponConfig.fromSlot(slot: number): string?
	for _, id in WeaponConfig.Order do
		if WeaponConfig.Weapons[id].slot == slot then
			return id
		end
	end
	return nil
end

return WeaponConfig
