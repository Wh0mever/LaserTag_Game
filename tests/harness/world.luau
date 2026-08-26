--!nonstrict
--[[
	tests/harness/world.luau
	Builds every map for real, outside Roblox, and checks what came out.

	The world builder is the largest piece of this game that unit tests cannot
	reach: it reads the declarative map definitions and produces the entire
	playable space. Until this existed, the first time that code ran was a
	playtest, which is a slow and expensive place to discover a typo.

	This executes it against Lune's real Instance/CFrame/Enum implementations, so
	a misspelled property or an invalid class fails exactly as it would in
	Studio, and then asserts the properties a match actually depends on: both
	teams have spawns, the hub has its portals and board, spawns are inside the
	map and above the kill plane, and the part budget is sane for a phone.

	Run:  lune run tests/harness/world
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

local passed = 0
local failed = 0
local failures: { string } = {}
local currentMap = "?"

local function check(ok: boolean, message: string)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, `{currentMap} :: {message}`)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

--------------------------------------------------------------------------------
-- Load the real modules
--------------------------------------------------------------------------------

heading("Loading modules")

local MapBuilder = Env.load("src/server/World/MapBuilder")
print("  MapBuilder loaded")

local GameConfig = Env.load("src/shared/Config/GameConfig")
print("  GameConfig loaded")

local MAPS = {
	{ id = "Hub", def = Env.load("src/shared/MapDefs/HubDef"), isHub = true },
	{ id = "Dust", def = Env.load("src/shared/MapDefs/DustDef"), isHub = false },
	{ id = "Mirage", def = Env.load("src/shared/MapDefs/MirageDef"), isHub = false },
}
print(`  {#MAPS} map definitions loaded`)

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function countDescendants(instance: any): (number, { [string]: number })
	local total = 0
	local byClass: { [string]: number } = {}

	local function walk(node)
		for _, child in node:GetChildren() do
			total += 1
			byClass[child.ClassName] = (byClass[child.ClassName] or 0) + 1
			walk(child)
		end
	end

	walk(instance)
	return total, byClass
end

local results = {}

for _, entry in MAPS do
	currentMap = entry.id
	heading(`Building {entry.id}`)

	local ok, built = pcall(function()
		return MapBuilder.build(entry.def)
	end)

	if not ok then
		failed += 1
		table.insert(failures, `{entry.id} :: build threw: {built}`)
		print(`  BUILD FAILED: {built}`)
		continue
	end

	local total, byClass = countDescendants(built.model)
	results[entry.id] = { built = built, total = total, byClass = byClass }

	print(`  parts and children: {total}`)
	local classes = {}
	for className, count in byClass do
		table.insert(classes, `{className}={count}`)
	end
	table.sort(classes)
	print("  " .. table.concat(classes, "  "))

	----------------------------------------------------------------------------
	-- What a match actually depends on
	----------------------------------------------------------------------------

	check(built.model ~= nil, "build returned a model")
	check(total > 50, `map has real geometry (got {total} instances)`)

	-- A phone has to render this. The skill's own budget is well under ten
	-- thousand visible parts, and three maps exist at once in one place.
	check(total < 3000, `part count stays inside a mobile budget (got {total})`)

	if entry.isHub then
		check(built.spawns.Lobby ~= nil and #built.spawns.Lobby > 0, "hub has lobby spawns")
		check(#built.portals == 2, `hub has two portals (got {#built.portals})`)
		check(built.boards ~= nil and built.boards.TopKills ~= nil, "hub has the TopKills board")

		for _, portal in built.portals do
			check(portal.padPart ~= nil, `portal {portal.mapId} has a pad part`)
			check(portal.mapId == "Dust" or portal.mapId == "Mirage", `portal targets a real map ({portal.mapId})`)
		end
	else
		check(built.spawns.A ~= nil and #built.spawns.A > 0, "team A has spawns")
		check(built.spawns.B ~= nil and #built.spawns.B > 0, "team B has spawns")
		check(#built.spawns.A == #built.spawns.B, "both teams get the same number of spawns")
		check(#built.portals == 0, "arenas carry no portals")

		-- Spawning below the kill plane would kill players on arrival.
		local lowest = math.huge
		for _, teamId in { "A", "B" } do
			for _, cf in built.spawns[teamId] do
				lowest = math.min(lowest, cf.Position.Y)
			end
		end
		check(lowest > built.killY, `spawns sit above the kill plane ({lowest} > {built.killY})`)

		-- Teams starting on top of each other would be a broken map.
		local a = built.spawns.A[1].Position
		local b = built.spawns.B[1].Position
		local separation = (a - b).Magnitude
		check(separation > 60, `team spawns are far apart ({math.floor(separation)} studs)`)
	end

	-- Everything must be anchored: one unanchored part falls through the map.
	local unanchored = 0
	local function checkAnchored(node)
		for _, child in node:GetChildren() do
			if child:IsA("BasePart") and not child.Anchored then
				unanchored += 1
			end
			checkAnchored(child)
		end
	end
	checkAnchored(built.model)
	check(unanchored == 0, `every part is anchored ({unanchored} unanchored)`)
end

--------------------------------------------------------------------------------
-- Cross-map invariants
--------------------------------------------------------------------------------

currentMap = "world"
heading("Cross-map")

local origins = {}
for _, entry in MAPS do
	local def = entry.def
	origins[entry.id] = roblox.Vector3.new(def.origin.x, def.origin.y, def.origin.z)
end

for a, posA in origins do
	for b, posB in origins do
		if a < b then
			local distance = (posA - posB).Magnitude
			check(distance > 1000, `{a} and {b} are far enough apart ({math.floor(distance)} studs)`)
		end
	end
end

-- The same coordinates live in two places: each map definition builds geometry
-- at its own origin, and GameConfig is what the teleport code reads. If those
-- ever drift, players arrive where the map is not.
for mapId, position in origins do
	local declared = GameConfig.MAP_ORIGINS[mapId]
	check(declared ~= nil, `GameConfig declares an origin for {mapId}`)
	if declared then
		local matches = declared.x == position.X and declared.y == position.Y and declared.z == position.Z
		check(
			matches,
			`{mapId} origin agrees with GameConfig `
				.. `(def {position.X},{position.Y},{position.Z} vs config {declared.x},{declared.y},{declared.z})`
		)
	end
end

local grandTotal = 0
for _, result in results do
	grandTotal += result.total
end
print(`  total instances across all maps: {grandTotal}`)
check(grandTotal > 0, "something was built")

-- This is the number every client loads at once while StreamingEnabled is off.
print(`  every client currently loads all {grandTotal} of them on join`)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

local calls = Env.calls()
local callSummary = {}
for name, count in calls do
	table.insert(callSummary, `{name}={count}`)
end
table.sort(callSummary)
if #callSummary > 0 then
	print("  sandbox calls: " .. table.concat(callSummary, "  "))
end

print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} world check(s) failed`, 0)
end

print("  All world checks passed.")
