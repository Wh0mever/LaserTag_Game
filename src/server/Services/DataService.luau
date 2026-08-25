--!nonstrict
--[[
	DataService.luau
	Owns every persistent profile. Nothing else on the server may touch
	Profile.Data directly — coins, stats, skins and spin state all move through the
	functions below, so clamping, validation and client sync happen in one place.

	Reward ownership (read this before adding a coin grant elsewhere):
	  * recordKill() is the single place a kill is paid for. Callers must NOT also
	    call addCoins() for the same kill or every frag pays twice.
	  * recordMatchResult() records stats ONLY. Match payouts stay with
	    MatchService: a boolean cannot express a draw, and MatchService has to
	    publish the same numbers in the Results payload anyway.

	Session locking, auto-save, retries and shutdown flushing belong to the
	vendored ProfileService; this module only handles the lifecycle around it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local EconomyConfig = require(Shared.Config.EconomyConfig)
local GameConfig = require(Shared.Config.GameConfig)
local MathUtil = require(Shared.Util.MathUtil)
local ProfileService = require(script.Parent.Parent.Vendor.ProfileService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local Signal = require(Shared.Util.Signal)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local SpinConfig = require(Shared.Config.SpinConfig)
local TableUtil = require(Shared.Util.TableUtil)
local Validators = require(script.Parent.Parent.Net.Validators)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local DataService = {}
DataService.Priority = 1
DataService.ProfileLoadedSignal = Signal.new()

-- Bump DataVersion when a field changes meaning rather than when one is added:
-- Profile:Reconcile() already backfills new keys from this template.
local PROFILE_TEMPLATE = {
	DataVersion = 1,
	Coins = EconomyConfig.STARTING_COINS,
	Stats = {
		Kills = 0,
		Deaths = 0,
		Wins = 0,
		MatchesPlayed = 0,
		BestKillsInMatch = 0,
	},
	OwnedSkins = {},
	EquippedSkins = {
		Rifle = SkinCatalog.DEFAULT_SKIN_ID,
		Pistol = SkinCatalog.DEFAULT_SKIN_ID,
	},
	Spin = {
		LastFreeSpinAt = 0,
		Pity = 0,
		TotalSpins = 0,
	},
}

local KEY_PREFIX = "Player_"
local LOAD_FAILED_MESSAGE = "Could not load your data. Please rejoin."
local RELEASED_MESSAGE = "Your data was opened on another server. Please rejoin."

local profileStore = nil
local profiles: { [Player]: any } = {}
local loading: { [Player]: boolean } = {}

function DataService.init()
	profileStore = ProfileService.GetProfileStore(GameConfig.PROFILE_STORE_NAME, PROFILE_TEMPLATE)
end

-- Leaderstats mirror the profile; the profile is always the source of truth.
local function setStat(player: Player, name: string, amount: number)
	local folder = player:FindFirstChild("leaderstats")
	local stat = folder and folder:FindFirstChild(name)
	if stat and stat:IsA("IntValue") then
		stat.Value = amount
	end
end

local function buildLeaderstats(player: Player, data)
	local existing = player:FindFirstChild("leaderstats")
	if existing then
		existing:Destroy()
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	for _, entry in { { "Kills", data.Stats.Kills }, { "Coins", data.Coins } } do
		local stat = Instance.new("IntValue")
		stat.Name = entry[1]
		stat.Value = entry[2]
		stat.Parent = folder
	end

	folder.Parent = player
end

local function syncCoins(player: Player, data)
	player:SetAttribute("Coins", data.Coins)
	setStat(player, "Coins", data.Coins)
end

function DataService.getData(player: Player)
	local profile = profiles[player]
	return if profile and profile:IsActive() then profile.Data else nil
end

function DataService.isLoaded(player: Player): boolean
	return DataService.getData(player) ~= nil
end

--[[
	Grant coins. Amount must be a positive integer and is clamped to
	EconomyConfig.MAX_SINGLE_AWARD: anything above that ceiling is a bug or a
	compromised call site, and silently paying it out is how an economy dies.
]]
function DataService.addCoins(player: Player, amount: number, reason: string): boolean
	local data = DataService.getData(player)
	if not data then
		return false
	end

	if not Validators.isPositiveInteger(amount) then
		warn(`[DataService] Rejected a coin award of {tostring(amount)} for {player.Name} ({tostring(reason)})`)
		return false
	end

	local granted = MathUtil.clamp(amount, 1, EconomyConfig.MAX_SINGLE_AWARD)
	if granted ~= amount then
		warn(`[DataService] Clamped a {amount} coin award for {player.Name} to {granted}`)
	end

	data.Coins += granted
	syncCoins(player, data)
	Remotes.fireClient(RemoteNames.CoinsChanged, player, data.Coins, granted, reason or "Reward")
	return true
end

function DataService.trySpendCoins(player: Player, amount: number): boolean
	local data = DataService.getData(player)
	if not data then
		return false
	end

	if not Validators.isPositiveInteger(amount) or data.Coins < amount then
		return false
	end

	data.Coins -= amount
	syncCoins(player, data)
	Remotes.fireClient(RemoteNames.CoinsChanged, player, data.Coins, -amount, "Spend")
	return true
end

-- Records a kill and pays for it. This is the only kill payout in the game; see
-- the reward-ownership note at the top of the file.
function DataService.recordKill(player: Player, isHeadshot: boolean)
	local data = DataService.getData(player)
	if not data then
		return
	end

	data.Stats.Kills += 1
	setStat(player, "Kills", data.Stats.Kills)
	player:SetAttribute("SessionKills", (player:GetAttribute("SessionKills") or 0) + 1)

	local reward = EconomyConfig.REWARDS.KILL
	if isHeadshot then
		reward += EconomyConfig.REWARDS.HEADSHOT_BONUS
	end

	DataService.addCoins(player, reward, if isHeadshot then "Headshot" else "Kill")
end

function DataService.recordDeath(player: Player)
	local data = DataService.getData(player)
	if data then
		data.Stats.Deaths += 1
	end
end

-- Stats only — match payouts belong to MatchService.
function DataService.recordMatchResult(player: Player, won: boolean, killsThisMatch: number)
	local data = DataService.getData(player)
	if not data then
		return
	end

	data.Stats.MatchesPlayed += 1
	if won then
		data.Stats.Wins += 1
	end

	local kills = if MathUtil.isFinite(killsThisMatch) then math.max(math.floor(killsThisMatch), 0) else 0
	if kills > data.Stats.BestKillsInMatch then
		data.Stats.BestKillsInMatch = kills
	end
end

function DataService.grantSkin(player: Player, skinId: string): boolean
	local data = DataService.getData(player)
	if not data or not SkinCatalog.exists(skinId) or data.OwnedSkins[skinId] then
		return false
	end

	data.OwnedSkins[skinId] = true
	return true
end

function DataService.setEquippedSkin(player: Player, weaponId: string, skinId: string): boolean
	local data = DataService.getData(player)
	if not data or not WeaponConfig.exists(weaponId) or not SkinCatalog.exists(skinId) then
		return false
	end

	-- The default skin is free and always equippable; everything else has to be
	-- owned, or the equip remote becomes a way to wear unpurchased cosmetics.
	if skinId ~= SkinCatalog.DEFAULT_SKIN_ID and not data.OwnedSkins[skinId] then
		return false
	end

	data.EquippedSkins[weaponId] = skinId
	return true
end

function DataService.getEquippedSkin(player: Player, weaponId: string): string
	local data = DataService.getData(player)
	local equipped = data and data.EquippedSkins[weaponId]
	return equipped or SkinCatalog.DEFAULT_SKIN_ID
end

-- The client-facing view of a profile. Sub-tables are cloned so a caller (or a
-- remote handler) cannot mutate live profile data through the snapshot.
function DataService.getSnapshot(player: Player)
	local data = DataService.getData(player)
	if not data then
		return nil
	end

	return {
		coins = data.Coins,
		stats = TableUtil.deepClone(data.Stats),
		ownedSkins = TableUtil.deepClone(data.OwnedSkins),
		equippedSkins = TableUtil.deepClone(data.EquippedSkins),
		spin = {
			nextFreeAt = data.Spin.LastFreeSpinAt + SpinConfig.FREE_SPIN_INTERVAL,
			pity = data.Spin.Pity,
		},
	}
end

function DataService.pushSnapshot(player: Player)
	local snapshot = DataService.getSnapshot(player)
	if snapshot then
		Remotes.fireClient(RemoteNames.ProfileLoaded, player, snapshot)
	end
end

function DataService.loadPlayer(player: Player)
	if profiles[player] or loading[player] then
		return
	end

	if not profileStore then
		profileStore = ProfileService.GetProfileStore(GameConfig.PROFILE_STORE_NAME, PROFILE_TEMPLATE)
	end

	loading[player] = true
	local ok, profile = pcall(function()
		return profileStore:LoadProfileAsync(KEY_PREFIX .. player.UserId, "ForceLoad")
	end)
	loading[player] = nil

	if not ok then
		warn(`[DataService] LoadProfileAsync failed for {player.Name}: {tostring(profile)}`)
		profile = nil
	end

	if not profile then
		player:Kick(LOAD_FAILED_MESSAGE)
		return
	end

	profile:AddUserId(player.UserId) -- GDPR: ties the key to a deletable user id
	profile:Reconcile()

	profile:ListenToRelease(function()
		profiles[player] = nil
		player:SetAttribute("Loaded", false)
		player:Kick(RELEASED_MESSAGE)
	end)

	-- LoadProfileAsync yields, so the player may already have left. Releasing
	-- here is what stops the session lock outliving the session.
	if not player:IsDescendantOf(Players) then
		profile:Release()
		return
	end

	profiles[player] = profile
	buildLeaderstats(player, profile.Data)
	player:SetAttribute("SessionKills", 0)
	syncCoins(player, profile.Data)
	player:SetAttribute("Loaded", true)

	DataService.pushSnapshot(player)
	DataService.ProfileLoadedSignal:Fire(player)
end

function DataService.releasePlayer(player: Player)
	local profile = profiles[player]
	profiles[player] = nil
	loading[player] = nil

	if profile then
		player:SetAttribute("Loaded", false)
		profile:Release()
	end
end

function DataService.releaseAll()
	local active = {}
	for player in profiles do
		table.insert(active, player)
	end

	for _, player in active do
		DataService.releasePlayer(player)
	end
end

return DataService
