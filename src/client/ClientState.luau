--!nonstrict
--[[
	ClientState.luau
	The single client-side store. Every server -> client remote lands here once,
	mutates the matching field and then fires a Signal; screens and controllers
	subscribe to the Signals and never touch remotes directly. That keeps one
	copy of "what the server told us" instead of five screens each holding a
	slightly different snapshot.

	This module is deliberately NOT loaded by the Loader (it lives directly under
	src/client, not under Controllers/ or UI/). Requirers call `ClientState.init()`
	themselves; it is idempotent, synchronous and safe to call from any module's
	init().

	Signal payloads:
	  CoinsChanged   (coins: number, delta: number, reason: string)
	  ProfileChanged (snapshot: table)
	  MatchChanged   (match: table)            -- also fires on every MatchTick
	  AmmoChanged    (ammo: table)
	  SlotChanged    (slot: number, weaponId: string)
	  KillFeed       (entry: table)            -- {killerName, killerTeam, victimName,
	                                           --  victimTeam, weaponId, isHeadshot, at}
	  Died           (killerUserId: number?, respawnSeconds: number)
	  Respawned      ()
	  HitConfirmed   (payload: table)          -- {victimUserId, damage, isHeadshot, hitPos, killed}
	  DamageTaken    (payload: table)          -- {attackerUserId, damage, fromPosition}
	  QueueChanged   (mapId, count, needed, countdown)   -- mirrors the remote args
	  ShotFired      (shooterUserId, weaponId, muzzlePos, hitPos, color) -- mirrors the remote args
	  AttributeChanged (name: string, value: any)        -- for the replicated player attributes
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ClientState = {}

-- Long enough to cover a slow first replication, short enough that a genuinely
-- missing remote surfaces as a warning instead of a silent hang (SE-11).
local REMOTE_WAIT_TIMEOUT = 10
local TRACKED_ATTRIBUTES =
	{ "Coins", "SessionKills", "InMatch", "TeamId", "CurrentWeapon", "SpawnProtectedUntil", "Loaded" }

local player = Players.LocalPlayer
local trove = Trove.new()
local remoteCache: { [string]: Instance } = {}
local initialised = false
local bound = false

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

ClientState.coins = 0
ClientState.stats = {}
ClientState.ownedSkins = {}
ClientState.equippedSkins = {}
ClientState.spin = { nextFreeAt = 0, pity = 0 }

ClientState.match = { mapId = nil, phase = "Idle", timeLeft = 0, scores = { A = 0, B = 0 }, data = {} }
ClientState.queue = { mapId = nil, count = 0, needed = 0, countdown = nil }

ClientState.ammo = { weaponId = Constants.SLOTS[Constants.DEFAULT_SLOT], mag = 0, magSize = 0, reloading = false }
ClientState.currentSlot = Constants.DEFAULT_SLOT
ClientState.isDead = false
ClientState.isTouch = false

--------------------------------------------------------------------------------
-- Signals
--------------------------------------------------------------------------------

ClientState.CoinsChanged = Signal.new()
ClientState.ProfileChanged = Signal.new()
ClientState.MatchChanged = Signal.new()
ClientState.AmmoChanged = Signal.new()
ClientState.SlotChanged = Signal.new()
ClientState.KillFeed = Signal.new()
ClientState.Died = Signal.new()
ClientState.Respawned = Signal.new()
ClientState.HitConfirmed = Signal.new()
ClientState.DamageTaken = Signal.new()
ClientState.QueueChanged = Signal.new()
ClientState.ShotFired = Signal.new()
ClientState.AttributeChanged = Signal.new()

--------------------------------------------------------------------------------
-- Remote access
--------------------------------------------------------------------------------

--[[
	Cached remote lookup. Yields on the first call for a given name (bounded by
	REMOTE_WAIT_TIMEOUT), so never call this from a module body or from an
	init() — use it inside start() or an event handler.

	Returns nil only when the server failed to create the remote, which is a
	broken build rather than a runtime condition.
]]
function ClientState.getRemote(name: string): Instance?
	local cached = remoteCache[name]
	if cached then
		return cached
	end

	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = ReplicatedStorage:WaitForChild("Remotes", REMOTE_WAIT_TIMEOUT)
	end
	if not folder then
		warn("[ClientState] ReplicatedStorage.Remotes never replicated")
		return nil
	end

	local remote = folder:FindFirstChild(name) or folder:WaitForChild(name, REMOTE_WAIT_TIMEOUT)
	if not remote then
		warn(`[ClientState] remote "{name}" is missing from ReplicatedStorage.Remotes`)
		return nil
	end

	remoteCache[name] = remote
	return remote
end

local function connectRemote(name: string, handler: (...any) -> ())
	local remote = ClientState.getRemote(name)
	if not remote then
		return
	end
	if not (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
		warn(`[ClientState] remote "{name}" is a {remote.ClassName}, expected an event`)
		return
	end
	trove:Connect((remote :: any).OnClientEvent, handler)
end

--------------------------------------------------------------------------------
-- Attribute mirroring
--------------------------------------------------------------------------------

function ClientState.getTeamId(): string
	return player:GetAttribute("TeamId") or "LOBBY"
end

--[[
	Map id while playing, "" in the hub. Mirrors the InMatch attribute.
]]
function ClientState.getMapId(): string
	return player:GetAttribute("InMatch") or ""
end

function ClientState.isInMatch(): boolean
	return ClientState.getMapId() ~= ""
end

function ClientState.isLoaded(): boolean
	return player:GetAttribute("Loaded") == true
end

function ClientState.getSessionKills(): number
	return player:GetAttribute("SessionKills") or 0
end

function ClientState.isSpawnProtected(): boolean
	local protectedUntil = player:GetAttribute("SpawnProtectedUntil")
	return type(protectedUntil) == "number" and workspace:GetServerTimeNow() < protectedUntil
end

local function applyWeaponAttribute()
	local weaponId = player:GetAttribute("CurrentWeapon")
	if not WeaponConfig.exists(weaponId) then
		return
	end

	local slot = WeaponConfig.get(weaponId).slot
	if slot == ClientState.currentSlot then
		return
	end

	ClientState.currentSlot = slot
	ClientState.SlotChanged:Fire(slot, weaponId)
end

--------------------------------------------------------------------------------
-- Remote handlers
--------------------------------------------------------------------------------

local function onProfileLoaded(snapshot)
	if type(snapshot) ~= "table" then
		return
	end

	ClientState.coins = snapshot.coins or 0
	ClientState.stats = snapshot.stats or {}
	ClientState.ownedSkins = snapshot.ownedSkins or {}
	ClientState.equippedSkins = snapshot.equippedSkins or {}
	ClientState.spin = snapshot.spin or { nextFreeAt = 0, pity = 0 }

	ClientState.ProfileChanged:Fire(snapshot)
end

local function onCoinsChanged(newCoins: number, delta: number, reason: string)
	if type(newCoins) ~= "number" then
		return
	end

	ClientState.coins = newCoins
	ClientState.CoinsChanged:Fire(newCoins, delta or 0, reason or "")
end

local function onMatchStateChanged(mapId: string, phase: string, data)
	local match = ClientState.match
	match.mapId = mapId
	match.phase = phase or "Idle"
	match.data = type(data) == "table" and data or {}

	if type(match.data.timeLeft) == "number" then
		match.timeLeft = match.data.timeLeft
	end
	if type(match.data.scores) == "table" then
		match.scores = { A = match.data.scores.A or 0, B = match.data.scores.B or 0 }
	end

	ClientState.MatchChanged:Fire(match)
end

local function onMatchTick(mapId: string, timeLeft: number, scoreA: number, scoreB: number)
	local match = ClientState.match
	match.mapId = mapId
	match.timeLeft = timeLeft or 0
	match.scores = { A = scoreA or 0, B = scoreB or 0 }

	ClientState.MatchChanged:Fire(match)
end

local function onQueueUpdate(mapId: string, count: number, needed: number, countdown: number?)
	ClientState.queue = { mapId = mapId, count = count or 0, needed = needed or 0, countdown = countdown }
	ClientState.QueueChanged:Fire(mapId, count or 0, needed or 0, countdown)
end

local function onAmmoSync(weaponId: string, mag: number, magSize: number, reloading: boolean, ackSeq: number?)
	ClientState.ammo = {
		weaponId = weaponId,
		mag = mag or 0,
		magSize = magSize or 0,
		reloading = reloading == true,
		-- The last shot the server's count already accounts for; WeaponClient
		-- uses it to tell a correction apart from a sync that predates shots
		-- still travelling to the server.
		ackSeq = if type(ackSeq) == "number" then ackSeq else 0,
	}
	ClientState.AmmoChanged:Fire(ClientState.ammo)
end

local function onKillFeed(killerName, killerTeam, victimName, victimTeam, weaponId, isHeadshot)
	ClientState.KillFeed:Fire({
		killerName = killerName,
		killerTeam = killerTeam,
		victimName = victimName,
		victimTeam = victimTeam,
		weaponId = weaponId,
		isHeadshot = isHeadshot == true,
		at = os.clock(),
	})
end

local function onDeathInfo(killerUserId: number?, respawnSeconds: number)
	ClientState.isDead = true
	ClientState.Died:Fire(killerUserId, respawnSeconds or Constants.RESPAWN_SECONDS)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--[[
	Binds every server -> client remote. Yields on the first WaitForChild, so it
	is spawned from init() rather than called inline.
]]
function ClientState.start()
	if bound then
		return
	end
	bound = true

	connectRemote(RemoteNames.ProfileLoaded, onProfileLoaded)
	connectRemote(RemoteNames.CoinsChanged, onCoinsChanged)
	connectRemote(RemoteNames.MatchStateChanged, onMatchStateChanged)
	connectRemote(RemoteNames.MatchTick, onMatchTick)
	connectRemote(RemoteNames.QueueUpdate, onQueueUpdate)
	connectRemote(RemoteNames.AmmoSync, onAmmoSync)
	connectRemote(RemoteNames.KillFeedEvent, onKillFeed)
	connectRemote(RemoteNames.DeathInfo, onDeathInfo)

	connectRemote(RemoteNames.HitConfirmed, function(victimUserId, damage, isHeadshot, hitPos, killed)
		ClientState.HitConfirmed:Fire({
			victimUserId = victimUserId,
			damage = damage or 0,
			isHeadshot = isHeadshot == true,
			hitPos = hitPos,
			killed = killed == true,
		})
	end)

	connectRemote(RemoteNames.DamageTaken, function(attackerUserId, damage, fromPosition)
		ClientState.DamageTaken:Fire({
			attackerUserId = attackerUserId,
			damage = damage or 0,
			fromPosition = fromPosition,
		})
	end)

	connectRemote(RemoteNames.ShotFired, function(shooterUserId, weaponId, muzzlePos, hitPos, color)
		ClientState.ShotFired:Fire(shooterUserId, weaponId, muzzlePos, hitPos, color)
	end)
end

--[[
	Idempotent, synchronous wiring. Attribute observers and the character hook go
	up immediately; the yielding remote binding is deferred into its own task so
	callers can safely call this from their own init().
]]
function ClientState.init()
	if initialised then
		return
	end
	initialised = true

	ClientState.isTouch = UserInputService.TouchEnabled
	ClientState.coins = player:GetAttribute("Coins") or 0

	for _, name in TRACKED_ATTRIBUTES do
		trove:Connect(player:GetAttributeChangedSignal(name), function()
			local value = player:GetAttribute(name)
			if name == "Coins" and type(value) == "number" then
				ClientState.coins = value
			elseif name == "CurrentWeapon" then
				applyWeaponAttribute()
			end
			ClientState.AttributeChanged:Fire(name, value)
		end)
	end
	applyWeaponAttribute()

	-- The server owns respawning (CharacterAutoLoads is off), so a new character
	-- arriving is the authoritative "you are alive again" signal.
	trove:Connect(player.CharacterAdded, function()
		if ClientState.isDead then
			ClientState.isDead = false
		end
		ClientState.Respawned:Fire()
	end)

	task.spawn(ClientState.start)
end

return ClientState
