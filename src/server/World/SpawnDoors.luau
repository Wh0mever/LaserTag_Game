--!nonstrict
--[[
	SpawnDoors.luau
	One-way spawn-room doors built out of collision groups.

	A door panel belongs to the group of the team that owns it. That team's
	characters are made non-collidable with it, so they walk straight out;
	everybody else (the enemy team and lobby characters) is stopped by it.

	Doors keep CanQuery = true and stay collidable with the "Default" group, which
	is the group RaycastParams uses unless a caller overrides it — so laser
	raycasts are blocked by a spawn door from both sides even though the owning
	team can physically walk through it. That asymmetry is the whole point: you
	can leave your spawn, but nobody can shoot in or out of it.
]]

local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
local Constants = require(Shared.Constants)
local Trove = require(Shared.Util.Trove)

local SpawnDoors = {}

-- "Default" is registered by Roblox itself; it is listed so the collidability
-- matrix below is written in one place and never depends on registration order.
local GROUPS = { "Default", "SpawnDoorA", "SpawnDoorB", "CharacterA", "CharacterB" }

local DOOR_GROUP = { A = "SpawnDoorA", B = "SpawnDoorB" }
local CHARACTER_GROUP = { A = "CharacterA", B = "CharacterB" }

local DOOR_TRANSPARENCY = 0.55

local groupsReady = false
local characterTroves: { [Model]: any } = {}

local function teamColor(teamId: string?): Color3
	local team = Constants.TEAMS[teamId or ""] or Constants.TEAMS.LOBBY
	return Color3.fromRGB(team.color.r, team.color.g, team.color.b)
end

local function setCollidable(a: string, b: string, collidable: boolean)
	local ok, err = pcall(function()
		PhysicsService:CollisionGroupSetCollidable(a, b, collidable)
	end)
	if not ok then
		warn(`[SpawnDoors] could not set {a} <-> {b} collidable: {err}`)
	end
end

--[[
	Registers the collision groups and the collidability matrix. Safe to call
	more than once; subsequent calls are no-ops.
]]
function SpawnDoors.setupCollisionGroups()
	if groupsReady then
		return
	end
	groupsReady = true

	for _, name in GROUPS do
		if not PhysicsService:IsCollisionGroupRegistered(name) then
			local ok, err = pcall(function()
				PhysicsService:RegisterCollisionGroup(name)
			end)
			if not ok then
				warn(`[SpawnDoors] could not register collision group {name}: {err}`)
			end
		end
	end

	-- Own door: pass through. Enemy door and lobby characters: solid.
	setCollidable("CharacterA", "SpawnDoorA", false)
	setCollidable("CharacterB", "SpawnDoorB", false)
	setCollidable("CharacterA", "SpawnDoorB", true)
	setCollidable("CharacterB", "SpawnDoorA", true)
	setCollidable("Default", "SpawnDoorA", true)
	setCollidable("Default", "SpawnDoorB", true)

	-- Character-vs-character collidability is deliberately left at the Roblox
	-- default (solid) so moving characters into these groups changes nothing
	-- except how they interact with doors.
end

local function assignGroup(instance: Instance, group: string)
	if not instance:IsA("BasePart") then
		return
	end
	local ok, err = pcall(function()
		instance.CollisionGroup = group
	end)
	if not ok then
		warn(`[SpawnDoors] could not assign collision group {group}: {err}`)
	end
end

--[[
	Builds a translucent neon door panel for `teamId`.
	`cframe` should place the panel in the doorway with its thin axis along the
	wall normal; `size` is the panel size in that frame.
]]
function SpawnDoors.makeDoor(teamId: string, cframe: CFrame, size: Vector3): BasePart
	local door = Instance.new("Part")
	door.Name = `SpawnDoor{teamId}`
	door.Anchored = true
	door.CanCollide = true
	door.CanQuery = true
	door.CanTouch = false
	door.CastShadow = false
	door.Material = Enum.Material.Neon
	door.Color = teamColor(teamId)
	door.Transparency = DOOR_TRANSPARENCY
	door.TopSurface = Enum.SurfaceType.Smooth
	door.BottomSurface = Enum.SurfaceType.Smooth
	door.Size = size
	door.CFrame = cframe

	assignGroup(door, DOOR_GROUP[teamId] or "Default")

	door:SetAttribute("SpawnDoorTeam", teamId)

	return door
end

--[[
	Stops tracking a character and drops its connections. Called automatically
	when the character leaves the DataModel; PlayerService may also call it
	explicitly when it recycles a character.
]]
function SpawnDoors.releaseCharacter(character: Model)
	local trove = characterTroves[character]
	if trove then
		characterTroves[character] = nil
		trove:Clean()
	end
end

--[[
	Puts every part of `character` into that team's collision group so the spawn
	doors treat it correctly. Accessories and tools added later are picked up by
	the tracked DescendantAdded connection.
]]
function SpawnDoors.applyToCharacter(character: Model, teamId: string?)
	SpawnDoors.releaseCharacter(character)

	local group = CHARACTER_GROUP[teamId or ""] or "Default"

	local trove = Trove.new()
	characterTroves[character] = trove

	for _, descendant in character:GetDescendants() do
		assignGroup(descendant, group)
	end

	trove:Connect(character.DescendantAdded, function(descendant)
		assignGroup(descendant, group)
	end)

	trove:Connect(character.AncestryChanged, function()
		if not character:IsDescendantOf(game) then
			SpawnDoors.releaseCharacter(character)
		end
	end)

	trove:Connect(character.Destroying, function()
		SpawnDoors.releaseCharacter(character)
	end)
end

--[[
	Collision group name a character of `teamId` is placed in. Exposed so other
	systems (raycast filters, tests) do not have to hardcode the strings.
]]
function SpawnDoors.characterGroup(teamId: string?): string
	return CHARACTER_GROUP[teamId or ""] or "Default"
end

return SpawnDoors
