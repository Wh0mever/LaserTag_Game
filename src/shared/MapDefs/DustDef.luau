--!nonstrict
--[[
	DustDef.luau
	"Dust" — a 220 x 180 sand-coloured outdoor TDM arena. Two spawn rooms at
	opposite ends, three lanes (north / mid / south) linked by rotation gaps, and
	a raised middle plateau that both teams have to climb to.

	Pure data — no Roblox API — so tests/MapDefs.spec.luau can require it off
	Roblox. `origin` and `killY` mirror GameConfig.MAP_ORIGINS.Dust and
	GameConfig.DEFAULT_KILL_Y; MapDefs cannot require GameConfig (it would break
	the off-Roblox spec runner), so the spec asserts they match.

	SYMMETRY: everything appended through `mirror()` is emitted twice, the second
	time rotated 180 degrees about the map centre ((x, z) -> (-x, -z)). That is
	the only way to guarantee neither team has an advantage; anything placed with
	plain `add()` is either on the centre line or written out symmetrically by
	hand (the two spawn rooms).
]]

local HALF_X = 110 -- arena spans x in [-110, 110]
local HALF_Z = 90 -- arena spans z in [-90, 90]
local WALL_HEIGHT = 46 -- unjumpable, so nobody can leave the arena
local WALL_THICKNESS = 6

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
	color = "Sand",
	material = "Sand",
})

-- Two walls declared, four built: the north wall mirrors to the south wall and
-- the west wall to the east wall.
mirror({
	kind = "wall",
	from = { x = -HALF_X, z = -HALF_Z },
	to = { x = HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 22,
})

mirror({
	kind = "wall",
	from = { x = -HALF_X, z = HALF_Z },
	to = { x = -HALF_X, z = -HALF_Z },
	height = WALL_HEIGHT,
	thickness = WALL_THICKNESS,
	color = "Wall",
	trim = true,
	neonStripY = 22,
})

-- Spawn rooms -------------------------------------------------------------
-- Written out by hand rather than mirrored so the team ids stay explicit.

add({
	kind = "spawnRoom",
	team = "A",
	center = { x = -92, z = 0 },
	size = { x = 34, y = 20, z = 48 },
	doorSide = "+x",
	doorWidth = 18,
	spawnCount = 8,
	color = "Wall",
	floorColor = "SandDark",
	ceilingColor = "Roof",
	neonColor = "TeamA",
	neonStripY = 11,
})

add({
	kind = "spawnRoom",
	team = "B",
	center = { x = 92, z = 0 },
	size = { x = 34, y = 20, z = 48 },
	doorSide = "-x",
	doorWidth = 18,
	spawnCount = 8,
	color = "Wall",
	floorColor = "SandDark",
	ceilingColor = "Roof",
	neonColor = "TeamB",
	neonStripY = 11,
})

-- Lane dividers -----------------------------------------------------------
-- Two long walls at z = -30 and z = +30, each broken in the middle so players
-- can rotate between lanes without walking all the way back to spawn.

mirror({
	kind = "wall",
	from = { x = -72, z = -30 },
	to = { x = -24, z = -30 },
	height = 20,
	thickness = 8,
	color = "WallDark",
	trim = true,
	neonStripY = 10,
})

mirror({
	kind = "wall",
	from = { x = 24, z = -30 },
	to = { x = 72, z = -30 },
	height = 20,
	thickness = 8,
	color = "WallDark",
	trim = true,
	neonStripY = 10,
})

-- Raised middle -----------------------------------------------------------

add({
	kind = "block",
	pos = { x = 0, y = 3, z = 0 },
	size = { x = 46, y = 6, z = 30 },
	color = "SandDark",
	studs = true,
	studColor = "Sand",
})

-- Ramps up onto the plateau from both lanes; the +14 degree tilt raises the +x
-- end, and mirror() negates it for the far side. The centre height is chosen so
-- the high end lands level with the 6-stud plateau and the low end meets the
-- floor: y + (length/2)*sin(t) + (thickness/2)*cos(t) == 6.
mirror({
	kind = "ramp",
	pos = { x = -32, y = 2, z = 0 },
	size = { x = 26, y = 2.4, z = 26 },
	color = "SandDark",
	rotation = { x = 0, y = 0, z = 14 },
})

mirror({
	kind = "block",
	pos = { x = -15, y = 9, z = -10 },
	size = { x = 10, y = 6, z = 8 },
	color = "Crate",
	studs = true,
})

-- Shade roof over the middle so the plateau reads as a landmark from the lanes.
add({
	kind = "tiledCeiling",
	pos = { x = 0, y = 26, z = 0 },
	size = { x = 62, z = 40 },
	height = 2,
	tile = 20,
	color = "Roof",
	gapColor = "WallDark",
})

for _, spot in { { x = -28, z = -18 }, { x = 28, z = -18 }, { x = -28, z = 18 }, { x = 28, z = 18 } } do
	add({
		kind = "block",
		pos = { x = spot.x, y = 12.5, z = spot.z },
		size = { x = 4, y = 25, z = 4 },
		color = "Metal",
		material = "Metal",
	})
end

-- Sites -------------------------------------------------------------------
-- One walled building per outer lane, backed onto the perimeter wall, with a
-- door into the lane and a door toward mid. mirror() puts the twin in the
-- opposite corner so both teams get the same approach.

mirror({
	kind = "room",
	center = { x = -58, z = -66 },
	size = { x = 40, y = 16, z = 40 },
	doorways = {
		{ side = "+x", width = 14 },
		{ side = "+z", width = 14 },
	},
	color = "Wall",
	floorColor = "SandDark",
	ceilingColor = "Roof",
	trim = true,
	neonStripY = 8,
})

-- Cover ------------------------------------------------------------------
-- One half of the arena; mirror() supplies the other.

local cover = {
	-- Inside the site building.
	{ pos = { x = -64, y = 3, z = -66 }, size = { x = 14, y = 6, z = 14 }, color = "Crate", studs = true },
	{ pos = { x = -50, y = 4, z = -78 }, size = { x = 16, y = 8, z = 12 }, color = "CrateDark" },
	-- North lane, outside the site.
	{ pos = { x = -28, y = 2.5, z = -46 }, size = { x = 12, y = 5, z = 20 }, color = "Crate" },
	{ pos = { x = -18, y = 3, z = -68 }, size = { x = 12, y = 6, z = 12 }, color = "CrateDark", studs = true },
	{ pos = { x = 6, y = 5, z = -48 }, size = { x = 10, y = 10, z = 22 }, color = "WallDark" },
	-- Mid lane, approach to the plateau. Kept clear of z = 0 so it never stands
	-- in the spawn doorway.
	{ pos = { x = -58, y = 3.5, z = -16 }, size = { x = 14, y = 7, z = 16 }, color = "CrateDark" },
	{ pos = { x = -58, y = 2.5, z = 16 }, size = { x = 12, y = 5, z = 12 }, color = "Crate", studs = true },
	-- Barrels out in the open.
	{ pos = { x = -46, y = 2, z = 20 }, size = { x = 8, y = 4, z = 8 }, color = "Crate" },
	{ pos = { x = -40, y = 2, z = 46 }, size = { x = 10, y = 4, z = 10 }, color = "CrateDark" },
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

-- Sandbag ridges: too tall to jump (a Roblox character clears about 6.4 studs),
-- so they read as hard cover rather than as a step.
mirror({
	kind = "wall",
	from = { x = -26, z = -84 },
	to = { x = -26, z = -62 },
	height = 9,
	thickness = 6,
	color = "SandDark",
	trim = true,
})

mirror({
	kind = "wall",
	from = { x = 30, z = -86 },
	to = { x = 66, z = -86 },
	height = 9,
	thickness = 6,
	color = "SandDark",
	trim = true,
})

-- Neon lane markers on the open floor, so the three lanes read at a glance.
mirror({
	kind = "neonStrip",
	pos = { x = 8, y = 0.15, z = -60 },
	size = { x = 60, y = 0.4, z = 1.6 },
	color = "Neon",
})

local DustDef = {
	id = "Dust",
	displayName = "Dust",
	origin = { x = 2000, y = 0, z = 0 },
	killY = -60,

	palette = {
		Sand = { r = 226, g = 199, b = 148 },
		SandDark = { r = 196, g = 164, b = 114 },
		Wall = { r = 214, g = 178, b = 122 },
		WallDark = { r = 168, g = 130, b = 86 },
		Trim = { r = 248, g = 246, b = 238 },
		Crate = { r = 188, g = 128, b = 68 },
		CrateDark = { r = 148, g = 96, b = 48 },
		Roof = { r = 236, g = 214, b = 168 },
		Metal = { r = 126, g = 132, b = 140 },
		Neon = { r = 255, g = 176, b = 64 },
		Board = { r = 26, g = 30, b = 42 },
		TeamA = { r = 45, g = 216, b = 129 },
		TeamB = { r = 235, g = 87, b = 158 },
	},

	elements = elements,
}

return DustDef
