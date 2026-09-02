--!nonstrict
--[[
	MapBuilder.luau
	Turns a pure MapDef data table (src/shared/MapDefs) into real geometry.

	Every element position in a def is relative to `def.origin`; this module adds
	the origin exactly once, here, so the defs stay readable and testable off
	Roblox. Each map becomes one Model inside workspace.World.

	Part budget: the defs are written to stay well under the ~1500 parts a mobile
	GPU can carry per map (references/sharp-edges.md SE-7), and the studs and
	ceiling-tile helpers below clamp their own part counts so a careless def
	cannot blow the budget on decoration alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Constants = require(Shared.Constants)
local SpawnDoors = require(script.Parent.SpawnDoors)

local MapBuilder = {}

local WORLD_FOLDER_NAME = "World"

local TRIM_HEIGHT = 1.0
local NEON_STRIP_HEIGHT = 1.6
local TILE_THICKNESS = 0.8
local TILE_GAP = 2.4
local DOOR_HEIGHT = 14
local DOOR_PANEL_THICKNESS = 0.8

-- HumanoidRootPart sits roughly 3 studs above the floor; the extra half stud
-- stops a spawning character from clipping into the pad it lands on.
local SPAWN_HEIGHT = 3.5

local STUD_SPACING = 10
local STUD_DIAMETER = 5
local STUD_HEIGHT = 1.2
local MAX_STUDS_PER_AXIS = 6
local MAX_CEILING_TILES = 120

local SIDE_ORDER = { "+x", "-x", "+z", "-z" }
local SIDE_NORMALS = {
	["+x"] = { x = 1, z = 0 },
	["-x"] = { x = -1, z = 0 },
	["+z"] = { x = 0, z = 1 },
	["-z"] = { x = 0, z = -1 },
}

local MATERIALS = {
	SmoothPlastic = Enum.Material.SmoothPlastic,
	Plastic = Enum.Material.Plastic,
	Neon = Enum.Material.Neon,
	Metal = Enum.Material.Metal,
	DiamondPlate = Enum.Material.DiamondPlate,
	Concrete = Enum.Material.Concrete,
	Sand = Enum.Material.Sand,
	Slate = Enum.Material.Slate,
	Glass = Enum.Material.Glass,
	Marble = Enum.Material.Marble,
	Wood = Enum.Material.WoodPlanks,
	Grass = Enum.Material.Grass,
}

local FALLBACK_COLOR = Color3.fromRGB(190, 190, 198)

-- Geometry helpers --------------------------------------------------------

local function worldVec(ctx, x: number, y: number, z: number): Vector3
	return Vector3.new(ctx.origin.X + x, ctx.origin.Y + y, ctx.origin.Z + z)
end

local function resolveColor(ctx, key: string?): Color3
	local rgb = key and ctx.def.palette[key]
	if not rgb then
		return FALLBACK_COLOR
	end
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local function resolveMaterial(name: string?): EnumItem?
	if name == nil then
		return nil
	end
	local material = MATERIALS[name]
	if not material then
		warn(`[MapBuilder] unknown material "{name}"; falling back to SmoothPlastic`)
	end
	return material
end

local function makePart(ctx, props): BasePart
	local part = Instance.new("Part")
	part.Name = props.name or "Block"
	part.Anchored = true
	part.CanCollide = props.canCollide ~= false
	part.CanQuery = true
	part.CanTouch = props.canTouch == true
	part.CastShadow = props.castShadow ~= false
	part.Material = props.material or Enum.Material.SmoothPlastic
	part.Color = props.color or FALLBACK_COLOR
	part.Transparency = props.transparency or 0
	part.Reflectance = props.reflectance or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if props.shape then
		part.Shape = props.shape
	end
	part.Size = props.size
	part.CFrame = props.cframe
	part.Parent = ctx.model
	ctx.count += 1
	return part
end

--[[
	Lego studs on the top face of a box. Count is clamped per axis so a large
	hero block adds at most MAX_STUDS_PER_AXIS^2 parts.
]]
local function addStuds(ctx, pos, size: Vector3, colorKey: string?)
	local nx = math.clamp(math.floor(size.X / STUD_SPACING), 1, MAX_STUDS_PER_AXIS)
	local nz = math.clamp(math.floor(size.Z / STUD_SPACING), 1, MAX_STUDS_PER_AXIS)
	local stepX, stepZ = size.X / nx, size.Z / nz
	local topY = pos.y + size.Y * 0.5 + STUD_HEIGHT * 0.5
	local color = resolveColor(ctx, colorKey)

	for ix = 1, nx do
		for iz = 1, nz do
			local x = pos.x + (ix - (nx + 1) * 0.5) * stepX
			local z = pos.z + (iz - (nz + 1) * 0.5) * stepZ
			makePart(ctx, {
				name = "Stud",
				-- A cylinder Part's axis runs along local X, so it is stood up.
				size = Vector3.new(STUD_HEIGHT, STUD_DIAMETER, STUD_DIAMETER),
				cframe = CFrame.new(worldVec(ctx, x, topY, z)) * CFrame.Angles(0, 0, math.rad(90)),
				color = color,
				shape = Enum.PartType.Cylinder,
				canCollide = false,
				castShadow = false,
			})
		end
	end
end

--[[
	A wall segment between two XZ points, optionally capped with white trim and
	lit with a neon strip. `spec` fields: fromX/fromZ/toX/toZ, height, thickness,
	color, baseY, trim, trimColor, neonStripY, neonColor, material.
]]
local function emitWall(ctx, spec)
	local dx, dz = spec.toX - spec.fromX, spec.toZ - spec.fromZ
	local length = math.sqrt(dx * dx + dz * dz)
	if length < 0.05 then
		return
	end

	local baseY = spec.baseY or 0
	local height = spec.height or 20
	local thickness = spec.thickness or 4
	local yaw = math.atan2(dx, dz)
	local midX, midZ = (spec.fromX + spec.toX) * 0.5, (spec.fromZ + spec.toZ) * 0.5
	local rotation = CFrame.Angles(0, yaw, 0)

	makePart(ctx, {
		name = "Wall",
		size = Vector3.new(thickness, height, length),
		cframe = CFrame.new(worldVec(ctx, midX, baseY + height * 0.5, midZ)) * rotation,
		color = resolveColor(ctx, spec.color),
		material = resolveMaterial(spec.material),
	})

	if spec.trim then
		makePart(ctx, {
			name = "WallTrim",
			size = Vector3.new(thickness + 1.2, TRIM_HEIGHT, length + 1.2),
			cframe = CFrame.new(worldVec(ctx, midX, baseY + height + TRIM_HEIGHT * 0.5, midZ)) * rotation,
			color = resolveColor(ctx, spec.trimColor or "Trim"),
		})
	end

	if spec.neonStripY then
		makePart(ctx, {
			name = "WallNeon",
			-- Slightly proud of the wall on both faces so the strip reads from
			-- either side without z-fighting.
			size = Vector3.new(thickness + 0.6, NEON_STRIP_HEIGHT, math.max(length - 3, 1)),
			cframe = CFrame.new(worldVec(ctx, midX, baseY + spec.neonStripY, midZ)) * rotation,
			color = resolveColor(ctx, spec.neonColor or "Neon"),
			material = Enum.Material.Neon,
			canCollide = false,
			castShadow = false,
		})
	end
end

local function sideGeometry(center, size, side)
	local normal = SIDE_NORMALS[side] or SIDE_NORMALS["+x"]
	local acrossX = normal.x ~= 0
	return {
		normal = normal,
		cx = center.x + normal.x * size.x * 0.5,
		cz = center.z + normal.z * size.z * 0.5,
		alongX = acrossX and 0 or 1,
		alongZ = acrossX and 1 or 0,
		length = acrossX and size.z or size.x,
	}
end

--[[
	Glowing doorframe: two neon posts plus a lintel bar around a gap of
	`2 * halfWidth` centred on the side.
]]
local function emitDoorFrame(ctx, spec, geom, halfWidth: number, baseY: number, doorHeight: number)
	local yaw = math.atan2(geom.alongX, geom.alongZ)
	local rotation = CFrame.Angles(0, yaw, 0)
	local thickness = (spec.thickness or 4) + 0.8
	local color = resolveColor(ctx, spec.neonColor or "Neon")

	for _, sign in { -1, 1 } do
		makePart(ctx, {
			name = "DoorFramePost",
			size = Vector3.new(thickness, doorHeight, 1.8),
			cframe = CFrame.new(
				worldVec(
					ctx,
					geom.cx + geom.alongX * sign * halfWidth,
					baseY + doorHeight * 0.5,
					geom.cz + geom.alongZ * sign * halfWidth
				)
			) * rotation,
			color = color,
			material = Enum.Material.Neon,
			canCollide = false,
			castShadow = false,
		})
	end

	makePart(ctx, {
		name = "DoorFrameBar",
		size = Vector3.new(thickness, 1.8, halfWidth * 2),
		cframe = CFrame.new(worldVec(ctx, geom.cx, baseY + doorHeight + 0.9, geom.cz)) * rotation,
		color = color,
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
	})
end

--[[
	One side of a room. `spec` carries center/size/height/thickness/color/baseY/
	trim/neonStripY plus a `doors` map of side -> door width. Returns the door
	CFrame and panel size when this side has a doorway.
]]
local function buildSide(ctx, spec, side: string): (CFrame?, Vector3?)
	local geom = sideGeometry(spec.center, spec.size, side)
	local half = geom.length * 0.5
	local baseY = spec.baseY or 0
	local height = spec.size.y
	local doorWidth = spec.doors and spec.doors[side]

	local function point(t: number)
		return geom.cx + geom.alongX * t, geom.cz + geom.alongZ * t
	end

	local common = {
		height = height,
		thickness = spec.thickness,
		color = spec.color,
		baseY = baseY,
		neonStripY = spec.neonStripY,
		neonColor = spec.neonColor,
		material = spec.material,
	}

	local function segment(fromT: number, toT: number, overrides)
		local wall = table.clone(common)
		wall.fromX, wall.fromZ = point(fromT)
		wall.toX, wall.toZ = point(toT)
		for key, value in overrides or {} do
			wall[key] = value
		end
		emitWall(ctx, wall)
	end

	local doorCFrame, doorSpan
	if doorWidth then
		-- Clamped so a doorway wider than its wall, or one in a very short wall,
		-- still leaves a jamb on each side instead of inverting the segments.
		local doorHeight = math.max(math.min(DOOR_HEIGHT, height - 3), 4)
		local halfWidth = math.max(math.min(doorWidth, geom.length - 8), 4) * 0.5
		segment(-half, -halfWidth)
		segment(halfWidth, half)
		segment(-halfWidth, halfWidth, { baseY = baseY + doorHeight, height = height - doorHeight, neonStripY = nil })
		emitDoorFrame(ctx, spec, geom, halfWidth, baseY, doorHeight)

		local doorPos = worldVec(ctx, geom.cx, baseY + doorHeight * 0.5, geom.cz)
		local outward = Vector3.new(geom.normal.x, 0, geom.normal.z)
		doorCFrame = CFrame.lookAt(doorPos, doorPos + outward)
		doorSpan = Vector3.new(halfWidth * 2, doorHeight, DOOR_PANEL_THICKNESS)
	else
		segment(-half, half)
	end

	if spec.trim then
		local fromX, fromZ = point(-half)
		local toX, toZ = point(half)
		local yaw = math.atan2(toX - fromX, toZ - fromZ)
		makePart(ctx, {
			name = "WallTrim",
			size = Vector3.new((spec.thickness or 4) + 1.2, TRIM_HEIGHT, geom.length + 1.2),
			cframe = CFrame.new(worldVec(ctx, geom.cx, baseY + height + TRIM_HEIGHT * 0.5, geom.cz))
				* CFrame.Angles(0, yaw, 0),
			color = resolveColor(ctx, spec.trimColor or "Trim"),
		})
	end

	return doorCFrame, doorSpan
end

local function lookAtCentre(ctx, position: Vector3): CFrame
	local target = Vector3.new(ctx.origin.X, position.Y, ctx.origin.Z)
	if (target - position).Magnitude < 1 then
		return CFrame.new(position)
	end
	return CFrame.lookAt(position, target)
end

--[[
	A grid of spawn CFrames inside a footprint, every one facing the map centre.
]]
local function spawnGrid(
	ctx,
	centerX: number,
	centerZ: number,
	sizeX: number,
	sizeZ: number,
	baseY: number,
	count: number
)
	local list = {}
	count = math.max(1, math.floor(count))
	local cols = math.ceil(math.sqrt(count))
	local rows = math.ceil(count / cols)
	local stepX = math.max(sizeX - 12, 6) / cols
	local stepZ = math.max(sizeZ - 12, 6) / rows

	local index = 0
	for row = 1, rows do
		for col = 1, cols do
			index += 1
			if index > count then
				break
			end
			local x = centerX + (col - (cols + 1) * 0.5) * stepX
			local z = centerZ + (row - (rows + 1) * 0.5) * stepZ
			table.insert(list, lookAtCentre(ctx, worldVec(ctx, x, baseY + SPAWN_HEIGHT, z)))
		end
	end

	return list
end

local function newGui(className: string, parent: Instance, props): Instance
	local instance = Instance.new(className)
	for key, value in props do
		instance[key] = value
	end
	instance.Parent = parent
	return instance
end

-- Element builders --------------------------------------------------------

local Builders = {}

local function emitBox(ctx, element, name: string, defaultMaterial: EnumItem?)
	local size = Vector3.new(element.size.x, element.size.y, element.size.z)
	local rotation = CFrame.identity
	if type(element.rotation) == "number" then
		rotation = CFrame.Angles(0, math.rad(element.rotation), 0)
	elseif type(element.rotation) == "table" then
		rotation = CFrame.Angles(
			math.rad(element.rotation.x or 0),
			math.rad(element.rotation.y or 0),
			math.rad(element.rotation.z or 0)
		)
	end

	local part = makePart(ctx, {
		name = name,
		size = size,
		cframe = CFrame.new(worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)) * rotation,
		color = resolveColor(ctx, element.color),
		material = resolveMaterial(element.material) or defaultMaterial,
		canCollide = element.canCollide ~= false,
		transparency = element.transparency,
	})

	if element.studs then
		addStuds(ctx, element.pos, size, element.studColor or element.color)
	end

	return part
end

function Builders.floor(ctx, element)
	emitBox(ctx, element, "Floor")
end

function Builders.block(ctx, element)
	emitBox(ctx, element, "Block")
end

function Builders.ramp(ctx, element)
	emitBox(ctx, element, "Ramp")
end

function Builders.neonStrip(ctx, element)
	makePart(ctx, {
		name = "NeonStrip",
		size = Vector3.new(element.size.x, element.size.y, element.size.z),
		cframe = CFrame.new(worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)),
		color = resolveColor(ctx, element.color),
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
	})
end

function Builders.wall(ctx, element)
	emitWall(ctx, {
		fromX = element.from.x,
		fromZ = element.from.z,
		toX = element.to.x,
		toZ = element.to.z,
		height = element.height,
		thickness = element.thickness,
		color = element.color,
		baseY = element.baseY,
		trim = element.trim,
		trimColor = element.trimColor,
		neonStripY = element.neonStripY,
		neonColor = element.neonColor,
		material = element.material,
	})
end

function Builders.tiledCeiling(ctx, element)
	local sizeX, sizeZ = element.size.x, element.size.z
	local thickness = element.height or 2

	makePart(ctx, {
		name = "CeilingSlab",
		size = Vector3.new(sizeX, thickness, sizeZ),
		cframe = CFrame.new(worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)),
		color = resolveColor(ctx, element.gapColor or element.color),
	})

	local tile = math.max(element.tile or 20, 6)
	local nx = math.max(1, math.floor(sizeX / tile))
	local nz = math.max(1, math.floor(sizeZ / tile))
	if nx * nz > MAX_CEILING_TILES then
		local scale = math.sqrt((nx * nz) / MAX_CEILING_TILES)
		nx = math.max(1, math.floor(nx / scale))
		nz = math.max(1, math.floor(nz / scale))
	end

	local cellX, cellZ = sizeX / nx, sizeZ / nz
	local tileY = element.pos.y - thickness * 0.5 - TILE_THICKNESS * 0.5
	local color = resolveColor(ctx, element.color)

	for ix = 1, nx do
		for iz = 1, nz do
			makePart(ctx, {
				name = "CeilingTile",
				size = Vector3.new(cellX - TILE_GAP, TILE_THICKNESS, cellZ - TILE_GAP),
				cframe = CFrame.new(
					worldVec(
						ctx,
						element.pos.x + (ix - (nx + 1) * 0.5) * cellX,
						tileY,
						element.pos.z + (iz - (nz + 1) * 0.5) * cellZ
					)
				),
				color = color,
				canCollide = false,
				castShadow = false,
			})
		end
	end
end

local function roomShell(ctx, element, doors)
	local baseY = element.baseY or 0
	local spec = {
		center = element.center,
		size = element.size,
		thickness = element.thickness or 5,
		color = element.color,
		baseY = baseY,
		trim = element.trim ~= false,
		trimColor = element.trimColor,
		neonStripY = element.neonStripY,
		neonColor = element.neonColor,
		material = element.material,
		doors = doors,
	}

	if element.floor ~= false then
		makePart(ctx, {
			name = "RoomFloor",
			size = Vector3.new(element.size.x, 2, element.size.z),
			cframe = CFrame.new(worldVec(ctx, element.center.x, baseY - 1, element.center.z)),
			color = resolveColor(ctx, element.floorColor or element.color),
		})
	end

	local doorFrames = {}
	for _, side in SIDE_ORDER do
		local cframe, size = buildSide(ctx, spec, side)
		if cframe then
			doorFrames[side] = { cframe = cframe, size = size }
		end
	end

	if element.ceiling ~= false then
		makePart(ctx, {
			name = "RoomCeiling",
			size = Vector3.new(element.size.x + 2, 2, element.size.z + 2),
			cframe = CFrame.new(worldVec(ctx, element.center.x, baseY + element.size.y + 1, element.center.z)),
			color = resolveColor(ctx, element.ceilingColor or element.color),
		})
	end

	return doorFrames
end

function Builders.room(ctx, element)
	local doors = {}
	for _, doorway in element.doorways or {} do
		doors[doorway.side] = doorway.width or 12
	end
	roomShell(ctx, element, doors)
end

function Builders.spawnRoom(ctx, element)
	local baseY = element.baseY or 0
	local teamId = element.team
	local doors = { [element.doorSide] = element.doorWidth or 16 }
	local doorFrames = roomShell(ctx, element, doors)

	local team = Constants.TEAMS[teamId] or Constants.TEAMS.LOBBY
	local teamColor = Color3.fromRGB(team.color.r, team.color.g, team.color.b)

	-- Team-coloured glow pad so a player knows instantly whose room this is.
	makePart(ctx, {
		name = "SpawnPad",
		size = Vector3.new(element.size.x - 8, 0.5, element.size.z - 8),
		cframe = CFrame.new(worldVec(ctx, element.center.x, baseY + 0.25, element.center.z)),
		color = teamColor,
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
		transparency = 0.35,
	})

	local door = doorFrames[element.doorSide]
	if door then
		local panel = SpawnDoors.makeDoor(teamId, door.cframe, door.size)
		panel.Parent = ctx.model
		ctx.count += 1
	end

	local spawns = spawnGrid(
		ctx,
		element.center.x,
		element.center.z,
		element.size.x,
		element.size.z,
		baseY,
		element.spawnCount or 6
	)
	local bucket = ctx.spawns[teamId]
	if bucket then
		for _, cframe in spawns do
			table.insert(bucket, cframe)
		end
	end
end

function Builders.lobbySpawn(ctx, element)
	local sizeX = element.size and element.size.x or 48
	local sizeZ = element.size and element.size.z or 32

	makePart(ctx, {
		name = "LobbyPad",
		size = Vector3.new(sizeX + 8, 0.5, sizeZ + 8),
		cframe = CFrame.new(worldVec(ctx, element.pos.x, element.pos.y + 0.25, element.pos.z)),
		color = resolveColor(ctx, element.color or "Neon"),
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
		transparency = 0.5,
	})

	for _, cframe in spawnGrid(ctx, element.pos.x, element.pos.z, sizeX, sizeZ, element.pos.y, element.count or 8) do
		table.insert(ctx.spawns.Lobby, cframe)
	end
end

function Builders.portal(ctx, element)
	local padSize = element.padSize or { x = 16, y = 1.2, z = 16 }
	local paletteKey = ctx.def.palette["Portal" .. tostring(element.mapId)] and ("Portal" .. tostring(element.mapId))
		or "Neon"
	local color = resolveColor(ctx, paletteKey)

	local padPos = worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)
	local base = lookAtCentre(ctx, padPos)
	local backZ = padSize.z * 0.5 + 2

	makePart(ctx, {
		name = "PortalRim",
		size = Vector3.new(padSize.x + 5, 0.8, padSize.z + 5),
		cframe = base * CFrame.new(0, 0.4, 0),
		color = resolveColor(ctx, "Trim"),
	})

	local pad = makePart(ctx, {
		name = "PortalPad",
		size = Vector3.new(padSize.x, padSize.y, padSize.z),
		cframe = base * CFrame.new(0, 0.8 + padSize.y * 0.5, 0),
		color = color,
		material = Enum.Material.Neon,
		canTouch = true,
		castShadow = false,
		transparency = 0.15,
	})
	pad:SetAttribute("MapId", element.mapId)

	for _, side in { -1, 1 } do
		makePart(ctx, {
			name = "PortalPost",
			size = Vector3.new(3, 24, 3),
			cframe = base * CFrame.new(side * (padSize.x * 0.5 + 2.5), 12, backZ),
			color = resolveColor(ctx, "Trim"),
		})
	end

	makePart(ctx, {
		name = "PortalArch",
		size = Vector3.new(padSize.x + 9, 3, 3),
		cframe = base * CFrame.new(0, 25.5, backZ),
		color = color,
		material = Enum.Material.Neon,
		castShadow = false,
	})

	local signPart = makePart(ctx, {
		name = "PortalSign",
		size = Vector3.new(padSize.x + 3, 10, 0.8),
		cframe = base * CFrame.new(0, 16, backZ - 1.6),
		color = resolveColor(ctx, "Board"),
	})

	local surface = newGui("SurfaceGui", signPart, {
		Name = "PortalGui",
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 36,
		LightInfluence = 0,
		MaxDistance = 400,
	})
	local root = newGui("Frame", surface, {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(14, 16, 24),
		BackgroundTransparency = 0.1,
		BorderSizePixel = 0,
	})
	newGui("UIStroke", root, { Color = color, Thickness = 3, Transparency = 0.1 })
	newGui("TextLabel", root, {
		Name = "Title",
		Size = UDim2.new(1, 0, 0.52, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = string.upper(tostring(element.mapId)),
		TextColor3 = color,
		TextScaled = true,
	})
	newGui("TextLabel", root, {
		Name = "Status",
		Position = UDim2.new(0, 0, 0.54, 0),
		Size = UDim2.new(1, 0, 0.4, 0),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamMedium,
		Text = "Встань на площадку",
		TextColor3 = Color3.fromRGB(226, 230, 240),
		TextScaled = true,
	})

	table.insert(ctx.portals, { mapId = element.mapId, padPart = pad, gui = surface })
end

--[[
	A lit name sign on two posts — the arena's front door.

	Text is rendered on BOTH faces. A gateway sign is walked under, and the half
	of the plaza that has already passed it would otherwise be looking at a blank
	slab. `board` gets away with one face because it is flat against a wall.

	`element.lines` is a list, not one string: a name reads as a logo when it is
	stacked, and TextScaled on a single 19-character line would shrink the letters
	to fit the width and leave the board mostly empty. The first line is drawn in
	trim, the rest in neon.

	`postHeight` is optional. Omitted, the board is mounted with nothing under it,
	which is what a sign flat against a wall wants.
]]
function Builders.sign(ctx, element)
	local facing = SIDE_NORMALS[element.facing or "+z"]
	local pos = worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)
	local base = CFrame.lookAt(pos, pos + Vector3.new(facing.x, 0, facing.z))
	local size = element.size
	local neon = resolveColor(ctx, "Neon")

	local board = makePart(ctx, {
		name = "SignBoard",
		size = Vector3.new(size.x, size.y, size.z),
		cframe = base,
		color = resolveColor(ctx, "Board"),
		-- Overhead and never walked into, so it neither collides nor blocks a
		-- shot: a sign that eats bullets fired across the plaza is a bug players
		-- would report as the gun not working.
		canCollide = false,
	})
	board.CanQuery = false

	-- The border is four edge bars rather than the larger slab behind the screen
	-- that `board` uses. A slab would be flush against the back face, which here
	-- carries the second copy of the text.
	for _, side in { -1, 1 } do
		makePart(ctx, {
			name = "SignGlow",
			size = Vector3.new(size.x + 3, 0.9, size.z + 0.4),
			cframe = base * CFrame.new(0, side * (size.y * 0.5 + 0.45), 0),
			color = neon,
			material = Enum.Material.Neon,
			canCollide = false,
			castShadow = false,
		})
		makePart(ctx, {
			name = "SignEdge",
			size = Vector3.new(1.5, size.y + 1.8, size.z + 0.4),
			cframe = base * CFrame.new(side * (size.x * 0.5 + 0.75), 0, 0),
			color = resolveColor(ctx, "Trim"),
			canCollide = false,
		})
	end

	if element.postHeight then
		local postOffsetY = -(size.y * 0.5 + element.postHeight * 0.5)
		for _, side in { -1, 1 } do
			makePart(ctx, {
				name = "SignPost",
				size = Vector3.new(2.4, element.postHeight, 2.4),
				cframe = base * CFrame.new(side * (size.x * 0.5 - 1.2), postOffsetY, 0),
				color = resolveColor(ctx, "Trim"),
			})
		end
	end

	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local surface = newGui("SurfaceGui", board, {
			Name = `SignGui{face.Name}`,
			Face = face,
			SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
			PixelsPerStud = 32,
			LightInfluence = 0,
			-- Further than the board's 500: this is the thing that tells a player
			-- which game they are in, and the plaza is 200 studs across.
			MaxDistance = 700,
		})
		local root = newGui("Frame", surface, {
			Name = "Root",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Color3.fromRGB(14, 16, 24),
			BorderSizePixel = 0,
		})
		newGui("UIPadding", root, {
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
			PaddingLeft = UDim.new(0, 18),
			PaddingRight = UDim.new(0, 18),
		})
		newGui("UIListLayout", root, {
			FillDirection = Enum.FillDirection.Vertical,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
		})

		local share = 1 / math.max(1, #element.lines)
		for index, line in element.lines do
			newGui("TextLabel", root, {
				Name = `Line{index}`,
				LayoutOrder = index,
				Size = UDim2.new(1, 0, share, 0),
				BackgroundTransparency = 1,
				Font = Enum.Font.GothamBlack,
				Text = line,
				TextColor3 = if index == 1 then resolveColor(ctx, "Trim") else neon,
				TextScaled = true,
			})
		end
	end
end

function Builders.board(ctx, element)
	local facing = SIDE_NORMALS[element.facing or "+z"]
	local pos = worldVec(ctx, element.pos.x, element.pos.y, element.pos.z)
	local base = CFrame.lookAt(pos, pos + Vector3.new(facing.x, 0, facing.z))
	local size = element.size

	makePart(ctx, {
		name = "BoardFrame",
		size = Vector3.new(size.x + 4, size.y + 4, size.z),
		cframe = base * CFrame.new(0, 0, size.z * 0.5),
		color = resolveColor(ctx, "Trim"),
	})

	local screen = makePart(ctx, {
		name = "BoardScreen",
		size = Vector3.new(size.x, size.y, size.z),
		cframe = base,
		color = resolveColor(ctx, "Board"),
	})

	makePart(ctx, {
		name = "BoardGlow",
		size = Vector3.new(size.x + 4, 1.4, size.z + 0.6),
		cframe = base * CFrame.new(0, -(size.y * 0.5 + 2.6), 0),
		color = resolveColor(ctx, "Neon"),
		material = Enum.Material.Neon,
		canCollide = false,
		castShadow = false,
	})

	local surface = newGui("SurfaceGui", screen, {
		Name = "BoardGui",
		Face = Enum.NormalId.Front,
		SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud,
		PixelsPerStud = 26,
		LightInfluence = 0,
		MaxDistance = 500,
	})
	local root = newGui("Frame", surface, {
		Name = "Root",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.fromRGB(14, 16, 24),
		BorderSizePixel = 0,
	})
	newGui("UIPadding", root, {
		PaddingTop = UDim.new(0, 12),
		PaddingBottom = UDim.new(0, 12),
		PaddingLeft = UDim.new(0, 16),
		PaddingRight = UDim.new(0, 16),
	})
	newGui("TextLabel", root, {
		Name = "Title",
		Size = UDim2.new(1, 0, 0, 56),
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBlack,
		Text = element.title or "ЛУЧШИЕ СТРЕЛКИ",
		TextColor3 = resolveColor(ctx, "Neon"),
		TextScaled = true,
	})
	local content = newGui("Frame", root, {
		Name = "Content",
		Position = UDim2.new(0, 0, 0, 64),
		Size = UDim2.new(1, 0, 1, -64),
		BackgroundTransparency = 1,
	})
	newGui("UIListLayout", content, {
		Padding = UDim.new(0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	})

	surface:SetAttribute("BoardId", element.boardId)
	ctx.boards[element.boardId] = surface
end

-- Public API --------------------------------------------------------------

function MapBuilder.getWorldFolder(): Folder
	local folder = workspace:FindFirstChild(WORLD_FOLDER_NAME)
	if folder and not folder:IsA("Folder") then
		folder:Destroy()
		folder = nil
	end
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = WORLD_FOLDER_NAME
		folder.Parent = workspace
	end
	return folder
end

--[[
	Builds `def` into workspace.World and returns a BuildResult:
	  {model, spawns = {A, B, Lobby}, portals = {{mapId, padPart, gui}},
	   boards = {[boardId] = SurfaceGui}, killY, origin, partCount}
	`killY` is absolute (origin.Y + def.killY) so callers can compare it straight
	against a character's world Y.
]]
function MapBuilder.build(def): { [string]: any }
	local world = MapBuilder.getWorldFolder()

	local previous = world:FindFirstChild(def.id)
	if previous then
		previous:Destroy()
	end

	local model = Instance.new("Model")
	model.Name = def.id

	local ctx = {
		def = def,
		model = model,
		origin = Vector3.new(def.origin.x, def.origin.y, def.origin.z),
		count = 0,
		spawns = { A = {}, B = {}, Lobby = {} },
		portals = {},
		boards = {},
	}

	for index, element in def.elements do
		local builder = Builders[element.kind]
		if not builder then
			warn(`[MapBuilder] {def.id} element #{index}: unknown kind "{tostring(element.kind)}"`)
			continue
		end
		local ok, err = pcall(builder, ctx, element)
		if not ok then
			warn(`[MapBuilder] {def.id} element #{index} ({element.kind}) failed: {err}`)
		end
	end

	model.Parent = world

	return {
		model = model,
		spawns = ctx.spawns,
		portals = ctx.portals,
		boards = ctx.boards,
		killY = ctx.origin.Y + def.killY,
		origin = ctx.origin,
		partCount = ctx.count,
	}
end

return MapBuilder
