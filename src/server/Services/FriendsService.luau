--!nonstrict
--[[
	FriendsService.luau
	Answers GetFriendsRequest with the player's friends split two ways:

		{inServer: {FriendEntry}, online: {FriendEntry}}
		FriendEntry = {userId: number, name: string, displayName: string}

	Those three fields are the whole payload. Players:GetFriendsAsync hands back
	more than that per friend, and none of the rest belongs on a client that only
	needs to render a list and offer a join.

	Every call here is a web call: GetFriendsAsync and IsFriendsWith both yield
	and both fail under load or when the service is down. Each is wrapped, and a
	failure degrades to a shorter list rather than an error crossing the wire —
	a friends panel is not worth breaking a session over.

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

-- A panel nobody scrolls past does not justify paging the whole friends list of
-- an account with thousands of them, so the walk stops at either bound.
local MAX_ONLINE = 50
local MAX_PAGES = 4

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

--[[
	Friends who are online somewhere other than this server. `exclude` holds the
	user ids already reported as in-server (plus the player's own) so nobody is
	listed twice.
]]
local function friendsOnline(player: Player, exclude: { [number]: boolean }): { any }
	local entries = {}

	local ok, pages = pcall(function()
		return Players:GetFriendsAsync(player.UserId)
	end)

	if not ok or not pages then
		warn(`[FriendsService] GetFriendsAsync failed for {player.Name}: {tostring(pages)}`)
		return entries
	end

	for _ = 1, MAX_PAGES do
		local readOk, items = pcall(function()
			return pages:GetCurrentPage()
		end)

		if not readOk or type(items) ~= "table" then
			break
		end

		for _, item in items do
			if #entries >= MAX_ONLINE then
				return entries
			end

			local userId = tonumber(item.Id)
			if item.IsOnline and userId and not exclude[userId] then
				exclude[userId] = true
				local name = tostring(item.Username or userId)
				table.insert(entries, entryFor(userId, name, tostring(item.DisplayName or name)))
			end
		end

		if pages.IsFinished then
			break
		end

		local advanced = pcall(function()
			pages:AdvanceToNextPageAsync()
		end)
		if not advanced then
			break
		end
	end

	return entries
end

local function buildPayload(player: Player)
	local inServer = friendsInServer(player)

	local exclude = { [player.UserId] = true }
	for _, entry in inServer do
		exclude[entry.userId] = true
	end

	return { inServer = inServer, online = friendsOnline(player, exclude) }
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
