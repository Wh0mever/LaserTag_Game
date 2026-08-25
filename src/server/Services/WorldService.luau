--!nonstrict
--[[
	WorldService.luau
	Owns the 3D world: collision groups, lighting and the three built maps.

	Priority 3 — after TeamService, before PlayerService, because PlayerService
	cannot spawn anybody until the spawn CFrames exist. The build itself happens
	in start() and never yields, so by the time PlayerService.start() runs the
	maps are already standing; anything that needs to be sure can poll
	WorldService.isBuilt().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Constants = require(Shared.Constants)
local DustDef = require(Shared.MapDefs.DustDef)
local GameConfig = require(Shared.Config.GameConfig)
local HubDef = require(Shared.MapDefs.HubDef)
local LightingSetup = require(script.Parent.Parent.World.LightingSetup)
local MapBuilder = require(script.Parent.Parent.World.MapBuilder)
local MirageDef = require(Shared.MapDefs.MirageDef)
local SpawnDoors = require(script.Parent.Parent.World.SpawnDoors)

local WorldService = {}

WorldService.Priority = 3

-- Build order matters only for logging; the hub is first because it is where
-- everyone lands.
local DEFS = { HubDef, DustDef, MirageDef }

-- Above every map so a fallback spawn can never drop a player through the floor.
local FALLBACK_SPAWN_HEIGHT = 12

local maps: { [string]: any } = {}
local spawnCursor: { [string]: number } = {}
local built = false

function WorldService.init()
	SpawnDoors.setupCollisionGroups()
	LightingSetup.apply()
end

function WorldService.start()
	if built then
		return
	end

	for _, def in DEFS do
		local ok, result = pcall(MapBuilder.build, def)
		if ok then
			maps[def.id] = result
			print(
				`[WorldService] {def.id}: {result.partCount} parts | spawns A={#result.spawns.A} `
					.. `B={#result.spawns.B} Lobby={#result.spawns.Lobby}`
			)
		else
			warn(`[WorldService] failed to build {def.id}: {result}`)
		end
	end

	built = true
end

--[[
	BuildResult for a map id, or nil if it has not been built.
	BuildResult = {model, spawns = {A, B, Lobby}, portals = {{mapId, padPart, gui}},
	               boards = {[boardId] = SurfaceGui}, killY, origin, partCount}
]]
function WorldService.getMap(mapId: string): { [string]: any }?
	return maps[mapId]
end

function WorldService.isBuilt(): boolean
	return built
end

--[[
	A spawn CFrame for `teamId` on `mapId`. With no index, spawns are handed out
	round-robin so two players respawning together do not land inside each other.
	Falls back to the map's lobby spawns, then to a point above the map origin.
]]
function WorldService.getSpawn(mapId: string, teamId: string, index: number?): CFrame
	local map = maps[mapId] or maps[Constants.HUB_ID]
	if not map then
		return CFrame.new(0, FALLBACK_SPAWN_HEIGHT, 0)
	end

	local list = map.spawns[teamId]
	if not list or #list == 0 then
		list = map.spawns.Lobby
	end
	if not list or #list == 0 then
		return CFrame.new(map.origin + Vector3.new(0, FALLBACK_SPAWN_HEIGHT, 0))
	end

	local chosen
	if index then
		chosen = ((math.floor(index) - 1) % #list) + 1
	else
		local key = `{mapId}|{teamId}`
		chosen = ((spawnCursor[key] or 0) % #list) + 1
		spawnCursor[key] = chosen
	end

	return list[chosen]
end

function WorldService.getHubSpawn(): CFrame
	return WorldService.getSpawn(Constants.HUB_ID, "Lobby")
end

--[[
	Every walk-on portal pad in the world, in map build order. Only the hub has
	portals, so this is the queue system's list of pads to sample.
]]
function WorldService.getPortalPads(): { { [string]: any } }
	local pads = {}
	for _, def in DEFS do
		local map = maps[def.id]
		if map then
			for _, portal in map.portals do
				table.insert(pads, { mapId = portal.mapId, padPart = portal.padPart, gui = portal.gui })
			end
		end
	end
	return pads
end

--[[
	SurfaceGui for a board id (currently only "TopKills", in the hub). The gui
	has a "Root" Frame containing a "Title" TextLabel and a "Content" Frame with
	a UIListLayout — LeaderboardService fills Content with rows.
]]
function WorldService.getBoard(boardId: string): SurfaceGui?
	for _, def in DEFS do
		local map = maps[def.id]
		local board = map and map.boards[boardId]
		if board then
			return board
		end
	end
	return nil
end

--[[
	Absolute world Y below which a character on `mapId` is considered fallen.
]]
function WorldService.getKillY(mapId: string): number
	local map = maps[mapId]
	if map then
		return map.killY
	end
	return GameConfig.DEFAULT_KILL_Y
end

--[[
	Part count for one built map, for budget checks (see sharp-edges.md SE-7).
]]
function WorldService.getPartCount(mapId: string): number
	local map = maps[mapId]
	return map and map.partCount or 0
end

return WorldService
