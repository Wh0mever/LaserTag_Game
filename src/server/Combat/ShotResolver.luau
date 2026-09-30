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

	Players are tested where the shooter SAW them. A shot fires at what the
	shooter's screen shows, which is other players a round trip and some
	interpolation in the past, and it lands here that much later. Testing it
	against where targets are by then misses everything that moves (at running
	speed a tenth of a second is wider than a body), so each candidate target is
	placed where it was, by CharacterTracker's history, before the ray is cast.

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

local CharacterTracker = require(script.Parent.CharacterTracker)
local GunModelFactory = require(Shared.GunModelFactory)
local MathUtil = require(Shared.Util.MathUtil)
local SprayPatterns = require(Shared.Config.SprayPatterns)
local TeamService = require(script.Parent.Parent.Services.TeamService)
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
-- hitscan hot-path cost. Only the filter list changes between shots, and
-- Roblox copies that list on assignment, so the backing tables are reused too.
--
-- Two casts serve a shot: one at the world with every character excluded, and
-- one per candidate target that sees only that target.
local worldParams = RaycastParams.new()
worldParams.FilterType = Enum.RaycastFilterType.Exclude
worldParams.IgnoreWater = true
local worldFilter: { Instance } = {}

local targetParams = RaycastParams.new()
targetParams.FilterType = Enum.RaycastFilterType.Include
targetParams.IgnoreWater = true
local targetFilter: { Instance } = {}

-- A character further than this from the line of fire (studs, centre of the
-- torso to the nearest point of the ray) cannot be hit by it. A body is about
-- five studs tall and a held weapon reaches a few more; this only exists to
-- avoid casting at people on the far side of the map.
local BROAD_PHASE_RADIUS = 8

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
	The name a hit part is scored under.

	Accessories are made invisible to shots when the character is set up
	(CharacterHitboxes), so a ray normally goes straight through a hat to the
	head under it. This is the second line, for a hat that is still hittable --
	one added in the frame before the hook ran, or a hook that never did: it
	counts as the body part it is worn on, so a shot at hair is a headshot and
	one at a backpack is a body shot, and neither is a hit on "Handle".
]]
local function scoredPartName(instance: Instance): string
	local accessory = instance:FindFirstAncestorWhichIsA("Accoutrement")
	if not accessory then
		return instance.Name
	end

	local weld = accessory:FindFirstChild("AccessoryWeld", true)
	if weld and weld:IsA("JointInstance") then
		for _, part in { weld.Part0, weld.Part1 } do
			if part and not part:IsDescendantOf(accessory) then
				return part.Name
			end
		end
	end
	return instance.Name
end

-- Distance from `point` to the segment starting at `origin` along the unit
-- vector `unit`, `reach` studs long.
local function distanceToSegment(point: Vector3, origin: Vector3, unit: Vector3, reach: number): number
	local along = math.clamp((point - origin):Dot(unit), 0, reach)
	return (point - (origin + unit * along)).Magnitude
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
	local eye = CharacterTracker.eyePosition(shooter)
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
	local unit = direction.Unit
	local reach = direction * weapon.range

	-- The world first: everything solid that is not somebody's body. How far it
	-- lets the ray go is how far any player can be hit.
	table.clear(worldFilter)
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(worldFilter, other.Character)
		end
	end
	worldParams.FilterDescendantsInstances = worldFilter

	local worldHit = workspace:Raycast(eye, reach, worldParams)
	local nearest = if worldHit then worldHit.Distance else weapon.range

	-- Then every candidate, placed where the shooter saw them. Casting at a
	-- target moved back by `offset` is casting at the target where it stands from
	-- a ray moved forward by the same amount, which lets the engine do the
	-- hit-testing against the real shapes of the real parts.
	local matchId = shooter:GetAttribute("InMatch")
	local now = workspace:GetServerTimeNow()
	local rewind = CharacterTracker.rewindSeconds(shooter)

	local victim, victimCharacter, hitInstance = nil, nil, nil
	for _, other in Players:GetPlayers() do
		local otherCharacter = other.Character
		local root = otherCharacter and otherCharacter:FindFirstChild("HumanoidRootPart")
		if other == shooter or not root or other:GetAttribute("InMatch") ~= matchId then
			continue
		end

		local standing = root.Position
		local was = CharacterTracker.rootPositionAgo(other, rewind, now)
		local offset = if was then standing - was else Vector3.new(0, 0, 0)

		if distanceToSegment(was or standing, eye, unit, weapon.range) > BROAD_PHASE_RADIUS then
			continue
		end

		targetFilter[1] = otherCharacter
		targetParams.FilterDescendantsInstances = targetFilter
		local hit = workspace:Raycast(eye + offset, reach, targetParams)

		-- Strictly nearer than the world and than any other target: cover in the
		-- way stops the shot, and so does a teammate in front of an enemy.
		if hit and hit.Distance < nearest then
			nearest = hit.Distance
			victim, victimCharacter, hitInstance = other, otherCharacter, hit.Instance
		end
	end

	return {
		eye = eye,
		direction = direction,
		-- Measured along the shot, so a target hit where the shooter saw it is
		-- reported where the shooter saw it, not where it has run to since. A miss
		-- still needs an endpoint: the client draws a beam for every shot, and one
		-- that stops at the world origin is worse than one that overshoots.
		hitPos = eye + unit * nearest,
		victim = victim,
		humanoid = victimCharacter and victimCharacter:FindFirstChildOfClass("Humanoid") or nil,
		hitPartName = hitInstance and scoredPartName(hitInstance) or nil,
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
