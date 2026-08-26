--!nonstrict
--[[
	SprayPatterns.luau
	Deterministic recoil patterns, CS2-style.

	Two separate concepts live here and they must not be confused:

	  * KICK  — how far the *camera* is pushed for shot N. It is deterministic
	            and identical on every client, so a player can learn the pattern
	            and pull down against it. This is the "feel" of the weapon.

	  * SPREAD — the random cone the *server* adds around the aim direction for
	             shot N. It grows while the trigger is held so that spraying at
	             range is punished. The client never computes damage, so this is
	             purely a server-side number (the client mirrors it only to draw
	             a matching crosshair bloom).

	The rifle pattern is the classic three-phase spray: a steep vertical climb,
	then a sway to the right, then a sway back to the left.

	Pure module: no Roblox API, unit-tested by tests/SprayPatterns.spec.luau.
]]

local SprayPatterns = {}

-- Rifle: 30 entries, one per bullet in the magazine.
-- Phase 1 (1-8):   climb, almost no horizontal drift.
-- Phase 2 (9-18):  reduced climb, drifting right.
-- Phase 3 (19-30): little climb, drifting left.
local RIFLE_KICK = {
	{ pitch = 0.35, yaw = 0.00 },
	{ pitch = 0.55, yaw = -0.04 },
	{ pitch = 0.75, yaw = 0.05 },
	{ pitch = 0.95, yaw = -0.05 },
	{ pitch = 1.10, yaw = 0.06 },
	{ pitch = 1.25, yaw = -0.06 },
	{ pitch = 1.40, yaw = 0.07 },
	{ pitch = 1.50, yaw = 0.10 },

	{ pitch = 0.85, yaw = 0.25 },
	{ pitch = 0.75, yaw = 0.34 },
	{ pitch = 0.65, yaw = 0.42 },
	{ pitch = 0.60, yaw = 0.50 },
	{ pitch = 0.55, yaw = 0.56 },
	{ pitch = 0.50, yaw = 0.60 },
	{ pitch = 0.48, yaw = 0.58 },
	{ pitch = 0.45, yaw = 0.52 },
	{ pitch = 0.42, yaw = 0.44 },
	{ pitch = 0.40, yaw = 0.30 },

	{ pitch = 0.38, yaw = -0.20 },
	{ pitch = 0.36, yaw = -0.35 },
	{ pitch = 0.35, yaw = -0.45 },
	{ pitch = 0.35, yaw = -0.50 },
	{ pitch = 0.34, yaw = -0.50 },
	{ pitch = 0.33, yaw = -0.48 },
	{ pitch = 0.33, yaw = -0.44 },
	{ pitch = 0.32, yaw = -0.40 },
	{ pitch = 0.32, yaw = -0.36 },
	{ pitch = 0.31, yaw = -0.32 },
	{ pitch = 0.30, yaw = -0.28 },
	{ pitch = 0.30, yaw = -0.24 },
}

-- Pistol: 12 entries, essentially vertical with a slight alternating wobble.
local PISTOL_KICK = {
	{ pitch = 0.90, yaw = 0.00 },
	{ pitch = 0.95, yaw = -0.05 },
	{ pitch = 1.00, yaw = 0.05 },
	{ pitch = 1.05, yaw = -0.05 },
	{ pitch = 1.10, yaw = 0.05 },
	{ pitch = 1.15, yaw = -0.05 },
	{ pitch = 1.20, yaw = 0.05 },
	{ pitch = 1.22, yaw = -0.05 },
	{ pitch = 1.25, yaw = 0.05 },
	{ pitch = 1.27, yaw = -0.05 },
	{ pitch = 1.29, yaw = 0.05 },
	{ pitch = 1.30, yaw = 0.00 },
}

-- Lance: 6 entries, one per round. A single heavy vertical punch with almost no
-- horizontal wander — the shot itself is accurate, so the cost is that the
-- muzzle ends up somewhere else and has to be pulled back down before the next
-- one is worth taking.
local LANCE_KICK = {
	{ pitch = 2.60, yaw = 0.00 },
	{ pitch = 2.80, yaw = -0.10 },
	{ pitch = 3.00, yaw = 0.10 },
	{ pitch = 3.20, yaw = -0.10 },
	{ pitch = 3.40, yaw = 0.10 },
	{ pitch = 3.60, yaw = 0.00 },
}

SprayPatterns.Kick = {
	Rifle = RIFLE_KICK,
	Pistol = PISTOL_KICK,
	Lance = LANCE_KICK,
}

-- Server-side inaccuracy cone in degrees, keyed by how deep into the spray we
-- are. Each entry is { upToIndex, degrees } and the table is read in order.
SprayPatterns.Spread = {
	Rifle = {
		{ upTo = 3, degrees = 0.2 },
		{ upTo = 8, degrees = 0.5 },
		{ upTo = 15, degrees = 1.2 },
		{ upTo = math.huge, degrees = 2.2 },
	},
	Pistol = {
		{ upTo = 1, degrees = 0.3 },
		{ upTo = 3, degrees = 0.6 },
		{ upTo = 6, degrees = 1.0 },
		{ upTo = math.huge, degrees = 1.5 },
	},
	-- The Lance is pin-accurate on the first shot and useless sprayed: the cone
	-- opens by an order of magnitude on the second. That, rather than raw
	-- damage, is what keeps a two-shot-kill weapon from dominating close range.
	Lance = {
		{ upTo = 1, degrees = 0.04 },
		{ upTo = 2, degrees = 1.4 },
		{ upTo = 4, degrees = 3.0 },
		{ upTo = math.huge, degrees = 4.5 },
	},
}

--[[
	Camera kick for the given shot index (1-based). Indices past the end of the
	table clamp to the last entry, so a modified magazine can never error.
]]
function SprayPatterns.getKick(weaponId: string, shotIndex: number): { pitch: number, yaw: number }
	local pattern = SprayPatterns.Kick[weaponId]
	if not pattern or #pattern == 0 then
		return { pitch = 0, yaw = 0 }
	end

	local index = math.clamp(math.floor(shotIndex), 1, #pattern)
	local entry = pattern[index]
	return { pitch = entry.pitch, yaw = entry.yaw }
end

--[[
	Server inaccuracy cone (degrees) for the given shot index.
]]
function SprayPatterns.getServerSpreadDeg(weaponId: string, shotIndex: number): number
	local table_ = SprayPatterns.Spread[weaponId]
	if not table_ then
		return 0
	end

	local index = math.max(1, math.floor(shotIndex))
	for _, entry in table_ do
		if index <= entry.upTo then
			return entry.degrees
		end
	end

	return table_[#table_].degrees
end

--[[
	Advance the spray counter. The pattern resets when the player stops firing
	for longer than the weapon's sprayResetTime, which is what lets a tapping
	player stay accurate.

	`previousIndex` is the index of the last shot (0 if none).
	`timeSinceLastShot` is in seconds; pass math.huge for a fresh magazine.
]]
function SprayPatterns.nextIndex(
	weaponId: string,
	previousIndex: number,
	timeSinceLastShot: number,
	resetTime: number
): number
	if timeSinceLastShot > resetTime then
		return 1
	end

	local pattern = SprayPatterns.Kick[weaponId]
	local maxIndex = pattern and #pattern or 1

	return math.min(previousIndex + 1, maxIndex)
end

--[[
	Total accumulated camera offset after `shots` consecutive shots. Used by the
	client to draw the spray preview in the shop/equip screens.
]]
function SprayPatterns.accumulate(weaponId: string, shots: number): { pitch: number, yaw: number }
	local pitch, yaw = 0, 0
	for index = 1, shots do
		local kick = SprayPatterns.getKick(weaponId, index)
		pitch += kick.pitch
		yaw += kick.yaw
	end
	return { pitch = pitch, yaw = yaw }
end

return SprayPatterns
