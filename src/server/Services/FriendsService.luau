--!nonstrict
--[[
	FriendsService.luau
	Answers GetFriendsRequest with the player's friends who are in this server:

		{inServer: {FriendEntry}}
		FriendEntry = {userId: number, name: string, displayName: string}

	Those three fields are the whole payload. Friends who are online somewhere
	else are not the server's to report: the engine's Player:GetFriendsOnlineAsync
	answers for the LocalPlayer only, so FriendsScreen asks it directly. The
	server used to build that list from the IsOnline field of
	Players:GetFriendsAsync, which the engine no longer fills in. It was always
	empty, and cost up to four pages of web calls every time the panel opened.

	IsFriendsWith yields and fails under load or when the service is down. Each
	call is wrapped, and a failure degrades to a shorter list rather than an
	error crossing the wire: a friends panel is not worth breaking a session
	over.

	Results are cached per player for GameConfig.FRIENDS_CACHE_SECONDS. Combined
	with the remote's rate limit, that bounds how much friend traffic one player
	can generate no matter how often the panel is opened.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local GameConfig = require(Shared.Config.GameConfig)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local Trove = require(Shared.Util.Trove)
local Validators = require(script.Parent.Parent.Net.Validators)

local FriendsService = {}
FriendsService.Priority = 6

-- Rate limit from the network contract.
local FRIENDS_RATE, FRIENDS_WINDOW = 2, 10

local cache: { [Player]: { expiresAt: number, payload: any } } = {}
local serviceTrove = Trove.new()

local function entryFor(userId: number, name: string, displayName: string)
	return {
		userId = userId,
		name = name,
		displayName = if displayName ~= "" then displayName else name,
	}
end

--[[
	Friends who are in this server right now. IsFriendsWith is per-pair and can
	yield, so the roster is re-checked as it is walked: a player who left during
	an earlier lookup must not end up in the list.
]]
local function friendsInServer(player: Player): { any }
	local entries = {}

	for _, other in Players:GetPlayers() do
		if other == player then
			continue
		end

		local ok, isFriend = pcall(function()
			return player:IsFriendsWith(other.UserId)
		end)

		if ok and isFriend and other.Parent and player.Parent then
			table.insert(entries, entryFor(other.UserId, other.Name, other.DisplayName))
		end
	end

	return entries
end

local function buildPayload(player: Player)
	return { inServer = friendsInServer(player) }
end

local function onGetFriendsRequest(player: Player)
	-- os.clock is monotonic; a wall clock that stepped backwards would freeze a
	-- cache entry until it caught up again.
	local cached = cache[player]
	if cached and os.clock() < cached.expiresAt then
		return cached.payload
	end

	local payload = buildPayload(player)

	-- The player may have left during the web calls above; caching for a session
	-- that no longer exists just leaks until the removal hook fires, so skip it.
	if player.Parent then
		cache[player] = { expiresAt = os.clock() + GameConfig.FRIENDS_CACHE_SECONDS, payload = payload }
	end

	return payload
end

local function validateGetFriends(_player: Player, ...): (boolean, string?)
	-- GetFriendsRequest carries no payload; anything sent with it is a probe.
	return Validators.checkTypes(table.pack(...), {})
end

--[[
	Drop a cached list, or every cached list when `player` is omitted. Anything
	that changes who is in this server should call this: the in-server half of
	the payload is wrong the moment the roster moves, and the cache would
	otherwise hide that for up to GameConfig.FRIENDS_CACHE_SECONDS.
]]
function FriendsService.clearCache(player: Player?)
	if player then
		cache[player] = nil
	else
		table.clear(cache)
	end
end

function FriendsService.onPlayerRemoving(_player: Player)
	FriendsService.clearCache()
end

function FriendsService.init()
	Remotes.register({
		Name = RemoteNames.GetFriendsRequest,
		Type = "Function",
		Handler = onGetFriendsRequest,
		Validator = validateGetFriends,
		RateLimit = FRIENDS_RATE,
		WindowSeconds = FRIENDS_WINDOW,
	})

	serviceTrove:Connect(Players.PlayerRemoving, FriendsService.onPlayerRemoving)
	serviceTrove:Connect(Players.PlayerAdded, function()
		FriendsService.clearCache()
	end)
end

return FriendsService
