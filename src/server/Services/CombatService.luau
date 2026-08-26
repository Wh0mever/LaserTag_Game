--!nonstrict
--[[
	CombatService.luau
	Server-authoritative hitscan combat: the only place in the game that spends
	ammunition, decides a hit, or applies damage.

	A ShootRequest carries the client's *aim*, never its result. Admission is
	Combat/ShootValidation's job, re-simulating the shot is Combat/ShotResolver's,
	spending the magazine is Combat/WeaponState's; this service is the wiring
	between them and the remotes.

	Reward ownership: DataService.recordKill() is the single kill payout in this
	game (see the note at the top of DataService). This service must not also
	call addCoins for the same kill, or every frag pays twice.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local DamageCalc = require(script.Parent.Parent.Combat.DamageCalc)
local DataService = require(script.Parent.DataService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local ShootValidation = require(script.Parent.Parent.Combat.ShootValidation)
local ShotResolver = require(script.Parent.Parent.Combat.ShotResolver)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local TeamService = require(script.Parent.TeamService)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local WeaponState = require(script.Parent.Parent.Combat.WeaponState)

local CombatService = {}
CombatService.Priority = 6

-- Rate limits from the network contract. The rifle's 600 RPM is 50 shots per
-- five seconds, so 60 leaves headroom for burst jitter while still capping a
-- macro'd trigger well below what a modified fire rate would need.
local SHOOT_RATE, SHOOT_WINDOW = 60, 5
local RELOAD_RATE, RELOAD_WINDOW = 10, 5
local EQUIP_RATE, EQUIP_WINDOW = 20, 5

-- One RNG for every shot on the server. Resolving spread here rather than
-- trusting a client-deviated direction is what stops a no-spread client.
local rng = Random.new()
local function nextRandom(): number
	return rng:NextNumber()
end

local serviceTrove = Trove.new()
local playerTroves: { [Player]: any } = {}
local characterTroves: { [Player]: any } = {}

local matchService: any = nil
local matchServiceResolved = false

--[[
	MatchService is written by a sibling agent and loads at priority 5. It is
	required on first use rather than at module scope so a missing module makes
	kill registration a no-op instead of breaking combat for the whole server.
]]
local function getMatchService(): any
	if matchServiceResolved then
		return matchService
	end
	matchServiceResolved = true

	local moduleScript = script.Parent:FindFirstChild("MatchService")
	if not moduleScript then
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	matchService = if ok and type(result) == "table" then result else nil
	return matchService
end

local function pushAmmo(player: Player, weaponId: string)
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		return
	end

	local entry = WeaponState.get(player, weaponId)
	local reloading = WeaponState.isReloading(player, weaponId, workspace:GetServerTimeNow())

	-- `lastSeq` is the last shot this magazine count already accounts for. The
	-- client compares it against the last shot it sent: once the server has
	-- caught up, a count higher than the client's own is a correction (a refused
	-- shot handing the round back), not a sync that predates shots still in
	-- flight. Without it the client cannot tell those two apart.
	Remotes.fireClient(RemoteNames.AmmoSync, player, weaponId, entry.mag, weapon.magSize, reloading, entry.lastSeq)
end

local function beamColor(player: Player, weaponId: string): Color3
	local skin = SkinCatalog.get(DataService.getEquippedSkin(player, weaponId))
		or SkinCatalog.get(SkinCatalog.DEFAULT_SKIN_ID)
	return Color3.fromRGB(skin.color.r, skin.color.g, skin.color.b)
end

--[[
	Everything that happens once a shot has actually killed someone. Only ever
	reached from a hit that already passed ShotResolver.canDamage, so a suicide,
	a void death or a friendly-fire shot can never arrive here and pay out.
]]
local function registerKill(killer: Player, victim: Player, weaponId: string, isHeadshot: boolean)
	local service = getMatchService()
	if service and type(service.registerKill) == "function" then
		service.registerKill(victim, killer, weaponId, isHeadshot)
	end

	DataService.recordKill(killer, isHeadshot)
	DataService.recordDeath(victim)

	-- A dead player's reload must not land during their respawn timer.
	WeaponState.cancelAllReloads(victim)

	-- Both maps run their own match at the same time, so the feed is addressed
	-- to the map the kill happened on. Routing by the victim rather than the
	-- killer is deliberate: the victim is always still in that match, while the
	-- killer may already have left it.
	local mapId = victim:GetAttribute("InMatch")
	if type(mapId) == "string" and mapId ~= "" then
		for _, other in Players:GetPlayers() do
			if other:GetAttribute("InMatch") == mapId then
				Remotes.fireClient(
					RemoteNames.KillFeedEvent,
					other,
					killer.DisplayName,
					TeamService.getTeamId(killer),
					victim.DisplayName,
					TeamService.getTeamId(victim),
					weaponId,
					isHeadshot
				)
			end
		end
	end
end

--[[
	Apply one resolved hit. Returns whether it killed, and whether it was a
	headshot, so the caller can pay for the kill without re-deriving either.
]]
local function applyHit(shooter: Player, weaponId: string, shot): (boolean, boolean)
	local victim, humanoid = shot.victim, shot.humanoid
	if not victim or not humanoid or not ShotResolver.canDamage(shooter, victim, humanoid) then
		return false, false
	end

	-- Measured from the server's own eye position to where the server's own ray
	-- landed, so the distance that decides falloff is never a client's claim.
	local distance = (shot.hitPos - shot.eye).Magnitude

	local damage, isHeadshot =
		DamageCalc.compute(WeaponConfig.get(weaponId), shot.hitPartName, WeaponConfig.HEAD_PARTS, distance)

	local healthBefore = humanoid.Health
	humanoid:TakeDamage(damage)
	local killed = healthBefore > 0 and humanoid.Health <= 0

	Remotes.fireClient(RemoteNames.HitConfirmed, shooter, victim.UserId, damage, isHeadshot, shot.hitPos, killed)
	Remotes.fireClient(RemoteNames.DamageTaken, victim, shooter.UserId, damage, shot.eye)

	return killed, isHeadshot
end

local function onShootRequest(player: Player, weaponId: string, seq: number, _origin: Vector3, direction: Vector3)
	-- ShootValidation already cleared this request (it is the registered
	-- validator). Committing the sequence number here is what makes the same
	-- packet worthless when it is replayed.
	WeaponState.recordSeq(player, weaponId, seq)

	local fired, sprayIndex = WeaponState.consumeShot(player, weaponId, workspace:GetServerTimeNow())
	if not fired then
		-- Empty, mid-reload or too fast: the client's prediction has drifted, so
		-- correct it instead of leaving the HUD showing rounds that do not exist.
		pushAmmo(player, weaponId)
		return
	end

	local shot = ShotResolver.resolve(player, weaponId, direction, sprayIndex, nextRandom)
	if not shot then
		return
	end

	local killed, isHeadshot = applyHit(player, weaponId, shot)

	-- The shooter already drew its own beam from the local viewmodel, so it is
	-- excluded rather than sent a second, slightly different one.
	Remotes.fireAllClientsExcept(
		RemoteNames.ShotFired,
		player,
		player.UserId,
		weaponId,
		ShotResolver.muzzlePosition(player, weaponId, shot.eye),
		shot.hitPos,
		beamColor(player, weaponId)
	)

	if killed then
		registerKill(player, shot.victim, weaponId, isHeadshot)
	end

	pushAmmo(player, weaponId)
end

local function onReloadRequest(player: Player, weaponId: string)
	local started, token = WeaponState.beginReload(player, weaponId, workspace:GetServerTimeNow())
	if not started then
		return
	end

	pushAmmo(player, weaponId)

	local weapon = WeaponConfig.get(weaponId)
	task.delay(weapon.reloadTime, function()
		-- The token is what lets a weapon switch, a death or a respawn cancel
		-- this reload: each of those bumps it, so this timer finds a stale token
		-- and leaves the magazine alone.
		if not player.Parent or not WeaponState.finishReload(player, weaponId, token) then
			return
		end
		pushAmmo(player, weaponId)
	end)
end

local function onEquipWeaponRequest(player: Player, slot: number)
	local weaponId = WeaponConfig.fromSlot(slot)
	local previous = player:GetAttribute("CurrentWeapon")

	if previous == weaponId then
		pushAmmo(player, weaponId)
		return
	end

	-- Switching away abandons any reload in flight and leaves the magazine where
	-- it was, so "reload, swap, swap back" is not a free instant refill.
	if WeaponConfig.exists(previous) then
		WeaponState.cancelReload(player, previous)
		pushAmmo(player, previous)
	end

	player:SetAttribute("CurrentWeapon", weaponId)
	pushAmmo(player, weaponId)
end

local function onCharacterAdded(player: Player, character: Model)
	local previous = characterTroves[player]
	if previous then
		previous:Clean()
	end

	local trove = Trove.new()
	characterTroves[player] = trove

	-- A new life starts with full magazines and a clean spray pattern; any
	-- reload the previous life had in flight dies with it.
	WeaponState.reset(player)

	if not WeaponConfig.exists(player:GetAttribute("CurrentWeapon")) then
		player:SetAttribute("CurrentWeapon", Constants.SLOTS[Constants.DEFAULT_SLOT])
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid") or character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		trove:Connect(humanoid.Died, function()
			WeaponState.cancelAllReloads(player)
		end)
	end

	-- Both weapons, so the HUD is already correct when the player swaps.
	CombatService.syncAmmo(player)
end

local function onPlayerAdded(player: Player)
	if playerTroves[player] then
		return
	end

	local trove = Trove.new()
	playerTroves[player] = trove

	trove:Connect(player.CharacterAdded, function(character)
		onCharacterAdded(player, character)
	end)

	if player.Character then
		task.spawn(onCharacterAdded, player, player.Character)
	end
end

--[[
	Drop every connection and all weapon state for a player. Safe to call twice:
	PlayerService may call it from its own teardown and this service also
	connects to PlayerRemoving directly, so combat still cleans up if
	PlayerService is not loaded.
]]
function CombatService.onPlayerRemoving(player: Player)
	for _, troves in { playerTroves, characterTroves } do
		local trove = troves[player]
		if trove then
			trove:Clean()
			troves[player] = nil
		end
	end

	WeaponState.clear(player)
end

--[[
	Re-send the authoritative magazine for one weapon, or for both when
	`weaponId` is omitted. Other services call this after moving a player between
	the hub and a match so the HUD never shows a stale count.
]]
function CombatService.syncAmmo(player: Player, weaponId: string?)
	if weaponId then
		pushAmmo(player, weaponId)
		return
	end

	-- The weapon in hand is sent LAST. Events to one client arrive in order, so
	-- whichever sync lands last is the one the HUD ends up showing; sending the
	-- stowed weapon first is what stops a fresh spawn from displaying the
	-- pistol's magazine while the player is holding the rifle.
	local current = player:GetAttribute("CurrentWeapon")
	for _, id in WeaponConfig.Order do
		if id ~= current then
			pushAmmo(player, id)
		end
	end

	if WeaponConfig.exists(current) then
		pushAmmo(player, current)
	end
end

function CombatService.init()
	Remotes.register({
		Name = RemoteNames.ShootRequest,
		Type = "Event",
		Handler = onShootRequest,
		Validator = ShootValidation.validate,
		RateLimit = SHOOT_RATE,
		WindowSeconds = SHOOT_WINDOW,
	})

	Remotes.register({
		Name = RemoteNames.ReloadRequest,
		Type = "Event",
		Handler = onReloadRequest,
		Validator = ShootValidation.validateReload,
		RateLimit = RELOAD_RATE,
		WindowSeconds = RELOAD_WINDOW,
	})

	Remotes.register({
		Name = RemoteNames.EquipWeaponRequest,
		Type = "Event",
		Handler = onEquipWeaponRequest,
		Validator = ShootValidation.validateEquip,
		RateLimit = EQUIP_RATE,
		WindowSeconds = EQUIP_WINDOW,
	})

	serviceTrove:Connect(Players.PlayerAdded, onPlayerAdded)
	serviceTrove:Connect(Players.PlayerRemoving, CombatService.onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return CombatService
