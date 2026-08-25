--!nonstrict
--[[
	PlayerService.luau
	The join flow and every character spawn in the game.

	Players.CharacterAutoLoads is off (default.project.json sets it, init() sets it
	again), so a character exists only because this service made one. That is what
	lets a player wait in the hub, be teleported into a match, die and come back
	three seconds later on their own team's spawn — all without Roblox's own
	respawn logic ever fighting the match state.

	Priority 4 — after WorldService (3), which owns the spawn CFrames, and before
	MatchService (5), which spawns players into matches through here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local DataService = require(script.Parent.DataService)
local GameConfig = require(Shared.Config.GameConfig)
local GunModelFactory = require(Shared.GunModelFactory)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local SpawnDoors = require(script.Parent.Parent.World.SpawnDoors)
local TeamService = require(script.Parent.TeamService)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local WorldService = require(script.Parent.WorldService)

local PlayerService = {}
PlayerService.Priority = 4

-- WorldService builds every map inside one synchronous start(); this only has to
-- outlast a slow first frame, not a network call.
local WORLD_WAIT_TIMEOUT = 30
local WORLD_POLL_INTERVAL = 0.1

-- Grip offsets are tuned against the R15 RightHand and the UpperTorso. A rig
-- without those parts falls back to the root so a weapon is never orphaned.
local HAND_GRIP = CFrame.new(0, -0.5, -0.6) * CFrame.Angles(math.rad(-90), 0, 0)
local BACK_STOW = CFrame.new(-0.9, 0.1, 0.75) * CFrame.Angles(0, math.rad(90), math.rad(-18))
local GRIP_NAME = "WeaponGrip"

local characterTroves: { [Player]: any } = {}
local weapons: { [Player]: { [string]: Model } } = {}
local respawning: { [Player]: boolean } = {}
local serviceTrove = Trove.new()
local killPlaneAccumulator = 0

--------------------------------------------------------------------------------
-- Lazy siblings
--------------------------------------------------------------------------------

local siblings: { [string]: any } = {}

--[[
	Require a sibling module the first time it is actually needed. MatchService
	requires this file at load time (through MatchRuntime), so requiring it back
	at load time would be a cycle; Combat/WeaponState may not exist at all in a
	build that has not landed yet. Both cases resolve to nil rather than throwing.
]]
local function lazySibling(parent: Instance?, name: string)
	if siblings[name] ~= nil then
		return siblings[name]
	end

	local module = if parent then parent:FindFirstChild(name) else nil
	if not module or not module:IsA("ModuleScript") then
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok then
		warn(`[PlayerService] could not require {name}: {result}`)
		return nil
	end

	siblings[name] = result
	return result
end

local function getMatchService()
	return lazySibling(script.Parent, "MatchService")
end

--------------------------------------------------------------------------------
-- Weapons
--------------------------------------------------------------------------------

local function limb(character: Model, primary: string, fallback: string): BasePart?
	local part = character:FindFirstChild(primary) or character:FindFirstChild(fallback)
	if part and part:IsA("BasePart") then
		return part
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function weldTo(model: Model, anchorPart: BasePart?, offset: CFrame)
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if not anchorPart or not handle or not handle:IsA("BasePart") then
		return
	end

	local existing = handle:FindFirstChild(GRIP_NAME)
	if existing then
		existing:Destroy()
	end

	-- Position before welding: a Weld snaps Part1 into place on its own, but not
	-- until the next physics step, which is one visible frame of a floating gun.
	handle.CFrame = anchorPart.CFrame * offset

	local weld = Instance.new("Weld")
	weld.Name = GRIP_NAME
	weld.Part0 = anchorPart
	weld.Part1 = handle
	weld.C0 = offset
	weld.Parent = handle
end

--[[
	Put the active weapon in the hand and the other across the back. Called on
	every spawn and on every weapon switch, so it must be safe to run repeatedly
	against the same models.
]]
local function poseWeapons(player: Player, character: Model, activeId: string)
	local models = weapons[player]
	if not models then
		return
	end

	local hand = limb(character, "RightHand", "Right Arm")
	local back = limb(character, "UpperTorso", "Torso")

	for weaponId, model in models do
		if model.Parent then
			local isActive = weaponId == activeId
			weldTo(model, if isActive then hand else back, if isActive then HAND_GRIP else BACK_STOW)
		end
	end
end

--[[
	Build both weapon models with the player's equipped skins and attach them.
	Also the refresh path after a skin purchase: ShopService calls this to rebuild
	with the new colours.
]]
function PlayerService.giveWeapons(player: Player)
	local character = player.Character
	if not character then
		return
	end

	PlayerService.clearWeapons(player)

	local models: { [string]: Model } = {}
	for _, weaponId in WeaponConfig.Order do
		local model = GunModelFactory.build(weaponId, DataService.getEquippedSkin(player, weaponId))
		if model then
			model.Parent = character
			models[weaponId] = model
		end
	end
	weapons[player] = models

	local activeId = player:GetAttribute("CurrentWeapon")
	if not WeaponConfig.exists(activeId) then
		activeId = Constants.SLOTS[Constants.DEFAULT_SLOT]
		player:SetAttribute("CurrentWeapon", activeId)
	end

	poseWeapons(player, character, activeId)
end

function PlayerService.clearWeapons(player: Player)
	local models = weapons[player]
	weapons[player] = nil
	if not models then
		return
	end

	for _, model in models do
		model:Destroy()
	end
end

--[[
	Switch which weapon is in hand.

	The CurrentWeapon attribute is the switch: the character hook below re-poses
	on every change to it, so a service that sets the attribute directly (as
	CombatService does when it accepts an EquipWeaponRequest) still moves the
	third-person model. Setting an attribute to the value it already holds fires
	no signal, hence the explicit re-pose on that path.
]]
function PlayerService.setActiveWeapon(player: Player, weaponId: string): boolean
	if not WeaponConfig.exists(weaponId) then
		return false
	end

	if player:GetAttribute("CurrentWeapon") == weaponId then
		local character = player.Character
		if character then
			poseWeapons(player, character, weaponId)
		end
	else
		player:SetAttribute("CurrentWeapon", weaponId)
	end

	return true
end

--------------------------------------------------------------------------------
-- Spawning
--------------------------------------------------------------------------------

function PlayerService.isSpawnProtected(player: Player): boolean
	local until_ = player:GetAttribute("SpawnProtectedUntil")
	return type(until_) == "number" and workspace:GetServerTimeNow() < until_
end

local function configureCharacter(player: Player, character: Model, teamId: string)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = Constants.MAX_HEALTH
		humanoid.Health = Constants.MAX_HEALTH
		humanoid.WalkSpeed = Constants.WALK_SPEED
		humanoid.UseJumpPower = true
		humanoid.JumpPower = Constants.JUMP_POWER
	end

	-- Collision group first: it is what decides whether this character can walk
	-- out through its own spawn door.
	SpawnDoors.applyToCharacter(character, teamId)
	player:SetAttribute("SpawnProtectedUntil", workspace:GetServerTimeNow() + Constants.SPAWN_PROTECTION_SECONDS)
end

--[[
	Watch one character: its death, and the weapon it is holding.

	The death hook is deferred by a resumption so an attributed scheduleRespawn
	from MatchService (which knows who fired) is already registered by the time
	this unattributed one runs — otherwise the client would be told it died to
	nobody.
]]
local function trackCharacter(player: Player, character: Model, mapId: string, teamId: string)
	local previous = characterTroves[player]
	if previous then
		previous:Clean()
	end

	local trove = Trove.new()
	characterTroves[player] = trove

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		trove:Connect(humanoid.Died, function()
			task.defer(PlayerService.scheduleRespawn, player, mapId, teamId, nil)
		end)
	end

	trove:Connect(player:GetAttributeChangedSignal("CurrentWeapon"), function()
		local weaponId = player:GetAttribute("CurrentWeapon")
		if WeaponConfig.exists(weaponId) then
			poseWeapons(player, character, weaponId)
		end
	end)
end

local function spawnAt(player: Player, mapId: string, teamId: string, pivot: CFrame): Model?
	if not player:IsDescendantOf(Players) then
		return nil
	end

	player:SetAttribute("InMatch", mapId)

	local ok, err = pcall(function()
		player:LoadCharacter()
	end)
	if not ok then
		warn(`[PlayerService] LoadCharacter failed for {player.Name}: {err}`)
		return nil
	end

	local character = player.Character
	if not character or not character.Parent then
		return nil
	end

	character:PivotTo(pivot)
	configureCharacter(player, character, teamId)
	trackCharacter(player, character, mapId, teamId)

	return character
end

--[[
	Spawn in the hub: no weapons, lobby team, no map id. Yields on LoadCharacter.
]]
function PlayerService.spawnInHub(player: Player)
	TeamService.moveToLobby(player)

	local character = spawnAt(player, "", TeamService.getTeamId(player), WorldService.getHubSpawn())
	if character then
		PlayerService.clearWeapons(player)
	end
end

--[[
	Spawn onto a team's spawn point on `mapId`, armed. Yields on LoadCharacter.
]]
function PlayerService.spawnInMatch(player: Player, mapId: string, teamId: string)
	TeamService.assignToTeam(player, teamId)

	local character = spawnAt(player, mapId, teamId, WorldService.getSpawn(mapId, teamId))
	if character then
		PlayerService.giveWeapons(player)
	end
end

--[[
	Bring a dead player back after Constants.RESPAWN_SECONDS.

	Idempotent on purpose: the kill path and the Humanoid.Died hook both call it
	for the same death, and a second timer would spawn the player twice. The first
	call wins, which is why the kill path (the one carrying `killerUserId`) is the
	one that runs first.
]]
function PlayerService.scheduleRespawn(player: Player, mapId: string, teamId: string, killerUserId: number?)
	if respawning[player] then
		return
	end
	respawning[player] = true

	Remotes.fireClient(RemoteNames.DeathInfo, player, killerUserId, Constants.RESPAWN_SECONDS)

	task.delay(Constants.RESPAWN_SECONDS, function()
		respawning[player] = nil

		if not player:IsDescendantOf(Players) then
			return
		end

		if mapId and mapId ~= "" then
			local matchService = getMatchService()
			local stillPlaying = matchService ~= nil
				and matchService.isInProgress(mapId)
				and player:GetAttribute("InMatch") == mapId

			if stillPlaying then
				PlayerService.spawnInMatch(player, mapId, teamId)
			elseif not player.Character then
				-- The match ended mid-respawn. Whoever returned the roster to the
				-- hub has usually spawned them already; step in only if nobody did.
				PlayerService.spawnInHub(player)
			end
			return
		end

		PlayerService.spawnInHub(player)
	end)
end

--------------------------------------------------------------------------------
-- Kill plane
--------------------------------------------------------------------------------

--[[
	Anything below a map's killY has fallen out of the world. Killing it (rather
	than teleporting it back) keeps the death, the kill feed and the respawn on
	the one code path every other death uses.
]]
local function enforceKillPlane()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")

		if root and humanoid and humanoid.Health > 0 then
			local mapId = player:GetAttribute("InMatch")
			if type(mapId) ~= "string" or mapId == "" then
				mapId = Constants.HUB_ID
			end

			if root.Position.Y < WorldService.getKillY(mapId) then
				humanoid.Health = 0
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function PlayerService.init()
	-- Set here as well as in default.project.json: a place file that lost the
	-- property would double-spawn everyone, once into the hub and once wherever
	-- Roblox felt like putting them.
	Players.CharacterAutoLoads = false
end

function PlayerService.start()
	serviceTrove:Connect(RunService.Heartbeat, function(dt: number)
		killPlaneAccumulator += dt
		if killPlaneAccumulator < GameConfig.KILL_PLANE_INTERVAL then
			return
		end
		killPlaneAccumulator = 0
		enforceKillPlane()
	end)
end

local function waitForWorld(): boolean
	local deadline = os.clock() + WORLD_WAIT_TIMEOUT
	while not WorldService.isBuilt() and os.clock() < deadline do
		task.wait(WORLD_POLL_INTERVAL)
	end
	return WorldService.isBuilt()
end

--[[
	Called by init.server.luau. Yields twice — once on the profile load, once on
	the world build — so every step re-checks that the player is still here.
]]
function PlayerService.onPlayerAdded(player: Player)
	-- Set before anything yields: the client reads these attributes as soon as it
	-- boots, and an absent InMatch is indistinguishable from "in a match" to code
	-- that only checks for a non-empty string.
	player:SetAttribute("InMatch", "")
	player:SetAttribute("TeamId", "LOBBY")
	player:SetAttribute("CurrentWeapon", Constants.SLOTS[Constants.DEFAULT_SLOT])
	player:SetAttribute("SpawnProtectedUntil", 0)

	DataService.loadPlayer(player)
	if not player:IsDescendantOf(Players) then
		return
	end

	if not waitForWorld() then
		warn(`[PlayerService] world never finished building; spawning {player.Name} anyway`)
	end
	if not player:IsDescendantOf(Players) then
		return
	end

	TeamService.moveToLobby(player)
	PlayerService.spawnInHub(player)
end

function PlayerService.onPlayerRemoving(player: Player)
	local matchService = getMatchService()
	if matchService then
		local ok, err = pcall(matchService.onPlayerRemoving, player)
		if not ok then
			warn(`[PlayerService] MatchService.onPlayerRemoving failed for {player.Name}: {err}`)
		end
	end

	local weaponState = lazySibling(script.Parent.Parent:FindFirstChild("Combat"), "WeaponState")
	if weaponState and type(weaponState.clear) == "function" then
		pcall(weaponState.clear, player)
	end

	respawning[player] = nil
	PlayerService.clearWeapons(player)

	local trove = characterTroves[player]
	if trove then
		characterTroves[player] = nil
		trove:Clean()
	end

	DataService.releasePlayer(player)
end

return PlayerService
