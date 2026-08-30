--!nonstrict
--[[
	NexusDef.luau
	"Nexus" — a 200 x 160 industrial arena built around height.

	The other two maps are fought on one level: Dust across open lanes, Mirage
	through tight indoor rooms. This one adds the third axis. A raised central
	platform overlooks the whole arena, and everything else is about getting onto
	it or punishing whoever is up there — four ramps from the flanks, a covered
	crossing directly underneath, and side catwalks that see the platform from
	the same height.

	That gives the map a question the others do not ask: take the high ground and
	be exposed from three sides, or stay low and fight through the underpass.

	Pure data — no Roblox API — so tests/MapDefs.spec.luau can require it off
	Roblox. `origin` and `killY` mirror GameConfig.MAP_ORIGINS.Nexus and
	GameConfig.DEFAULT_KILL_Y; MapDefs cannot require GameConfig (it would break
	the off-Roblox spec runner), so the spec asserts they match.

	SYMMETRY: everything appended through `mirror()` is emitted twice, the second
	time rotated 180 degrees about the map centre ((x, z) -> (-x, -z)). Height
	makes an asymmetric map far more punishing than a flat one would, so only the
	centre line and the two hand-written spawn rooms escape it.
]]

local HALF_X = 100 -- arena spans x in [-100, 100]
local HALF_Z = 80 -- arena spans z in [-80, 80]
local WALL_HEIGHT = 52 -- taller than Dust: the platform must not be escapable
local WALL_THICKNESS = 6

local PLATFORM_Y = 14 -- top surface of the central platform
local PLATFORM_HALF_X = 30
local PLATFORM_HALF_Z = 26
local CATWALK_Y = 14 -- level with the platform, so duels across are fair

local elements = {}

local function add(element)
	table.insert(elements, element)
	return element
end

local function flipSide(side: string?): string?
	if side == "+x" then
		return "-x"
	elseif side == "-x" then
		return "+x"
	elseif side == "+z" then
		return "-z"
	elseif side == "-z" then
		return "+z"
	end
	return side
end

--[[
	Appends `element` and its 180-degree twin. Handles every positional field the
	element kinds in this map use.
]]
local function mirror(element)
	add(element)

	local twin = table.clone(element)
	if element.pos then
		twin.pos = { x = -element.pos.x, y = element.pos.y, z = -element.pos.z }
	end
	if element.from then
		twin.from = { x = -element.from.x, z = -element.from.z }
	end
	if element.to then
		twin.to = { x = -element.to.x, z = -element.to.z }
	end
	if element.center then
		twin.center = { x = -element.center.x, z = -element.center.z }
	end
	if type(element.rotation) == "table" then
		-- Conjugating an XYZ euler rotation by a 180-degree yaw negates X and Z.
		twin.rotation = { x = -(element.rotation.x or 0), y = element.rotation.y or 0, z = -(element.rotation.z or 0) }
	elseif type(element.rotation) == "number" then
		twin.rotation = element.rotation + 180
	end
	if element.doorSide then
		twin.doorSide = flipSide(element.doorSide)
	end
	if element.doorways then
		local flipped = {}
		for _, doorway in element.doorways do
			table.insert(flipped, { side = flipSide(doorway.side), width = doorway.width })
		end
		twin.doorways = flipped
	end

	add(twin)
	return twin
end

-- Ground and perimeter ----------------------------------------------------

add({
	kind = "floor",
	pos = { x = 0, y = -2, z = 0 },
	size = { x = HALF_X * 2, y = 4, z = HALF_Z * 2 },
	color = "Deck",
	material = "Metal",
})

mirror({
	kind = "wall",
	from = { x = -HALF_X, z = -HALF_Z },
	to = { x = HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 26,
})

mirror({
	kind = "wall",
	from = { x = -HALF_X, z = HALF_Z },
	to = { x = -HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 26,
})

-- Spawn rooms -------------------------------------------------------------
-- Written out by hand rather than mirrored so the team ids stay explicit.

add({
	kind = "spawnRoom",
	team = "A",
	center = { x = -84, z = 0 },
	size = { x = 30, y = 22, z = 44 },
	doorSide = "+x",
	doorWidth = 18,
	spawnCount = 8,
	color = "Wall",
	floorColor = "DeckDark",
	ceilingColor = "Roof",
	neonColor = "TeamA",
	neonStripY = 12,
})

add({
	kind = "spawnRoom",
	team = "B",
	center = { x = 84, z = 0 },
	size = { x = 30, y = 22, z = 44 },
	doorSide = "-x",
	doorWidth = 18,
	spawnCount = 8,
	color = "Wall",
	floorColor = "DeckDark",
	ceilingColor = "Roof",
	neonColor = "TeamB",
	neonStripY = 12,
})

-- The central platform ----------------------------------------------------
-- Four pillars hold it up, which is what turns the space underneath into a
-- fightable underpass rather than a tunnel with no cover.

add({
	kind = "block",
	pos = { x = 0, y = PLATFORM_Y - 1.5, z = 0 },
	size = { x = PLATFORM_HALF_X * 2, y = 3, z = PLATFORM_HALF_Z * 2 },
	color = "DeckDark",
	material = "Metal",
	studs = true,
	studColor = "Deck",
})

-- Pillars at the four corners of the platform.
mirror({
	kind = "block",
	pos = { x = -PLATFORM_HALF_X + 4, y = 6, z = -PLATFORM_HALF_Z + 4 },
	size = { x = 6, y = 12, z = 6 },
	color = "Strut",
	material = "Metal",
})

mirror({
	kind = "block",
	pos = { x = PLATFORM_HALF_X - 4, y = 6, z = -PLATFORM_HALF_Z + 4 },
	size = { x = 6, y = 12, z = 6 },
	color = "Strut",
	material = "Metal",
})

-- A low railing so players can take cover on top instead of being fully
-- exposed the moment they climb up. Broken at the ramp mouths.
mirror({
	kind = "block",
	pos = { x = 0, y = PLATFORM_Y + 1.5, z = -PLATFORM_HALF_Z + 0.6 },
	size = { x = PLATFORM_HALF_X * 2, y = 3, z = 1.2 },
	color = "Strut",
	material = "Metal",
})

-- Ramps up ----------------------------------------------------------------
-- One pair from each flank. The 16-degree tilt raises the far end; the centre
-- height is chosen so the high end lands level with the platform and the low
-- end meets the floor.

mirror({
	kind = "ramp",
	pos = { x = -46, y = 6.4, z = -34 },
	size = { x = 30, y = 2.4, z = 20 },
	color = "DeckDark",
	material = "Metal",
	rotation = { x = 0, y = 0, z = 16 },
})

mirror({
	kind = "ramp",
	pos = { x = -46, y = 6.4, z = 34 },
	size = { x = 30, y = 2.4, z = 20 },
	color = "DeckDark",
	material = "Metal",
	rotation = { x = 0, y = 0, z = 16 },
})

-- Side catwalks -----------------------------------------------------------
-- Level with the platform and along both long walls, so holding the middle can
-- be answered from the flank rather than only from below.

mirror({
	kind = "block",
	pos = { x = -40, y = CATWALK_Y - 1, z = -HALF_Z + 10 },
	size = { x = 56, y = 2, z = 16 },
	color = "Deck",
	material = "Metal",
})

mirror({
	kind = "block",
	pos = { x = -40, y = CATWALK_Y + 1.5, z = -HALF_Z + 2.4 },
	size = { x = 56, y = 3, z = 1.2 },
	color = "Strut",
	material = "Metal",
})

-- Ramp from the spawn side up onto the catwalk.
mirror({
	kind = "ramp",
	pos = { x = -74, y = 6, z = -HALF_Z + 10 },
	size = { x = 22, y = 2.4, z = 16 },
	color = "Deck",
	material = "Metal",
	rotation = { x = 0, y = 0, z = 20 },
})

-- Cover on the open deck --------------------------------------------------

mirror({
	kind = "block",
	pos = { x = -58, y = 3, z = 0 },
	size = { x = 10, y = 6, z = 18 },
	color = "Crate",
	studs = true,
	studColor = "CrateDark",
})

mirror({
	kind = "block",
	pos = { x = -30, y = 2.5, z = -56 },
	size = { x = 14, y = 5, z = 10 },
	color = "Crate",
	studs = true,
	studColor = "CrateDark",
})

mirror({
	kind = "block",
	pos = { x = 12, y = 2, z = -44 },
	size = { x = 10, y = 4, z = 10 },
	color = "CrateDark",
})

-- Inside the underpass, so crossing under the platform is not a clean sightline.
mirror({
	kind = "block",
	pos = { x = -14, y = 2.5, z = 10 },
	size = { x = 8, y = 5, z = 12 },
	color = "CrateDark",
})

-- Light ------------------------------------------------------------------
-- Neon runs along the underpass ceiling and the catwalk edges: the two places a
-- player needs to read depth quickly.

mirror({
	kind = "neonStrip",
	pos = { x = 0, y = PLATFORM_Y - 3.4, z = -14 },
	size = { x = PLATFORM_HALF_X * 2 - 8, y = 0.4, z = 1.4 },
	color = "Neon",
})

mirror({
	kind = "neonStrip",
	pos = { x = -40, y = CATWALK_Y + 0.2, z = -HALF_Z + 18 },
	size = { x = 56, y = 0.4, z = 1.2 },
	color = "Neon",
})

local NexusDef = {
	id = "Nexus",
	displayName = "Nexus",
	origin = { x = 6000, y = 0, z = 0 },
	killY = -60,

	palette = {
		Deck = { r = 132, g = 142, b = 158 },
		DeckDark = { r = 92, g = 100, b = 116 },
		Wall = { r = 74, g = 82, b = 100 },
		WallDark = { r = 54, g = 60, b = 76 },
		Strut = { r = 148, g = 156, b = 172 },
		Trim = { r = 172, g = 178, b = 192 },
		Crate = { r = 96, g = 116, b = 148 },
		CrateDark = { r = 66, g = 82, b = 108 },
		Roof = { r = 60, g = 66, b = 82 },
		Metal = { r = 126, g = 132, b = 140 },
		Neon = { r = 0, g = 229, b = 255 },
		Board = { r = 26, g = 30, b = 42 },
		TeamA = { r = 45, g = 216, b = 129 },
		TeamB = { r = 235, g = 87, b = 158 },
	},

	elements = elements,
}

return NexusDef
