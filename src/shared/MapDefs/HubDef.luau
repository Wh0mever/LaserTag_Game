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

-- Gateway -----------------------------------------------------------------
-- The name, over the walkway between the two decorative walls at z = -20.
-- Placed here rather than on a wall because this is the one line every player
-- crosses: they land at z = +62 and walk north to the portals, so the sign is
-- ahead of them from the moment they spawn and behind them for the rest of the
-- match. Nothing else in the game shows what the game is called.
--
-- The text must stay in step with Constants.GAME_NAME. MapDefs deliberately
-- require nothing (the off-Roblox spec runner loads them bare), so the two are
-- tied by an assertion in tests/MapDefs.spec.luau rather than by a require.
add({
	kind = "sign",
	pos = { x = 0, y = 17.5, z = -20 },
	size = { x = 36, y = 9, z = 1.2 },
	facing = "+z",
	-- Posts reach the ground: 17.5 - 4.5 - 13 = 0.
	postHeight = 13,
	lines = { "SKILLANDIA", "LASERTAG" },
})

-- Portals -----------------------------------------------------------------
-- One per playable map, spread evenly across the plaza so no pad is the
-- obvious default. QueueService reads padPart from the BuildResult and writes
-- queue counts into the SurfaceGui's "Status" label.

add({
	kind = "portal",
	mapId = "Dust",
	pos = { x = -60, y = 0, z = -48 },
	padSize = { x = 20, y = 1.2, z = 20 },
})

add({
	kind = "portal",
	mapId = "Mirage",
	pos = { x = 0, y = 0, z = -48 },
	padSize = { x = 20, y = 1.2, z = 20 },
})

add({
	kind = "portal",
	mapId = "Nexus",
	pos = { x = 60, y = 0, z = -48 },
	padSize = { x = 20, y = 1.2, z = 20 },
})

-- Top Kills board, mounted flat against the north wall facing the plaza.
add({
	kind = "board",
	boardId = "TopKills",
	pos = { x = 0, y = 17, z = -94 },
	size = { x = 56, y = 28, z = 1.6 },
	facing = "+z",
	title = "ЛУЧШИЕ СТРЕЛКИ",
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
	displayName = "Площадь",
	origin = { x = 0, y = 0, z = 0 },
	killY = -60,

	-- No ordinary surface may outrank the dimmest Neon one, and the bright end
	-- of the palette belongs to trim rather than to the plaza floor. The first
	-- version broke both — a near-white 200x200 ground under a near-white trim —
	-- and the hub rendered as a single white sheet. tests/harness/lighting.luau
	-- measures it.
	palette = {
		Ground = { r = 146, g = 154, b = 168 },
		GroundAlt = { r = 124, g = 132, b = 148 },
		Wall = { r = 58, g = 96, b = 176 },
		Trim = { r = 176, g = 182, b = 194 },
		Neon = { r = 88, g = 214, b = 255 },
		Accent = { r = 196, g = 74, b = 132 },
		Planter = { r = 186, g = 82, b = 58 },
		Hedge = { r = 74, g = 178, b = 90 },
		Canopy = { r = 198, g = 162, b = 56 },
		Board = { r = 26, g = 30, b = 42 },
		PortalDust = { r = 240, g = 186, b = 92 },
		PortalMirage = { r = 168, g = 112, b = 246 },
		PortalNexus = { r = 0, g = 229, b = 255 },
	},

	elements = elements,
}

return HubDef
