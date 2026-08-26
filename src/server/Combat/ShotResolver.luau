--!nonstrict
--[[
	ShotResolver.luau
	Turns an accepted ShootRequest into what actually happened in the world: the
	server's own spread, the server's own raycast, and whichever player that ray
	found.

	The ray always starts at the SERVER-known eye position. The client's claimed
	origin never reaches this module — ShootValidation bounds it, and that is the
	only job it has. A client that moves its reported origin gets its shot
	rejected upstream; it can never move where the server shoots from.

	Split out of CombatService so the hot path — up to ten calls a second per
	player — reads as one straight line, and so the rules deciding whether a hit
	counts sit next to the raycast that produced it. Nothing here mutates player
	state: it reports, and CombatService acts.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local GunModelFactory = require(Shared.GunModelFactory)
local MathUtil = require(Shared.Util.MathUtil)
local SprayPatterns = require(Shared.Config.SprayPatterns)
local TeamService = require(script.Parent.Parent.Services.TeamService)
local Validators = require(script.Parent.Parent.Net.Validators)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ShotResolver = {}

export type Shot = {
	eye: Vector3,
	direction: Vector3,
	hitPos: Vector3,
	victim: Player?,
	humanoid: Humanoid?,
	hitPartName: string?,
}

-- Built once and reused: allocating RaycastParams per shot is the classic
-- hitscan hot-path cost. Only the exclude list changes between shots, and
-- Roblox copies that list on assignment, so the backing table is reused too.
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true
local filterList: { Instance } = {}

local playerService: any = nil
local playerServiceResolved = false

--[[
	PlayerService is written by a sibling agent and loads at priority 4. It is
	required on first use rather than at module scope so a missing module falls
	back to the replicated attribute instead of breaking every shot.
]]
local function getPlayerService(): any
	if playerServiceResolved then
		return playerService
	end
	playerServiceResolved = true

	local moduleScript = script.Parent.Parent.Services:FindFirstChild("PlayerService")
	if not moduleScript then
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	playerService = if ok and type(result) == "table" then result else nil
	return playerService
end

function ShotResolver.isSpawnProtected(player: Player): boolean
	local service = getPlayerService()
	if service and type(service.isSpawnProtected) == "function" then
		return service.isSpawnProtected(player) == true
	end

	-- The attribute PlayerService publishes carries the same answer and is
	-- server-written, so the fallback still trusts nothing the client sent.
	local protectedUntil = player:GetAttribute("SpawnProtectedUntil")
	return type(protectedUntil) == "number" and workspace:GetServerTimeNow() < protectedUntil
end

--[[
	End the shooter's spawn protection.

	Protection is there so a player cannot be killed before they can move, not so
	they can push out and trade while nothing can hurt them. Three seconds is
	long enough to cross a spawn lane, so firing gives it up.

	Same service-or-attribute path as isSpawnProtected: the attribute is the
	authority either way, so this works whether or not PlayerService is loaded.
]]
function ShotResolver.clearSpawnProtection(player: Player)
	local service = getPlayerService()
	if service and type(service.clearSpawnProtection) == "function" then
		service.clearSpawnProtection(player)
		return
	end

	if player:GetAttribute("SpawnProtectedUntil") ~= 0 then
		player:SetAttribute("SpawnProtectedUntil", 0)
	end
end

--[[
	Walk up from the hit part to the character that owns it. Accessories, hats
	and welded weapon parts nest arbitrarily deep, so a hit part's immediate
	parent is not reliably the character model.
]]
local function playerFromHit(instance: Instance?): (Player?, Instance?)
	local current: Instance? = instance
	while current and current ~= workspace do
		if current:IsA("Model") then
			local player = Players:GetPlayerFromCharacter(current)
			if player then
				return player, current
			end
		end
		current = current.Parent
	end

	return nil, nil
end

--[[
	Re-simulate one shot.

	`aim` is the client's reported look direction — already validated as unit
	length — and is the only part of the request that survives into the ray.
	`rng` returns a float in [0, 1); it is the server's, so a client cannot
	predict where its own spray lands.

	Returns nil when the shooter has no character or root part to shoot from.
]]
function ShotResolver.resolve(
	shooter: Player,
	weaponId: string,
	aim: Vector3,
	sprayIndex: number,
	rng: () -> number
): Shot?
	local weapon = WeaponConfig.get(weaponId)
	local eye = Validators.getHeadPosition(shooter)
	local character = shooter.Character
	if not weapon or not eye or not character then
		return nil
	end

	local spread = MathUtil.applySpread(
		{ x = aim.X, y = aim.Y, z = aim.Z },
		SprayPatterns.getServerSpreadDeg(weaponId, sprayIndex),
		rng
	)
	local direction = Vector3.new(spread.x, spread.y, spread.z)

	filterList[1] = character
	raycastParams.FilterDescendantsInstances = filterList

	local result = workspace:Raycast(eye, direction * weapon.range, raycastParams)
	local victim, victimCharacter = playerFromHit(result and result.Instance)

	return {
		eye = eye,
		direction = direction,
		-- A miss still needs an endpoint: the client draws a beam for every shot,
		-- and one that stops at the world origin is worse than one that overshoots.
		hitPos = if result then result.Position else eye + direction * weapon.range,
		victim = victim,
		humanoid = victimCharacter and victimCharacter:FindFirstChildOfClass("Humanoid") or nil,
		hitPartName = result and result.Instance and result.Instance.Name or nil,
	}
end

--[[
	Whether `victim` may legally take damage from `shooter` right now. A shot
	that fails here still draws its beam; it just does nothing on arrival.
]]
function ShotResolver.canDamage(shooter: Player, victim: Player, humanoid: Humanoid): boolean
	if victim == shooter then
		return false
	end

	if TeamService.sameTeam(shooter, victim) then
		return false
	end

	-- Both must be in the same match. Every map is built into the one workspace,
	-- so without this a long enough ray could reach across two of them.
	if victim:GetAttribute("InMatch") ~= shooter:GetAttribute("InMatch") then
		return false
	end

	if ShotResolver.isSpawnProtected(victim) then
		return false
	end

	return humanoid.Health > 0
end

--[[
	Where the third-person gun's muzzle is right now, for the beam other players
	see. Falls back to `fallback` (the eye position) so a player whose weapon
	model has not been welded yet still draws a beam from somewhere sensible.
]]
function ShotResolver.muzzlePosition(player: Player, weaponId: string, fallback: Vector3): Vector3
	local character = player.Character
	if not character then
		return fallback
	end

	for _, child in character:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("WeaponId") == weaponId then
			local muzzle = GunModelFactory.getMuzzle(child)
			if muzzle then
				return muzzle.WorldPosition
			end
		end
	end

	return fallback
end

return ShotResolver
