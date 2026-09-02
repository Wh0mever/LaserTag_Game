--!nonstrict
local Constants = require("../src/shared/Constants")
local DustDef = require("../src/shared/MapDefs/DustDef")
local GameConfig = require("../src/shared/Config/GameConfig")
local HubDef = require("../src/shared/MapDefs/HubDef")
local MirageDef = require("../src/shared/MapDefs/MirageDef")
local NexusDef = require("../src/shared/MapDefs/NexusDef")

-- Every kind MapBuilder knows how to interpret. A def using anything else would
-- silently build nothing, so the set is asserted rather than assumed.
local ALLOWED_KINDS = {
	floor = true,
	block = true,
	wall = true,
	neonStrip = true,
	tiledCeiling = true,
	ramp = true,
	room = true,
	spawnRoom = true,
	portal = true,
	board = true,
	sign = true,
	lobbySpawn = true,
}

local HUB_ONLY_KINDS = { portal = true, board = true }

local function countKinds(def)
	local counts = {}
	for _, element in def.elements do
		counts[element.kind] = (counts[element.kind] or 0) + 1
	end
	return counts
end

local function elementsOfKind(def, kind)
	local list = {}
	for _, element in def.elements do
		if element.kind == kind then
			table.insert(list, element)
		end
	end
	return list
end

local function isRgb(value): boolean
	if type(value) ~= "table" then
		return false
	end
	for _, channel in { "r", "g", "b" } do
		local component = value[channel]
		if type(component) ~= "number" or component < 0 or component > 255 or component % 1 ~= 0 then
			return false
		end
	end
	return true
end

return function(t)
	local defs = {
		{ name = "Hub", def = HubDef },
		{ name = "Dust", def = DustDef },
		{ name = "Mirage", def = MirageDef },
		{ name = "Nexus", def = NexusDef },
	}

	-- Shape of every def --------------------------------------------------
	for _, entry in defs do
		local def, name = entry.def, entry.name

		t.equal(def.id, name, `{name} def has the expected id`)
		t.expect(type(def.displayName) == "string" and #def.displayName > 0, `{name} has a displayName`)
		t.expect(type(def.elements) == "table" and #def.elements > 0, `{name} has elements`)

		local origin = def.origin
		t.expect(
			type(origin) == "table"
				and type(origin.x) == "number"
				and type(origin.y) == "number"
				and type(origin.z) == "number",
			`{name} origin is a numeric {"{x, y, z}"} table`
		)

		-- MapDefs cannot require GameConfig (the spec runner has no Roblox
		-- instance tree), so the two are kept in step here instead.
		local configured = GameConfig.MAP_ORIGINS[name]
		t.expect(configured ~= nil, `GameConfig knows about {name}`)
		if configured then
			t.deepEqual(origin, configured, `{name} origin matches GameConfig.MAP_ORIGINS.{name}`)
		end

		t.expect(type(def.killY) == "number" and def.killY < 0, `{name} killY is below the floor`)
		t.equal(def.killY, GameConfig.DEFAULT_KILL_Y, `{name} killY matches GameConfig.DEFAULT_KILL_Y`)

		-- Elements
		local unknown = nil
		for index, element in def.elements do
			if type(element) ~= "table" or not ALLOWED_KINDS[element.kind] then
				unknown = `#{index}: {tostring(type(element) == "table" and element.kind or element)}`
				break
			end
		end
		t.equal(unknown, nil, `{name} uses only known element kinds`)

		-- Palette
		local badKey = nil
		local paletteCount = 0
		for key, rgb in def.palette do
			paletteCount += 1
			if type(key) ~= "string" or not isRgb(rgb) then
				badKey = tostring(key)
				break
			end
		end
		t.expect(paletteCount > 0, `{name} has a palette`)
		t.equal(badKey, nil, `{name} palette holds only 0-255 rgb triples`)

		-- Colour keys referenced by elements must exist in the palette.
		local missingColor = nil
		for index, element in def.elements do
			for _, field in { "color", "trimColor", "neonColor", "floorColor", "ceilingColor", "studColor", "gapColor" } do
				local key = element[field]
				if key ~= nil and def.palette[key] == nil then
					missingColor = `#{index} {field}={tostring(key)}`
					break
				end
			end
			if missingColor then
				break
			end
		end
		t.equal(missingColor, nil, `{name} only references palette colours that exist`)
	end

	-- Hub-only element kinds ----------------------------------------------
	for _, entry in defs do
		local counts = countKinds(entry.def)
		for kind in HUB_ONLY_KINDS do
			if entry.name == "Hub" then
				t.expect((counts[kind] or 0) > 0, `Hub contains at least one {kind}`)
			else
				t.equal(counts[kind] or 0, 0, `{entry.name} contains no {kind} elements`)
			end
		end
	end

	-- Hub specifics --------------------------------------------------------
	local portals = elementsOfKind(HubDef, "portal")
	t.equal(#portals, #Constants.MAPS, "the hub has one portal per playable map")

	local portalMaps = {}
	for _, portal in portals do
		portalMaps[portal.mapId] = (portalMaps[portal.mapId] or 0) + 1
		t.expect(
			type(portal.padSize) == "table" and portal.padSize.x > 0 and portal.padSize.z > 0,
			`hub portal to {tostring(portal.mapId)} has a walk-on pad`
		)
	end
	-- Derived from Constants.MAPS rather than named one by one: the hub must
	-- carry a portal for exactly the maps the rest of the game thinks are
	-- playable, and adding a map should fail here if its portal was forgotten.
	for _, mapId in Constants.MAPS do
		t.equal(portalMaps[mapId], 1, `the hub has exactly one {mapId} portal`)
	end

	-- The name on the gateway sign ----------------------------------------
	--
	-- The hub sign is the only place inside the game a player is shown what the
	-- game is called, and HubDef spells the words out because MapDefs require
	-- nothing. So a rename that touches Constants and forgets the sign — or the
	-- reverse — leaves the arena advertising the old name to every player who
	-- walks under it, with nothing else in the build to notice. This is the
	-- notice.
	local signs = elementsOfKind(HubDef, "sign")
	t.equal(#signs, 1, "the hub carries exactly one name sign")

	local nameSign = signs[1]
	if nameSign then
		t.expect(type(nameSign.lines) == "table" and #nameSign.lines > 0, "the hub sign has at least one line of text")
		t.equal(
			table.concat(nameSign.lines or {}, " "),
			Constants.GAME_NAME,
			"the hub sign spells out Constants.GAME_NAME"
		)
		t.equal(
			string.upper(Constants.GAME_NAME),
			Constants.GAME_NAME,
			"GAME_NAME is upper case, which is how the sign renders it"
		)
		-- Posts have to reach the ground: a sign hanging in mid-air over the
		-- walkway is a modelling mistake that only a screenshot would catch.
		t.equal(
			nameSign.pos.y - nameSign.size.y * 0.5 - (nameSign.postHeight or 0),
			0,
			"the hub sign's posts stand on the plaza floor"
		)
	end

	local lobbySpawns = elementsOfKind(HubDef, "lobbySpawn")
	t.expect(#lobbySpawns >= 1, "the hub has at least one lobbySpawn")
	local lobbyTotal = 0
	for _, spawn in lobbySpawns do
		lobbyTotal += spawn.count or 0
	end
	t.expect(lobbyTotal >= GameConfig.MAX_PLAYERS_PER_MATCH, "the hub can hold a full match's worth of players")

	local boards = elementsOfKind(HubDef, "board")
	local topKills = nil
	for _, board in boards do
		if board.boardId == "TopKills" then
			topKills = board
		end
	end
	t.expect(topKills ~= nil, "the hub has a board with boardId TopKills")

	-- The hub must be closed, or players walk off the plaza into the void.
	t.expect(#elementsOfKind(HubDef, "wall") >= 4, "the hub is enclosed by at least four walls")

	-- Playable maps --------------------------------------------------------
	for _, entry in
		{ { name = "Dust", def = DustDef }, { name = "Mirage", def = MirageDef }, { name = "Nexus", def = NexusDef } }
	do
		local rooms = elementsOfKind(entry.def, "spawnRoom")
		t.equal(#rooms, 2, `{entry.name} has exactly two spawn rooms`)

		local byTeam = {}
		for _, room in rooms do
			byTeam[room.team] = room
		end
		t.expect(byTeam.A ~= nil, `{entry.name} has a team A spawn room`)
		t.expect(byTeam.B ~= nil, `{entry.name} has a team B spawn room`)

		if byTeam.A and byTeam.B then
			t.equal(byTeam.A.spawnCount, byTeam.B.spawnCount, `{entry.name} spawn rooms hold equal numbers of players`)
			t.expect(
				byTeam.A.spawnCount >= GameConfig.MAX_PLAYERS_PER_MATCH / 2,
				`{entry.name} fits half a full match per side`
			)

			-- 180-degree rotational symmetry: neither team gets the better end.
			t.equal(byTeam.A.center.x, -byTeam.B.center.x, `{entry.name} spawn rooms are mirrored on x`)
			t.equal(byTeam.A.center.z, -byTeam.B.center.z, `{entry.name} spawn rooms are mirrored on z`)
			t.deepEqual(byTeam.A.size, byTeam.B.size, `{entry.name} spawn rooms are the same size`)
		end

		t.expect(#elementsOfKind(entry.def, "wall") >= 4, `{entry.name} is enclosed by at least four walls`)
		t.expect(#elementsOfKind(entry.def, "floor") >= 1, `{entry.name} has a floor`)
	end

	-- Separation -----------------------------------------------------------
	for i = 1, #defs do
		for j = i + 1, #defs do
			local a, b = defs[i], defs[j]
			local dx = a.def.origin.x - b.def.origin.x
			local dy = a.def.origin.y - b.def.origin.y
			local dz = a.def.origin.z - b.def.origin.z
			local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			t.expect(
				distance >= GameConfig.MIN_MAP_SEPARATION,
				`{a.name} and {b.name} origins are at least {GameConfig.MIN_MAP_SEPARATION} studs apart (got {distance})`
			)
		end
	end

	-- Part budget guard ----------------------------------------------------
	-- Element count is a lower bound on part count; the real ceiling is checked
	-- at build time, but a def that has ballooned shows up here first.
	for _, entry in defs do
		t.expect(#entry.def.elements <= 400, `{entry.name} stays within a sane element count`)
	end
end
