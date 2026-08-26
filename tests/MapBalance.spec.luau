--!nonstrict
--[[
	MapBalance.spec.luau
	Whether the arenas are fair, and whether they contain the fights the weapons
	were tuned for.

	MapDefs.spec.luau already checks that a def is well formed — known element
	kinds, a palette, two spawn rooms, an enclosing wall. This file is about what
	the geometry does to a match:

	  * Neither team may get the better end. Every element must have a 180-degree
	    twin, which is stronger than checking the spawn rooms match: a single
	    crate placed with add() instead of mirror() hands one side cover the
	    other does not have, and nothing else would notice.

	  * A weapon's range band has to exist somewhere. The lance was tuned to take
	    over past 240 studs while the longest clear sightline in the game was 234
	    — its entire band sat beyond the edge of every arena, so it was never the
	    right answer anywhere. That failure is invisible in WeaponConfig, which
	    knows nothing about maps, and invisible in the map defs, which know
	    nothing about weapons.

	  * Three maps should not play the same. If they all offered the same
	    sightlines the portal choice would be cosmetic.

	SIGHTLINES are measured top-down at chest height: elements are projected to
	rectangles in the xz plane and a line between two open points is clear if it
	misses all of them. Rooms are modelled as four perimeter slabs, since their
	interiors are walkable. Doorways are NOT cut out, so a real doorway sightline
	is slightly longer than measured here — the numbers are a lower bound, which
	is the safe direction for "does this distance exist".
]]

local DamageCalc = require("../src/server/Combat/DamageCalc")
local DustDef = require("../src/shared/MapDefs/DustDef")
local MirageDef = require("../src/shared/MapDefs/MirageDef")
local NexusDef = require("../src/shared/MapDefs/NexusDef")
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

-- Chest height of a character standing on the arena floor.
local EYE = 3

-- Sampling step for the sightline search, in studs.
--
-- The search is O(points^2) and points scale as 1/STEP^2, so this is the knob
-- that decides whether the file costs milliseconds or minutes. It also biases
-- the answer: a coarse grid can miss the two points that see each other, and
-- always underestimates. At 8 studs Mirage measures 85 against a true 99, which
-- is enough to move a threshold; at 4 it is accurate to a stud or so and the
-- whole suite still runs in about two seconds.
local STEP = 4

local function rect(cx, cz, sx, sz)
	return { x0 = cx - sx / 2, x1 = cx + sx / 2, z0 = cz - sz / 2, z1 = cz + sz / 2 }
end

--[[
	Everything that blocks a shot at `eye` height, as xz rectangles.
]]
local function occluders(def, eye: number)
	local rects = {}

	for _, element in def.elements do
		local kind = element.kind

		if kind == "block" and element.pos and element.size then
			local low = element.pos.y - element.size.y / 2
			local high = element.pos.y + element.size.y / 2
			if low <= eye and eye <= high then
				table.insert(rects, rect(element.pos.x, element.pos.z, element.size.x, element.size.z))
			end
		elseif kind == "wall" and element.from and element.to and (element.height or 0) >= eye then
			local thickness = element.thickness or 4
			table.insert(
				rects,
				rect(
					(element.from.x + element.to.x) / 2,
					(element.from.z + element.to.z) / 2,
					math.max(math.abs(element.to.x - element.from.x), thickness),
					math.max(math.abs(element.to.z - element.from.z), thickness)
				)
			)
		elseif (kind == "room" or kind == "spawnRoom") and element.center and element.size then
			local sx, sz, thickness = element.size.x, element.size.z, 4
			table.insert(rects, rect(element.center.x, element.center.z - sz / 2, sx, thickness))
			table.insert(rects, rect(element.center.x, element.center.z + sz / 2, sx, thickness))
			table.insert(rects, rect(element.center.x - sx / 2, element.center.z, thickness, sz))
			table.insert(rects, rect(element.center.x + sx / 2, element.center.z, thickness, sz))
		end
	end

	return rects
end

-- Slab method: does the segment from (px, pz) to (qx, qz) touch `r`?
local function segmentHitsRect(px, pz, qx, qz, r): boolean
	local enter, exit = 0, 1

	for _, axis in { { p = px, d = qx - px, lo = r.x0, hi = r.x1 }, { p = pz, d = qz - pz, lo = r.z0, hi = r.z1 } } do
		if math.abs(axis.d) < 1e-9 then
			if axis.p < axis.lo or axis.p > axis.hi then
				return false
			end
		else
			local a, b = (axis.lo - axis.p) / axis.d, (axis.hi - axis.p) / axis.d
			if a > b then
				a, b = b, a
			end
			enter = math.max(enter, a)
			exit = math.min(exit, b)
			if enter > exit then
				return false
			end
		end
	end

	return true
end

local function isClear(px, pz, qx, qz, rects): boolean
	for _, r in rects do
		if segmentHitsRect(px, pz, qx, qz, r) then
			return false
		end
	end
	return true
end

local function isInside(x, z, rects): boolean
	for _, r in rects do
		if x >= r.x0 and x <= r.x1 and z >= r.z0 and z <= r.z1 then
			return true
		end
	end
	return false
end

local function floorSize(def): (number, number)
	for _, element in def.elements do
		if element.kind == "floor" then
			return element.size.x, element.size.z
		end
	end
	return 0, 0
end

--[[
	Open floor points on a grid centred on the origin.

	The offsets are symmetric (-n*STEP .. n*STEP) so the sample set is itself
	invariant under the 180-degree rotation. A grid running edge-to-edge would
	sample the two halves differently and make a symmetric map measure as
	lopsided — which is a bug in the measurement that reads exactly like a bug
	in the map.
]]
local function openPoints(def, rects)
	local sx, sz = floorSize(def)
	local points = {}
	local nx = math.floor((sx / 2 - STEP) / STEP)
	local nz = math.floor((sz / 2 - STEP) / STEP)

	for i = -nx, nx do
		for j = -nz, nz do
			local x, z = i * STEP, j * STEP
			if not isInside(x, z, rects) then
				table.insert(points, { x = x, z = z })
			end
		end
	end

	return points
end

--[[
	The longest unobstructed line between two open points, in studs.

	Pairs are only raycast when they could beat the best found so far, which is
	what keeps an O(n^2) search cheap enough to sit in CI.
]]
local function longestSightline(def, eye: number): number
	local rects = occluders(def, eye)
	local points = openPoints(def, rects)
	local best = 0

	for i = 1, #points do
		local a = points[i]
		for j = i + 1, #points do
			local b = points[j]
			local squared = (a.x - b.x) ^ 2 + (a.z - b.z) ^ 2
			if squared > best * best and isClear(a.x, a.z, b.x, b.z, rects) then
				best = math.sqrt(squared)
			end
		end
	end

	return best
end

--[[
	A canonical string for an element, optionally rotated 180 degrees about the
	map centre. Two elements are twins when one's flipped key equals the other's
	unflipped key.
]]
local function elementKey(element, flip: boolean): string
	local function point(v): string
		if not v then
			return "-"
		end
		local x, z = v.x, v.z
		if flip then
			x, z = -x, -z
		end
		-- Normalise negative zero: an element on the centre line is its own twin,
		-- and "-0.0" would otherwise never match "0.0".
		x = if x == 0 then 0 else x
		z = if z == 0 then 0 else z
		return string.format("%.2f,%.2f", x, z)
	end

	local key = element.kind .. "|" .. point(element.pos) .. "|" .. point(element.center)

	if element.from and element.to then
		-- A wall is the same wall whichever end is written first.
		local a, b = point(element.from), point(element.to)
		if a > b then
			a, b = b, a
		end
		key ..= "|" .. a .. ">" .. b
	end

	if element.size then
		key ..= string.format("|%.2f,%.2f,%.2f", element.size.x, element.size.y or 0, element.size.z or 0)
	end
	if element.height then
		key ..= "|h" .. tostring(element.height)
	end

	return key
end

local function spawnRooms(def)
	local byTeam = {}
	for _, element in def.elements do
		if element.kind == "spawnRoom" then
			byTeam[element.team] = element
		end
	end
	return byTeam
end

return function(t)
	local maps = {
		{ name = "Dust", def = DustDef },
		{ name = "Mirage", def = MirageDef },
		{ name = "Nexus", def = NexusDef },
	}

	local reach = {}

	-- Neither team gets the better end -------------------------------------

	for _, entry in maps do
		local counts = {}
		for _, element in entry.def.elements do
			local key = elementKey(element, false)
			counts[key] = (counts[key] or 0) + 1
		end

		local orphan = nil
		for _, element in entry.def.elements do
			if (counts[elementKey(element, true)] or 0) == 0 then
				orphan = elementKey(element, false)
				break
			end
		end

		t.equal(orphan, nil, `every element on {entry.name} has a 180-degree twin`)
	end

	-- Spawns are equally placed and cannot see each other --------------------

	for _, entry in maps do
		local rooms = spawnRooms(entry.def)
		local a, b = rooms.A, rooms.B

		if a and b then
			local distanceA = math.sqrt(a.center.x ^ 2 + a.center.z ^ 2)
			local distanceB = math.sqrt(b.center.x ^ 2 + b.center.z ^ 2)
			t.expect(
				math.abs(distanceA - distanceB) < 1e-6,
				`{entry.name} spawns are the same distance from the centre ({distanceA} vs {distanceB})`
			)

			-- A spawn that can be shot from the other spawn is a spawn camp with
			-- extra steps.
			local rects = occluders(entry.def, EYE)
			t.expect(
				not isClear(a.center.x, a.center.z, b.center.x, b.center.z, rects),
				`{entry.name} spawn A cannot see spawn B`
			)

			-- Far enough apart that the first contact is not immediate. Below
			-- roughly a rifle's effective reach the match opens inside a fight.
			local apart = math.sqrt((a.center.x - b.center.x) ^ 2 + (a.center.z - b.center.z) ^ 2)
			t.expect(apart >= 120, `{entry.name} spawns are far enough apart to walk out of ({apart} studs)`)
		end
	end

	-- The fights the weapons were tuned for actually exist -------------------

	for _, entry in maps do
		local ground = longestSightline(entry.def, EYE)
		reach[entry.name] = ground

		t.expect(ground > 0, `{entry.name} has a measurable sightline`)

		-- A map with no line longer than a room is a corridor, not an arena.
		t.expect(ground >= 90, `{entry.name} has at least one real lane ({ground} studs)`)
	end

	local longestAnywhere = 0
	for _, distance in reach do
		longestAnywhere = math.max(longestAnywhere, distance)
	end

	--[[
		The check that would have caught the lance.

		For every weapon that fades, the distance where it drops to its floor has
		to be inside what some arena offers — otherwise the bottom of its curve is
		unreachable and the tuning below it is decoration. For the weapon that
		does NOT fade, the point where it becomes the best answer must likewise be
		reachable, or it is never the best answer at all.
	]]
	for _, weaponId in WeaponConfig.Order do
		local weapon = WeaponConfig.Weapons[weaponId]

		if weapon.falloff then
			t.expect(
				weapon.falloff.start < longestAnywhere,
				`{weaponId} starts fading within a distance that exists ({weapon.falloff.start} vs {longestAnywhere})`
			)
		end
	end

	-- The marksman weapon is the one with no falloff; find where it overtakes
	-- the rifle and require that distance to be on a map.
	local rifle = WeaponConfig.Weapons.Rifle
	local lance = WeaponConfig.Weapons.Lance
	local MAX_HEALTH = 100

	local function timeToKill(weapon, distance: number): number
		local damage = DamageCalc.perShot(weapon, false, distance)
		return (math.ceil(MAX_HEALTH / damage) - 1) * weapon.fireRate
	end

	local crossover = nil
	for distance = 10, 400, 2 do
		if timeToKill(lance, distance) < timeToKill(rifle, distance) then
			crossover = distance
			break
		end
	end

	t.expect(crossover ~= nil, "the lance overtakes the rifle at some distance")
	if crossover then
		t.expect(
			crossover <= longestAnywhere,
			`the lance's band exists on a map (overtakes at {crossover}, longest lane is {longestAnywhere})`
		)
		-- ...and is not so close that it also takes the middle of the game.
		t.expect(crossover >= 100, `the lance does not also own mid range (overtakes at {crossover})`)
	end

	-- Three maps, three different fights -------------------------------------

	t.expect(
		reach.Mirage < reach.Dust and reach.Dust < reach.Nexus,
		`the maps are ordered tight to open (Mirage {reach.Mirage}, Dust {reach.Dust}, Nexus {reach.Nexus})`
	)
	t.expect(
		reach.Nexus >= reach.Mirage * 1.75,
		`the most open map is meaningfully more open than the tightest ({reach.Nexus} vs {reach.Mirage})`
	)

	-- Mirage is the close-quarters map: the lance must not be the answer there.
	t.expect(
		reach.Mirage < (crossover or math.huge),
		`Mirage stays inside the rifle's band ({reach.Mirage} vs a {crossover} crossover)`
	)
end
