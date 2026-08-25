--!nonstrict
--[[
	HubDef.luau
	The Hub plaza: where players land, queue for a map and read the Top Kills
	board. Pure data — no Roblox API — so tests/MapDefs.spec.luau can require it
	off Roblox. src/server/World/MapBuilder.luau turns it into geometry.

	Every position is relative to `origin`; MapBuilder adds the origin exactly
	once. `origin` and `killY` mirror GameConfig.MAP_ORIGINS.Hub and
	GameConfig.DEFAULT_KILL_Y — MapDefs cannot require GameConfig (it would break
	the off-Roblox spec runner), so tests/MapDefs.spec.luau asserts they match.
]]

local HALF = 100 -- the plaza is 200 x 200 studs, walled on all four sides
local WALL_HEIGHT = 26
local WALL_THICKNESS = 5

local elements = {}

local function add(element)
	table.insert(elements, element)
	return element
end

-- Ground ------------------------------------------------------------------

add({
	kind = "floor",
	pos = { x = 0, y = -2, z = 0 },
	size = { x = HALF * 2, y = 4, z = HALF * 2 },
	color = "Ground",
})

-- Inlaid centre tile, purely visual; low enough to walk over.
add({
	kind = "block",
	pos = { x = 0, y = 0.2, z = 0 },
	size = { x = 96, y = 0.4, z = 96 },
	color = "GroundAlt",
	canCollide = false,
})

add({
	kind = "block",
	pos = { x = 0, y = 0.3, z = 0 },
	size = { x = 30, y = 0.4, z = 30 },
	color = "Accent",
	canCollide = false,
})

-- Perimeter ---------------------------------------------------------------

local corners = {
	{ x = -HALF, z = -HALF },
	{ x = HALF, z = -HALF },
	{ x = HALF, z = HALF },
	{ x = -HALF, z = HALF },
}

for index, from in corners do
	add({
		kind = "wall",
		from = from,
		to = corners[(index % #corners) + 1],
		height = WALL_HEIGHT,
		thickness = WALL_THICKNESS,
		color = "Wall",
		trim = true,
		neonStripY = 13,
	})
end

-- Portals -----------------------------------------------------------------
-- Exactly two, one per playable map. QueueService reads padPart from the
-- BuildResult and writes queue counts into the SurfaceGui's "Status" label.

add({
	kind = "portal",
	mapId = "Dust",
	pos = { x = -44, y = 0, z = -48 },
	padSize = { x = 20, y = 1.2, z = 20 },
})

add({
	kind = "portal",
	mapId = "Mirage",
	pos = { x = 44, y = 0, z = -48 },
	padSize = { x = 20, y = 1.2, z = 20 },
})

-- Top Kills board, mounted flat against the north wall facing the plaza.
add({
	kind = "board",
	boardId = "TopKills",
	pos = { x = 0, y = 17, z = -94 },
	size = { x = 56, y = 28, z = 1.6 },
	facing = "+z",
	title = "TOP KILLS",
})

-- Lobby ------------------------------------------------------------------

add({
	kind = "lobbySpawn",
	pos = { x = 0, y = 0, z = 62 },
	size = { x = 52, y = 0, z = 30 },
	count = 16,
	color = "Neon",
})

-- Canopy over the landing area, on four white pillars.
for _, pillar in { { x = -32, z = 44 }, { x = 32, z = 44 }, { x = -32, z = 80 }, { x = 32, z = 80 } } do
	add({
		kind = "block",
		pos = { x = pillar.x, y = 11, z = pillar.z },
		size = { x = 5, y = 22, z = 5 },
		color = "Trim",
	})
end

add({
	kind = "tiledCeiling",
	pos = { x = 0, y = 23, z = 62 },
	size = { x = 74, z = 44 },
	height = 2,
	tile = 18,
	color = "Canopy",
	gapColor = "Trim",
})

add({
	kind = "neonStrip",
	pos = { x = 0, y = 21.6, z = 40 },
	size = { x = 74, y = 1.2, z = 1.6 },
	color = "Neon",
})

add({
	kind = "neonStrip",
	pos = { x = 0, y = 21.6, z = 84 },
	size = { x = 74, y = 1.2, z = 1.6 },
	color = "Neon",
})

-- Scenery ----------------------------------------------------------------

-- Planters: an orange Lego box with a studded hedge sitting in it.
for _, spot in { { x = -66, z = -66 }, { x = 66, z = -66 }, { x = -66, z = 66 }, { x = 66, z = 66 } } do
	add({
		kind = "block",
		pos = { x = spot.x, y = 3, z = spot.z },
		size = { x = 24, y = 6, z = 24 },
		color = "Planter",
	})
	add({
		kind = "block",
		pos = { x = spot.x, y = 8, z = spot.z },
		size = { x = 20, y = 4, z = 20 },
		color = "Hedge",
		studs = true,
	})
end

-- Low decorative walls flanking the portal approach.
for _, sign in { -1, 1 } do
	add({
		kind = "wall",
		from = { x = sign * 20, z = -20 },
		to = { x = sign * 74, z = -20 },
		height = 7,
		thickness = 4,
		color = "Wall",
		trim = true,
		neonStripY = 4,
	})
	add({
		kind = "wall",
		from = { x = sign * 74, z = -20 },
		to = { x = sign * 74, z = -46 },
		height = 7,
		thickness = 4,
		color = "Wall",
		trim = true,
		neonStripY = 4,
	})
	-- Studded benches either side of the centre tile.
	add({
		kind = "block",
		pos = { x = sign * 34, y = 2, z = 18 },
		size = { x = 22, y = 4, z = 8 },
		color = "Accent",
		studs = true,
	})
end

-- A pair of chunky corner towers so the skyline is not four flat walls.
for _, spot in { { x = -HALF + 8, z = -HALF + 8 }, { x = HALF - 8, z = -HALF + 8 } } do
	add({
		kind = "block",
		pos = { x = spot.x, y = 17, z = spot.z },
		size = { x = 18, y = 34, z = 18 },
		color = "Wall",
	})
	add({
		kind = "block",
		pos = { x = spot.x, y = 35, z = spot.z },
		size = { x = 20, y = 2, z = 20 },
		color = "Trim",
		studs = true,
	})
end

local HubDef = {
	id = "Hub",
	displayName = "Hub Plaza",
	origin = { x = 0, y = 0, z = 0 },
	killY = -60,

	palette = {
		Ground = { r = 198, g = 204, b = 214 },
		GroundAlt = { r = 168, g = 176, b = 190 },
		Wall = { r = 58, g = 96, b = 176 },
		Trim = { r = 246, g = 248, b = 252 },
		Neon = { r = 88, g = 214, b = 255 },
		Accent = { r = 235, g = 87, b = 158 },
		Planter = { r = 224, g = 98, b = 70 },
		Hedge = { r = 74, g = 178, b = 90 },
		Canopy = { r = 240, g = 196, b = 66 },
		Board = { r = 26, g = 30, b = 42 },
		PortalDust = { r = 240, g = 186, b = 92 },
		PortalMirage = { r = 168, g = 112, b = 246 },
	},

	elements = elements,
}

return HubDef
