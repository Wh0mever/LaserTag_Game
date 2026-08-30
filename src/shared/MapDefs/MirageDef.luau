--!nonstrict
--[[
	MirageDef.luau
	"Mirage" — a 180 x 140 indoor arena: purple walls with white trim, a tiled
	ceiling carrying neon strips, green side rooms and glowing doorframes.
	Corridors are deliberately tighter than Dust so fights happen at short range.

	Pure data — no Roblox API — so tests/MapDefs.spec.luau can require it off
	Roblox. `origin` and `killY` mirror GameConfig.MAP_ORIGINS.Mirage and
	GameConfig.DEFAULT_KILL_Y; MapDefs cannot require GameConfig (it would break
	the off-Roblox spec runner), so the spec asserts they match.

	SYMMETRY: everything appended through `mirror()` is emitted twice, the second
	time rotated 180 degrees about the map centre ((x, z) -> (-x, -z)). Anything
	placed with plain `add()` sits on the centre line or is written out
	symmetrically by hand (the two spawn rooms).
]]

local HALF_X = 90 -- arena spans x in [-90, 90]
local HALF_Z = 70 -- arena spans z in [-70, 70]
local WALL_HEIGHT = 30
local WALL_THICKNESS = 6
local CEILING_Y = 31

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
	Appends `element` and its 180-degree twin.
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

-- Shell -------------------------------------------------------------------

add({
	kind = "floor",
	pos = { x = 0, y = -2, z = 0 },
	size = { x = HALF_X * 2, y = 4, z = HALF_Z * 2 },
	color = "Floor",
})

add({
	kind = "block",
	pos = { x = 0, y = 0.2, z = 0 },
	size = { x = 120, y = 0.4, z = 96 },
	color = "FloorTile",
	canCollide = false,
})

mirror({
	kind = "wall",
	from = { x = -HALF_X, z = -HALF_Z },
	to = { x = HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 16,
})

mirror({
	kind = "wall",
	from = { x = -HALF_X, z = HALF_Z },
	to = { x = -HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 16,
})

-- A full tiled ceiling: Mirage is indoors, and it is also what stops anyone
-- from rocket-jumping out of the arena.
add({
	kind = "tiledCeiling",
	pos = { x = 0, y = CEILING_Y, z = 0 },
	size = { x = HALF_X * 2 + 4, z = HALF_Z * 2 + 4 },
	height = 2,
	tile = 30,
	color = "CeilingTile",
	gapColor = "Ceiling",
})

mirror({
	kind = "neonStrip",
	pos = { x = 0, y = CEILING_Y - 1.6, z = -22 },
	size = { x = 168, y = 0.9, z = 2.4 },
	color = "Neon",
})

mirror({
	kind = "neonStrip",
	pos = { x = 0, y = CEILING_Y - 1.6, z = -52 },
	size = { x = 168, y = 0.9, z = 2.4 },
	color = "Neon",
})

-- Spawn rooms -------------------------------------------------------------

add({
	kind = "spawnRoom",
	team = "A",
	center = { x = -72, z = 0 },
	size = { x = 26, y = 22, z = 40 },
	doorSide = "+x",
	doorWidth = 16,
	spawnCount = 8,
	color = "WallDeep",
	floorColor = "Floor",
	ceilingColor = "Ceiling",
	neonColor = "TeamA",
	neonStripY = 12,
})

add({
	kind = "spawnRoom",
	team = "B",
	center = { x = 72, z = 0 },
	size = { x = 26, y = 22, z = 40 },
	doorSide = "-x",
	doorWidth = 16,
	spawnCount = 8,
	color = "WallDeep",
	floorColor = "Floor",
	ceilingColor = "Ceiling",
	neonColor = "TeamB",
	neonStripY = 12,
})

-- Green side rooms --------------------------------------------------------
-- Two declared, four built. Each backs onto a long wall, opens toward its own
-- half through the +z door and flanks the middle through the side door.

mirror({
	kind = "room",
	center = { x = -36, z = -51 },
	size = { x = 38, y = 20, z = 36 },
	doorways = {
		{ side = "+z", width = 13 },
		{ side = "+x", width = 12 },
	},
	color = "Green",
	floorColor = "GreenDark",
	ceilingColor = "GreenDark",
	neonColor = "NeonGreen",
	neonStripY = 11,
})

mirror({
	kind = "room",
	center = { x = 36, z = -51 },
	size = { x = 38, y = 20, z = 36 },
	doorways = {
		{ side = "+z", width = 13 },
		{ side = "-x", width = 12 },
	},
	color = "Green",
	floorColor = "GreenDark",
	ceilingColor = "GreenDark",
	neonColor = "NeonGreen",
	neonStripY = 11,
})

-- Middle ------------------------------------------------------------------

add({
	kind = "block",
	pos = { x = 0, y = 3, z = 0 },
	size = { x = 36, y = 6, z = 28 },
	color = "WallDeep",
	studs = true,
	studColor = "Wall",
})

add({
	kind = "block",
	pos = { x = 0, y = 13, z = 0 },
	size = { x = 14, y = 14, z = 14 },
	color = "Wall",
	studs = true,
	studColor = "WallDeep",
})

add({
	kind = "neonStrip",
	pos = { x = 0, y = 20.4, z = 0 },
	size = { x = 16, y = 1.2, z = 16 },
	color = "Neon",
})

-- Ramps onto the middle; the +11 degree tilt raises the +x end and mirror()
-- negates it for the far side. The centre height is chosen so the high end
-- lands level with the 6-stud platform and the low end meets the floor:
-- y + (length/2)*sin(t) + (thickness/2)*cos(t) == 6.
mirror({
	kind = "ramp",
	pos = { x = -30, y = 2.4, z = 0 },
	size = { x = 26, y = 2.2, z = 24 },
	color = "WallDeep",
	rotation = { x = 0, y = 0, z = 11 },
})

-- Corridor walls ----------------------------------------------------------

mirror({
	kind = "wall",
	from = { x = -20, z = -33 },
	to = { x = -20, z = -14 },
	height = 20,
	thickness = 5,
	color = "Wall",
	trim = true,
	neonStripY = 11,
})

mirror({
	kind = "wall",
	from = { x = -56, z = -18 },
	to = { x = -30, z = -18 },
	height = 20,
	thickness = 5,
	color = "Wall",
	trim = true,
	neonStripY = 11,
})

-- Cover -------------------------------------------------------------------

-- The band between the green rooms (z = -30.5) and the corridor wall
-- (z = -20.5) is only ten studs deep, so cover there is deliberately shallow.
-- Nothing sits within 4 studs of z = 0 on team A's side: that line is the
-- spawn doorway.
local cover = {
	{ pos = { x = -46, y = 2.5, z = -25.5 }, size = { x = 12, y = 5, z = 8 }, color = "Green", studs = true },
	{ pos = { x = -28, y = 3, z = -25.5 }, size = { x = 10, y = 6, z = 8 }, color = "WallDeep" },
	{ pos = { x = -46, y = 2.5, z = 24 }, size = { x = 12, y = 5, z = 12 }, color = "Wall", studs = true },
	{ pos = { x = -8, y = 2.5, z = -26 }, size = { x = 12, y = 5, z = 10 }, color = "WallDeep" },
	{ pos = { x = -50, y = 4, z = 10 }, size = { x = 10, y = 8, z = 12 }, color = "Wall" },
}

for _, block in cover do
	mirror({
		kind = "block",
		pos = block.pos,
		size = block.size,
		color = block.color,
		studs = block.studs,
	})
end

mirror({
	kind = "neonStrip",
	pos = { x = 0, y = 0.15, z = -33 },
	size = { x = 150, y = 0.4, z = 1.6 },
	color = "NeonGreen",
})

local MirageDef = {
	id = "Mirage",
	displayName = "Mirage",
	origin = { x = 4000, y = 0, z = 0 },
	killY = -60,

	palette = {
		Floor = { r = 58, g = 46, b = 78 },
		FloorTile = { r = 74, g = 58, b = 100 },
		Wall = { r = 112, g = 70, b = 176 },
		WallDeep = { r = 88, g = 52, b = 148 },
		Trim = { r = 176, g = 178, b = 196 },
		Neon = { r = 128, g = 226, b = 255 },
		NeonGreen = { r = 96, g = 245, b = 132 },
		Green = { r = 54, g = 168, b = 98 },
		GreenDark = { r = 38, g = 132, b = 78 },
		Ceiling = { r = 44, g = 36, b = 60 },
		CeilingTile = { r = 96, g = 76, b = 138 },
		Board = { r = 26, g = 30, b = 42 },
		TeamA = { r = 45, g = 216, b = 129 },
		TeamB = { r = 235, g = 87, b = 158 },
	},

	elements = elements,
}

return MirageDef
