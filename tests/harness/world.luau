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
local Constants = Env.load("src/shared/Constants")
print("  GameConfig loaded")

-- Taken from Constants rather than written out here: the hub must carry a
-- portal for exactly the maps the rest of the game believes are playable, and
-- a second list would be one more place to forget.
local PLAYABLE_MAPS: { [string]: boolean } = {}
for _, mapId in Constants.MAPS do
	PLAYABLE_MAPS[mapId] = true
end

local MAPS = {
	{ id = "Hub", def = Env.load("src/shared/MapDefs/HubDef"), isHub = true },
	{ id = "Dust", def = Env.load("src/shared/MapDefs/DustDef"), isHub = false },
	{ id = "Mirage", def = Env.load("src/shared/MapDefs/MirageDef"), isHub = false },
	{ id = "Nexus", def = Env.load("src/shared/MapDefs/NexusDef"), isHub = false },
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

--------------------------------------------------------------------------------
-- Geometry probes
--
-- Lune has no physics, so "can a player walk from here to there" cannot be
-- asked of the engine. It can be asked of the boxes: every surface in these
-- maps is an upright box or a box tilted about one axis, so the questions that
-- matter (does this ramp meet the thing it climbs to?) are plain arithmetic on
-- the built parts' CFrames, read back off the instances the way a player's
-- feet would meet them.
--------------------------------------------------------------------------------

local function partsNamed(model: any, names: { [string]: boolean }): { any }
	local found = {}
	for _, node in model:GetDescendants() do
		if node:IsA("BasePart") and names[node.Name] then
			table.insert(found, node)
		end
	end
	return found
end

-- World-space top face of an upright, axis-aligned box: {minX, maxX, minZ, maxZ, y}.
-- Nil for anything tilted, so a ramp can never be mistaken for the surface it serves.
local function uprightTop(part: any)
	local cf = part.CFrame
	if math.abs(cf.UpVector.Y) < 0.999 then
		return nil
	end
	local size = part.Size
	local right, look = cf.RightVector, cf.LookVector
	local halfX = math.abs(right.X) * size.X / 2 + math.abs(look.X) * size.Z / 2
	local halfZ = math.abs(right.Z) * size.X / 2 + math.abs(look.Z) * size.Z / 2
	local centre = cf.Position
	return {
		minX = centre.X - halfX,
		maxX = centre.X + halfX,
		minZ = centre.Z - halfZ,
		maxZ = centre.Z + halfZ,
		y = centre.Y + size.Y / 2,
		bottom = centre.Y - size.Y / 2,
	}
end

local WALKABLE = { Floor = true, Block = true, RoomFloor = true }

--[[
	For each ramp: where the middle of its top edge sits at the low and the high
	end, and the surface a player steps onto from the high end. That surface is
	the highest walkable top whose footprint contains a point one stud further
	up the slope from the edge — one stud past the edge rather than the edge
	itself, because a ramp that stops exactly at a platform's rim is still a
	ramp that reaches it.
]]
local function probeRamps(built: any)
	local probes = {}
	local surfaces = {}
	for _, part in partsNamed(built.model, WALKABLE) do
		local top = uprightTop(part)
		if top then
			table.insert(surfaces, top)
		end
	end

	for _, ramp in partsNamed(built.model, { Ramp = true }) do
		local half = ramp.Size / 2
		local a = ramp.CFrame * roblox.Vector3.new(half.X, half.Y, 0)
		local b = ramp.CFrame * roblox.Vector3.new(-half.X, half.Y, 0)
		local high, low, highSign = a, b, 1
		if b.Y > a.Y then
			high, low, highSign = b, a, -1
		end

		local flat = roblox.Vector3.new(high.X - low.X, 0, high.Z - low.Z).Unit
		local probeX, probeZ = high.X + flat.X, high.Z + flat.Z

		local served = nil
		for _, top in surfaces do
			local inside = probeX >= top.minX and probeX <= top.maxX and probeZ >= top.minZ and probeZ <= top.maxZ
			-- A ramp that ends against a wall's foot is not "serving" the wall,
			-- and the arena floor under it is not a destination either.
			if inside and top.y > built.origin.Y + 1 and (not served or top.y > served.y) then
				served = top
			end
		end

		-- How much of the ramp's width actually meets that surface: a ramp whose
		-- middle lands on a platform but whose sides hang in the air is a trap.
		local covered = 0
		if served then
			for _, across in { -1, -0.5, 0, 0.5, 1 } do
				local edge = ramp.CFrame * roblox.Vector3.new(highSign * half.X, half.Y, across * half.Z)
				local x, z = edge.X + flat.X, edge.Z + flat.Z
				if
					x >= served.minX - 0.01
					and x <= served.maxX + 0.01
					and z >= served.minZ - 0.01
					and z <= served.maxZ + 0.01
				then
					covered += 1
				end
			end
		end

		table.insert(probes, { ramp = ramp, high = high, low = low, served = served, covered = covered / 5 })
	end
	return probes
end

--[[
	Blocks that are mostly inside a wall. Cover that has been placed in a wall
	is invisible, cannot be stood behind, and shows no face to anyone — the
	Nexus catwalk railings were built that way, one stud from the perimeter.
	Returns { part, fraction } for each block with more than half its volume
	buried.
]]
local function buriedBlocks(built: any)
	local walls = {}
	for _, wall in partsNamed(built.model, { Wall = true }) do
		local box = uprightTop(wall)
		if box then
			table.insert(walls, box)
		end
	end

	local buried = {}
	for _, block in partsNamed(built.model, { Block = true }) do
		local box = uprightTop(block)
		if not box then
			continue
		end
		local volume = (box.maxX - box.minX) * (box.maxZ - box.minZ) * (box.y - box.bottom)
		local inside = 0
		for _, wall in walls do
			local dx = math.min(box.maxX, wall.maxX) - math.max(box.minX, wall.minX)
			local dz = math.min(box.maxZ, wall.maxZ) - math.max(box.minZ, wall.minZ)
			local dy = math.min(box.y, wall.y) - math.max(box.bottom, wall.bottom)
			if dx > 0 and dz > 0 and dy > 0 then
				inside += dx * dz * dy
			end
		end
		if inside / volume > 0.5 then
			table.insert(buried, { part = block, fraction = inside / volume })
		end
	end
	return buried
end

--[[
	Wall neon that is not on a wall. A WallNeon bar is a decoration for the wall
	it belongs to, so its centre must lie within a wall's box; one that does not
	is a glowing bar hanging in mid-air. Returns the offending bars.
]]
local function strayWallNeon(built: any)
	local walls = {}
	for _, wall in partsNamed(built.model, { Wall = true }) do
		local box = uprightTop(wall)
		if box then
			table.insert(walls, box)
		end
	end

	local stray = {}
	for _, bar in partsNamed(built.model, { WallNeon = true }) do
		local at = bar.CFrame.Position
		local held = false
		for _, wall in walls do
			if
				at.X >= wall.minX - 0.5
				and at.X <= wall.maxX + 0.5
				and at.Z >= wall.minZ - 0.5
				and at.Z <= wall.maxZ + 0.5
				and at.Y >= wall.bottom - 0.5
				and at.Y <= wall.y + 0.5
			then
				held = true
				break
			end
		end
		if not held then
			table.insert(stray, bar)
		end
	end
	return stray
end

--[[
	Pairs of floor-like tops that occupy the same plane over the same ground.
	The GPU cannot decide which of two coincident faces is in front, so it
	decides per pixel and per frame and the surface shimmers. Only the tops of
	Floor, RoomFloor and Block parts are compared (the things a player stands
	on), and only when they overlap by more than a stud in each direction, so
	blocks that merely touch edge to edge are left alone.
]]
local function coplanarTops(built: any)
	local boxes = {}
	for _, part in partsNamed(built.model, WALKABLE) do
		local box = uprightTop(part)
		if box and part.Transparency < 1 then
			box.part = part
			table.insert(boxes, box)
		end
	end

	local pairsFound = {}
	for i = 1, #boxes do
		for j = i + 1, #boxes do
			local a, b = boxes[i], boxes[j]
			if math.abs(a.y - b.y) < 0.02 then
				local dx = math.min(a.maxX, b.maxX) - math.max(a.minX, b.minX)
				local dz = math.min(a.maxZ, b.maxZ) - math.max(a.minZ, b.minZ)
				if dx > 1 and dz > 1 then
					table.insert(pairsFound, { a = a, b = b })
				end
			end
		end
	end
	return pairsFound
end

--------------------------------------------------------------------------------
-- Sight lines
--
-- There is no renderer here, but "can the eye see that sign" is a segment
-- against boxes, and every part in these maps is one. A part hides what is
-- behind it whether or not it collides or answers raycasts, so unlike a
-- gameplay raycast this counts everything that draws.
--------------------------------------------------------------------------------

-- Standing eye above the HumanoidRootPart height that spawns are placed at.
local EYE_ABOVE_SPAWN = 1.5

local function segmentHitsPart(part: any, from: any, to: any): boolean
	local cf = part.CFrame
	local a = cf:PointToObjectSpace(from)
	local b = cf:PointToObjectSpace(to)
	local half = part.Size / 2
	local tMin, tMax = 0, 1
	for _, axis in { "X", "Y", "Z" } do
		local origin, delta, extent = a[axis], b[axis] - a[axis], half[axis]
		if math.abs(delta) < 1e-9 then
			if math.abs(origin) > extent then
				return false
			end
		else
			local t1, t2 = (-extent - origin) / delta, (extent - origin) / delta
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			tMin, tMax = math.max(tMin, t1), math.min(tMax, t2)
			if tMin > tMax then
				return false
			end
		end
	end
	return true
end

-- Anything that draws and is big enough to matter: studs are decoration on top
-- of blocks (and cylinders, which a box test would over-count).
local function occluders(built: any, ignore: { [any]: boolean }): { any }
	local list = {}
	for _, node in built.model:GetDescendants() do
		if
			node:IsA("BasePart")
			and node.Transparency < 0.5
			and node.Name ~= "Stud"
			and node.Name ~= "CeilingTile"
			and not ignore[node]
		then
			table.insert(list, node)
		end
	end
	return list
end

--[[
	The share of a sign face a viewer at `eye` can see: a 5 x 3 grid of points
	half a stud in front of the face, each tested against everything that draws.
]]
local function visibleShare(eye: any, face: any, blockers: { any }): number
	local half = face.Size / 2
	local seen, total = 0, 0
	for _, u in { -0.9, -0.45, 0, 0.45, 0.9 } do
		for _, v in { -0.8, 0, 0.8 } do
			total += 1
			local point = face.CFrame * roblox.Vector3.new(u * half.X, v * half.Y, -(half.Z + 0.5))
			local hidden = false
			for _, blocker in blockers do
				if segmentHitsPart(blocker, eye, point) then
					hidden = true
					break
				end
			end
			if not hidden then
				seen += 1
			end
		end
	end
	return seen / total
end

--[[
	How far two upright boxes sink into each other, in studs, by the separating
	axis test on their footprints (they may be yawed, as portals are) and an
	interval test on height. 0 when they only touch or miss.
]]
local function penetration(a: any, b: any): number
	local function corners(part: any)
		local cf, size = part.CFrame, part.Size
		local centre = cf.Position
		local right = roblox.Vector3.new(cf.RightVector.X, 0, cf.RightVector.Z)
		local look = roblox.Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
		return centre, right * (size.X / 2), look * (size.Z / 2)
	end

	local aCentre, aRight, aLook = corners(a)
	local bCentre, bRight, bLook = corners(b)

	local depth = math.huge
	for _, axis in { aRight.Unit, aLook.Unit, bRight.Unit, bLook.Unit } do
		local function radius(right: any, look: any)
			return math.abs(right:Dot(axis)) + math.abs(look:Dot(axis))
		end
		local reach = radius(aRight, aLook) + radius(bRight, bLook)
		local gap = math.abs((bCentre - aCentre):Dot(axis))
		depth = math.min(depth, reach - gap)
		if depth <= 0 then
			return 0
		end
	end

	local aY, bY = a.CFrame.Position.Y, b.CFrame.Position.Y
	local height = math.min(aY + a.Size.Y / 2, bY + b.Size.Y / 2) - math.max(aY - a.Size.Y / 2, bY - b.Size.Y / 2)
	if height <= 0 then
		return 0
	end
	return math.min(depth, height)
end

--[[
	How a character moves, from the same constants the server sets on it, so the
	numbers here cannot drift from the game. Gravity is Roblox's default; nothing
	in this project changes it.
]]
local GRAVITY = 196.2
local JUMP_SPEED = Constants.JUMP_POWER
local WALK_SPEED = Constants.WALK_SPEED
local JUMP_APEX = JUMP_SPEED * JUMP_SPEED / (2 * GRAVITY)
-- Feet clear an edge only with a little to spare; without it a "reachable" top
-- would be one a player can reach only by touching it at the very peak.
local JUMP_MARGIN = 0.3

-- How far along the ground a running jump carries a character that ends up
-- `rise` studs above where it left (on the way down, so the longest carry), or
-- nil when that rise cannot be jumped at all.
local function jumpReach(rise: number): number?
	local discriminant = JUMP_SPEED * JUMP_SPEED - 2 * GRAVITY * (rise + JUMP_MARGIN)
	if discriminant < 0 then
		return nil
	end
	return WALK_SPEED * (JUMP_SPEED + math.sqrt(discriminant)) / GRAVITY
end

--[[
	Tall walls that a step lets a player climb. Any wall taller than a jump is
	drawn as hard cover ("too tall to jump"), and it only stays that way if
	nothing a player can jump onto stands close enough to jump from onto the
	wall. Returns { wall, step, gap } for each wall/step pair that breaks it.
]]
local function climbableWalls(built: any)
	local floorY = built.origin.Y
	local found = {}
	local steps = {}
	for _, part in partsNamed(built.model, { Block = true, Wall = true, Ramp = true }) do
		local box = uprightTop(part)
		if box and box.y - floorY <= JUMP_APEX - JUMP_MARGIN and box.y - floorY > 0.5 then
			box.part = part
			table.insert(steps, box)
		end
	end

	for _, wall in partsNamed(built.model, { Wall = true }) do
		local box = uprightTop(wall)
		local height = if box then box.y - floorY else 0
		-- Only walls that are drawn as cover a player might try to climb: above
		-- one jump, and not so tall that two stacked jumps still fall short.
		if not box or height <= JUMP_APEX or height >= 2 * JUMP_APEX - 1 then
			continue
		end
		for _, step in steps do
			if step.part ~= wall then
				local reach = jumpReach(box.y - step.y)
				if reach then
					local gapX = math.max(step.minX - box.maxX, box.minX - step.maxX, 0)
					local gapZ = math.max(step.minZ - box.maxZ, box.minZ - step.maxZ, 0)
					local gap = math.sqrt(gapX * gapX + gapZ * gapZ)
					if gap < reach then
						table.insert(found, { wall = wall, step = step, gap = gap, reach = reach })
					end
				end
			end
		end
	end
	return found
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
		check(
			#built.portals == #Constants.MAPS,
			`hub has a portal per playable map (got {#built.portals}, want {#Constants.MAPS})`
		)
		check(built.boards ~= nil and built.boards.TopKills ~= nil, "hub has the TopKills board")

		----------------------------------------------------------------------
		-- The name on the gateway sign
		--
		-- MapDefs.spec asserts the def carries the right words. That says
		-- nothing about whether they reach a screen: the sign is the first
		-- element kind in this game that draws a SurfaceGui on two faces, and
		-- a Face enum set wrong, a label parented outside the layout, or a
		-- board built with no GUI at all all leave the def perfectly correct
		-- and the arena unbranded. So the text is read back off the built
		-- instances, per face, exactly as a player reads it.
		----------------------------------------------------------------------
		local signBoards = {}
		for _, node in built.model:GetDescendants() do
			if node:IsA("BasePart") and node.Name == "SignBoard" then
				table.insert(signBoards, node)
			end
		end
		check(#signBoards == 1, `hub has one name sign board (got {#signBoards})`)

		local facesShowingTheName = 0
		for _, board in signBoards do
			for _, gui in board:GetChildren() do
				if not gui:IsA("SurfaceGui") then
					continue
				end
				local lines = {}
				for _, node in gui:GetDescendants() do
					if node:IsA("TextLabel") then
						table.insert(lines, { order = node.LayoutOrder, text = node.Text })
					end
				end
				table.sort(lines, function(a, b)
					return a.order < b.order
				end)

				local words = {}
				for _, line in lines do
					table.insert(words, line.text)
				end
				if table.concat(words, " ") == Constants.GAME_NAME then
					facesShowingTheName += 1
				end
			end
		end
		-- Both faces: the sign is walked under, so half the plaza sees its back.
		check(
			facesShowingTheName == 2,
			`the name reads "{Constants.GAME_NAME}" on both faces of the sign (got {facesShowingTheName})`
		)

		----------------------------------------------------------------------
		-- Which way the lettering faces
		--
		-- A sign is a one-sided object dressed as geometry: the SurfaceGui sits
		-- on NormalId.Front, and Front is the local -Z face, which is exactly
		-- where CFrame.LookVector points. Build it yawed 180 degrees and every
		-- assertion above still passes — the part exists, is anchored, is in
		-- the right place, carries the right words — while players read a blank
		-- slab and the text faces a wall.
		--
		-- This is not hypothetical. Lune's CFrame.lookAt disagrees with
		-- Roblox's for a target along +/-Z and hands back exactly that 180
		-- degree error; tests/harness/env.luau now corrects it. Nothing here
		-- noticed, because nothing here looked at a facing. This does.
		--
		-- Phrased as "points at the people who need to read it" rather than as
		-- a compass direction, so moving the hub around cannot quietly make it
		-- vacuous.
		--
		-- Read through CFrame.Position, not BasePart.Position: Lune does not
		-- derive the latter from the former and raises on it.
		----------------------------------------------------------------------
		local function averagePosition(cframes)
			local sum = roblox.Vector3.new(0, 0, 0)
			for _, cf in cframes do
				sum += cf.Position
			end
			return sum / math.max(1, #cframes)
		end

		local lobbyAt = averagePosition(built.spawns.Lobby)
		local plazaAt = roblox.Vector3.new(built.origin.X, 0, built.origin.Z)

		for _, node in built.model:GetDescendants() do
			if not node:IsA("BasePart") then
				continue
			end

			if node.Name == "SignBoard" then
				local toPlayers = (lobbyAt - node.CFrame.Position).Unit
				check(
					node.CFrame.LookVector:Dot(toPlayers) > 0.5,
					`the gateway sign's lettering faces the lobby spawn `
						.. `(dot {string.format("%.2f", node.CFrame.LookVector:Dot(toPlayers))})`
				)
			elseif node.Name == "PortalSign" then
				local toPlaza = (plazaAt - node.CFrame.Position).Unit
				check(
					node.CFrame.LookVector:Dot(toPlaza) > 0.4,
					`a portal sign faces the plaza rather than the wall behind it `
						.. `(dot {string.format("%.2f", node.CFrame.LookVector:Dot(toPlaza))})`
				)
			end
		end

		----------------------------------------------------------------------
		-- Can a player standing in the lobby read the hub's signs?
		--
		-- The leaderboard and the portals' names are the only things that tell
		-- a new player what to do in this room. Each one used to stand behind
		-- another portal, a planter or the gateway sign: present, correctly
		-- lettered, facing the right way and unreadable. So every sign is
		-- measured from every lobby spawn, and each must be mostly in view from
		-- most of them.
		----------------------------------------------------------------------
		local eyes = {}
		for _, cf in built.spawns.Lobby do
			table.insert(eyes, cf.Position + roblox.Vector3.new(0, EYE_ABOVE_SPAWN, 0))
		end

		local targets = {}
		for _, portal in built.portals do
			table.insert(targets, { label = `the {portal.mapId} portal sign`, face = portal.gui.Parent })
		end
		if built.boards.TopKills then
			table.insert(targets, { label = "the Top Kills board", face = built.boards.TopKills.Parent })
		end

		for _, target in targets do
			local ignore = { [target.face] = true }
			-- A board is a screen plus its own frame and glow; those are the
			-- sign, not something in front of it.
			if target.face.Name == "BoardScreen" then
				for _, sibling in target.face.Parent:GetChildren() do
					if sibling.Name == "BoardFrame" or sibling.Name == "BoardGlow" then
						ignore[sibling] = true
					end
				end
			end
			local blockers = occluders(built, ignore)

			local wellSeen, sum = 0, 0
			for _, eye in eyes do
				local share = visibleShare(eye, target.face, blockers)
				sum += share
				if share >= 0.6 then
					wellSeen += 1
				end
			end
			print(
				`  {target.label}: {string.format("%.0f", sum / #eyes * 100)}% visible on average, `
					.. `readable from {wellSeen}/{#eyes} spawns`
			)
			check(
				wellSeen >= math.ceil(#eyes * 0.75),
				`{target.label} is mostly in view from the lobby (readable from {wellSeen} of {#eyes} spawns)`
			)
		end

		----------------------------------------------------------------------
		-- Portals that stand in the open
		--
		-- A portal is a pad, a frame and a sign. Set down where a planter or a
		-- wall already is, the pad sinks into the hedge and the frame is half
		-- buried: the Dust and Nexus portals were placed that way, over the
		-- planters. Nothing solid may overlap any part of a portal by more than
		-- the half stud two touching faces are allowed.
		----------------------------------------------------------------------
		local portalParts = partsNamed(
			built.model,
			{ PortalRim = true, PortalPad = true, PortalPost = true, PortalArch = true, PortalSign = true }
		)
		local scenery = partsNamed(built.model, { Block = true, Wall = true })
		local clashes = 0
		for _, portalPart in portalParts do
			for _, other in scenery do
				local depth = penetration(portalPart, other)
				if depth > 0.5 then
					clashes += 1
					local at = portalPart.CFrame.Position
					check(
						false,
						`{portalPart.Name} at ({math.floor(at.X)}, {math.floor(at.Z)}) sinks {string.format(
							"%.1f",
							depth
						)} studs `
							.. `into a {other.Name} at ({math.floor(other.CFrame.Position.X)}, {math.floor(
								other.CFrame.Position.Z
							)})`
					)
				end
			end
		end
		check(clashes == 0, "no portal part is buried in scenery")

		for _, portal in built.portals do
			check(portal.padPart ~= nil, `portal {portal.mapId} has a pad part`)
			check(PLAYABLE_MAPS[portal.mapId] == true, `portal targets a real map ({portal.mapId})`)
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

		----------------------------------------------------------------------
		-- Ramps that actually reach something
		--
		-- A ramp is only a ramp if a player can walk from the floor onto it and
		-- from it onto the surface it climbs to. Nexus shipped with six that did
		-- neither: low ends floating three studs up, high ends stopping two studs
		-- short of a platform they were meant to serve, and a comment claiming
		-- the opposite. Nothing checked, because every part was anchored, in
		-- bounds and correctly coloured. Humanoids step up ~2 studs and cross
		-- gaps of about half a stud, so half a stud is the tolerance here.
		----------------------------------------------------------------------
		for _, hidden in buriedBlocks(built) do
			local at = hidden.part.CFrame.Position
			check(
				false,
				`block at ({math.floor(at.X - built.origin.X)}, {math.floor(at.Y - built.origin.Y)}, `
					.. `{math.floor(at.Z - built.origin.Z)}) is {math.floor(hidden.fraction * 100)}% inside a wall`
			)
		end
		check(true, "no cover block is buried in a wall")

		local stray = strayWallNeon(built)
		for _, bar in stray do
			local at = bar.CFrame.Position
			check(
				false,
				`a wall neon bar floats at ({math.floor(at.X - built.origin.X)}, {math.floor(at.Y - built.origin.Y)}, `
					.. `{math.floor(at.Z - built.origin.Z)}) with no wall around it`
			)
		end
		check(true, "every wall neon bar sits on a wall")

		local probes = probeRamps(built)
		check(#probes > 0, "the map has ramps for the check below to measure")
		for _, probe in probes do
			local at = probe.ramp.CFrame.Position
			local label = `ramp at ({math.floor(at.X - built.origin.X)}, {math.floor(at.Z - built.origin.Z)})`
			check(
				math.abs(probe.low.Y - built.origin.Y) <= 0.5,
				`{label} meets the floor at its low end (top edge {string.format("%.2f", probe.low.Y - built.origin.Y)} up)`
			)
			check(probe.served ~= nil, `{label} ends on a surface a player can step onto`)
			if probe.served then
				check(probe.covered >= 0.8, `{label} meets its surface across its whole width ({probe.covered * 100}%)`)
				check(
					math.abs(probe.high.Y - probe.served.y) <= 0.5,
					`{label} lands level with what it climbs to `
						.. `(top edge {string.format("%.2f", probe.high.Y - built.origin.Y)}, surface {string.format(
							"%.2f",
							probe.served.y - built.origin.Y
						)})`
				)
			end
		end
	end

	-- Floor inlays are paint: thin, non-colliding blocks laid on the arena floor.
	-- One that spills over a room colours the room's floor with the arena's.
	local roomFloors = partsNamed(built.model, { RoomFloor = true })
	local paintedRooms = 0
	for _, inlay in partsNamed(built.model, { Block = true }) do
		if inlay.Size.Y <= 0.5 and not inlay.CanCollide then
			local box = uprightTop(inlay)
			for _, floor in roomFloors do
				local room = uprightTop(floor)
				if box and room then
					local dx = math.min(box.maxX, room.maxX) - math.max(box.minX, room.minX)
					local dz = math.min(box.maxZ, room.maxZ) - math.max(box.minZ, room.minZ)
					if dx > 0.5 and dz > 0.5 then
						paintedRooms += 1
						check(
							false,
							`a floor inlay at ({math.floor(inlay.CFrame.Position.X - built.origin.X)}, `
								.. `{math.floor(inlay.CFrame.Position.Z - built.origin.Z)}) spills {string.format(
									"%.1f",
									dx
								)} x `
								.. `{string.format("%.1f", dz)} studs into a room's floor`
						)
					end
				end
			end
		end
	end
	check(paintedRooms == 0, "no floor inlay reaches into a room")

	for _, climb in climbableWalls(built) do
		local at, stepAt = climb.wall.CFrame.Position, climb.step.part.CFrame.Position
		check(
			false,
			`the {math.floor(climb.wall.Size.Y)}-stud wall at ({math.floor(at.X - built.origin.X)}, `
				.. `{math.floor(at.Z - built.origin.Z)}) can be jumped onto from the {climb.step.part.Name} at `
				.. `({math.floor(stepAt.X - built.origin.X)}, {math.floor(stepAt.Z - built.origin.Z)}), `
				.. `{string.format("%.1f", climb.gap)} studs away (a jump carries {string.format("%.1f", climb.reach)})`
		)
	end
	check(true, "no wall taller than a jump can be climbed from a step")

	for _, clash in coplanarTops(built) do
		check(
			false,
			`{clash.a.part.Name} and {clash.b.part.Name} share a top face at height `
				.. `{string.format("%.2f", clash.a.y - built.origin.Y)} `
				.. `(x {math.floor(clash.a.minX - built.origin.X)}..{math.floor(clash.a.maxX - built.origin.X)} vs `
				.. `{math.floor(clash.b.minX - built.origin.X)}..{math.floor(clash.b.maxX - built.origin.X)}) and will z-fight`
		)
	end
	check(true, "no two floor tops share a plane")

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

-- Every client loads all of this on join: the three worlds coexist in one place
-- and streaming is off. That is a deliberate choice and this number is why it
-- holds — it is an order of magnitude under what a phone struggles with, and
-- streaming would buy nothing while adding parts appearing late around a
-- player who has already been shot at. The guard is here so that if the maps
-- ever grow into territory where the trade changes, this fails rather than the
-- framerate quietly sagging on someone's phone.
print(`  every client loads all {grandTotal} of them on join (streaming is off by choice)`)
check(grandTotal < 8000, `the whole world stays inside a mobile budget (got {grandTotal})`)

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

-- Spawned work runs on its own thread now, so a thread that dies takes its
-- timer or its poll with it and says nothing. This is where it says something.
check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

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
