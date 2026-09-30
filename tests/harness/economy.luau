--!nonstrict
--[[
	tests/harness/economy.luau
	Runs the real economy services (analytics, profiles, leaderboard, friends)
	against stand-ins that are as strict as the engine.

	The Lune mock accepts anything, which is how AnalyticsService shipped with
	LogProgressionEvent's arguments in the wrong order: the call threw inside a
	pcall, the service switched itself off for the rest of the server's life, and
	nothing anywhere said so. So the analytics stand-in here checks every
	argument's type and range the way the documented signatures do, and a check
	asks whether the service is still switched on afterwards.

	Run:  lune run tests/harness/economy
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

local passed, failed = 0, 0
local failures: { string } = {}

local function check(ok: boolean, message: string)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, message)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

local Enum = roblox.Enum

--------------------------------------------------------------------------------
-- Real players
--
-- DataService parents a leaderstats folder to the player, and only an Instance
-- can be a parent, so a table will not do. Lune's Player and Players classes
-- carry no behaviour of their own; the members these services use are added
-- here, once, and recorded so a check can read them back.
--------------------------------------------------------------------------------

local players = roblox.Instance.new("Players")
players.Name = "Players"
Env.setService("Players", players)

roblox.implementMethod("Players", "GetPlayers", function(self)
	local roster = {}
	for _, child in self:GetChildren() do
		if child.ClassName == "Player" then
			table.insert(roster, child)
		end
	end
	return roster
end)

local userNames: { [number]: string } = {}
roblox.implementMethod("Players", "GetNameFromUserIdAsync", function(_self, userId)
	local name = userNames[userId]
	if not name then
		error(`HTTP 404 (no user {userId})`, 2)
	end
	return name
end)

for _, eventName in { "PlayerAdded", "PlayerRemoving" } do
	roblox.implementProperty("Players", eventName, function(self)
		return Env.instanceEvent(self, eventName)
	end)
end

local kicks: { [any]: string } = {}
roblox.implementMethod("Player", "Kick", function(self, message)
	kicks[self] = message or ""
end)

local friendships: { [number]: { [number]: boolean } } = {}
roblox.implementMethod("Player", "IsFriendsWith", function(self, userId)
	local mine = friendships[self.UserId]
	return mine ~= nil and mine[userId] == true
end)

local nextUserId = 5000
local function fakePlayer(name: string)
	nextUserId += 1
	local player = roblox.Instance.new("Player")
	player.Name = name
	player.DisplayName = name
	player.UserId = nextUserId
	player.Parent = players
	userNames[nextUserId] = name
	return player
end

-- The way a player leaves: the event fires while they are still in the game.
local function leave(player)
	players.PlayerRemoving:Fire(player)
	player.Parent = nil
end

--------------------------------------------------------------------------------
-- A strict AnalyticsService
--
-- Signatures are the documented ones (Roblox creator-docs, AnalyticsService):
--   LogCustomEvent(player, eventName, value?, customFields?)
--   LogEconomyEvent(player, flowType, currencyType, amount, endingBalance,
--                   transactionType, itemSku?, customFields?)
--   LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName?, customFields?)
--   LogProgressionEvent(player, progressionPathName, status, level?, levelName?, customFields?)
-- customFields only honours the keys of Enum.AnalyticsCustomFieldKeys.
--------------------------------------------------------------------------------

local logged: { { method: string, args: { any } } } = {}

local function argError(method: string, position: number, expected: string, got: any)
	error(`{method}: argument {position} must be {expected}, got {type(got)} ({tostring(got)})`, 3)
end

local function expectString(method: string, position: number, value: any, optional: boolean?)
	if value == nil and optional then
		return
	end
	if type(value) ~= "string" or (not optional and value == "") then
		argError(method, position, "a non-empty string", value)
	end
end

local function expectNumber(method: string, position: number, value: any, optional: boolean?)
	if value == nil and optional then
		return
	end
	if type(value) ~= "number" or value ~= value then
		argError(method, position, "a number", value)
	end
end

local function expectEnum(method: string, position: number, value: any, enumType: any)
	if type(value) ~= "userdata" or value.EnumType ~= enumType then
		argError(method, position, `an {tostring(enumType)} item`, value)
	end
end

local function expectPlayer(method: string, value: any)
	if type(value) ~= "userdata" or value.ClassName ~= "Player" then
		argError(method, 1, "a Player", value)
	end
end

local function expectFields(method: string, position: number, fields: any)
	if fields == nil then
		return
	end
	if type(fields) ~= "table" then
		argError(method, position, "a dictionary", fields)
	end
	for key, value in fields do
		local isKey = type(key) == "string" and Enum.AnalyticsCustomFieldKeys[key] ~= nil
		if not isKey then
			error(`{method}: customFields key {tostring(key)} is not an AnalyticsCustomFieldKeys name`, 3)
		end
		if type(value) ~= "string" then
			error(`{method}: customFields.{key} must be a string, got {type(value)}`, 3)
		end
	end
end

local function record(method: string, ...)
	table.insert(logged, { method = method, args = table.pack(...) })
end

local strictAnalytics = Env.service("AnalyticsService")

function strictAnalytics.LogCustomEvent(_self, player, eventName, value, customFields)
	expectPlayer("LogCustomEvent", player)
	expectString("LogCustomEvent", 2, eventName)
	expectNumber("LogCustomEvent", 3, value, true)
	expectFields("LogCustomEvent", 4, customFields)
	record("LogCustomEvent", player, eventName, value, customFields)
end

function strictAnalytics.LogEconomyEvent(
	_self,
	player,
	flowType,
	currencyType,
	amount,
	endingBalance,
	transactionType,
	itemSku,
	customFields
)
	expectPlayer("LogEconomyEvent", player)
	expectEnum("LogEconomyEvent", 2, flowType, Enum.AnalyticsEconomyFlowType)
	expectString("LogEconomyEvent", 3, currencyType)
	expectNumber("LogEconomyEvent", 4, amount)
	expectNumber("LogEconomyEvent", 5, endingBalance)
	if amount <= 0 or endingBalance < 0 then
		error("LogEconomyEvent: amount must be positive and endingBalance non-negative", 2)
	end
	expectString("LogEconomyEvent", 6, transactionType)
	expectString("LogEconomyEvent", 7, itemSku, true)
	expectFields("LogEconomyEvent", 8, customFields)
	record("LogEconomyEvent", player, flowType, currencyType, amount, endingBalance, transactionType, itemSku)
end

function strictAnalytics.LogFunnelStepEvent(_self, player, funnelName, funnelSessionId, step, stepName, customFields)
	expectPlayer("LogFunnelStepEvent", player)
	expectString("LogFunnelStepEvent", 2, funnelName)
	expectString("LogFunnelStepEvent", 3, funnelSessionId)
	expectNumber("LogFunnelStepEvent", 4, step)
	expectString("LogFunnelStepEvent", 5, stepName, true)
	expectFields("LogFunnelStepEvent", 6, customFields)
	record("LogFunnelStepEvent", player, funnelName, funnelSessionId, step, stepName)
end

function strictAnalytics.LogProgressionEvent(_self, player, pathName, status, level, levelName, customFields)
	expectPlayer("LogProgressionEvent", player)
	expectString("LogProgressionEvent", 2, pathName)
	if pathName:find("[,\"'\n\r]") then
		error("LogProgressionEvent: progressionPathName may not contain , \" ' or a newline", 2)
	end
	expectEnum("LogProgressionEvent", 3, status, Enum.AnalyticsProgressionType)
	expectNumber("LogProgressionEvent", 4, level, true)
	expectString("LogProgressionEvent", 5, levelName, true)
	expectFields("LogProgressionEvent", 6, customFields)
	record("LogProgressionEvent", player, pathName, status, level, levelName, customFields)
end

local function loggedCalls(method: string)
	local out = {}
	for _, entry in logged do
		if entry.method == method then
			table.insert(out, entry)
		end
	end
	return out
end

--------------------------------------------------------------------------------
-- Analytics
--------------------------------------------------------------------------------

heading("Analytics")

local AnalyticsService = Env.load("src/server/Services/AnalyticsService")

do
	local player = fakePlayer("analyst")
	AnalyticsService.matchQueued(player, "Dust")
	AnalyticsService.matchStarted(player, "Dust")
	AnalyticsService.killScored(player)
	AnalyticsService.killScored(player)
	AnalyticsService.matchFinished(player, true, 54, 31)

	local progression = loggedCalls("LogProgressionEvent")
	check(#progression == 1, `a finished match reports exactly one progression event (got {#progression})`)
	check(
		AnalyticsService.isAvailable(),
		"the progression event is accepted by the engine's signature, so analytics stays switched on"
	)

	local entry = progression[1]
	if entry then
		local args = entry.args
		check(args[2] == "Dust", "the progression path is the map")
		check(args[3] == Enum.AnalyticsProgressionType.Complete, "a win is reported as Complete")
		check(args[4] == 1, `the level is the number 1 (got {tostring(args[4])})`)
		check(type(args[5]) == "string", `the level has a name (got {type(args[5])})`)
	end
end

do
	local player = fakePlayer("loser")
	AnalyticsService.matchQueued(player, "Dust")
	AnalyticsService.matchStarted(player, "Dust")
	AnalyticsService.matchFinished(player, false, 20, 54)
	local last = loggedCalls("LogProgressionEvent")
	local entry = last[#last]
	check(entry ~= nil and entry.args[3] == Enum.AnalyticsProgressionType.Fail, "a loss is reported as Fail")
end

-- The other three call shapes go through the same strict stand-in, so one
-- wrong argument anywhere shows up as the service having switched itself off.
do
	local player = fakePlayer("spender")
	AnalyticsService.coinsEarned(player, 25, 125, "Kill")
	AnalyticsService.coinsSpent(player, 100, 25, "Skin_Neon")
	AnalyticsService.spinResolved(player, 3, "Coins", 250)
	check(#loggedCalls("LogEconomyEvent") == 2, "coins earned and spent are both reported")
	check(#loggedCalls("LogCustomEvent") == 1, "a spin is reported")
	check(AnalyticsService.isAvailable(), "economy and spin events are accepted, so analytics stays switched on")

	local spin = loggedCalls("LogCustomEvent")[1]
	check(spin ~= nil and spin.args[4] ~= nil, "a spin carries its breakdown fields")
end

--------------------------------------------------------------------------------
-- Profiles
--
-- ProfileService is third-party and talks to DataStores; what is under test is
-- DataService's own handling of the lifecycle around it. The stand-in profile
-- keeps ProfileService's one important timing: Release() returns at once and
-- the release listeners fire later, once the final save has finished.
--------------------------------------------------------------------------------

heading("Profiles")

local function deepCopy(value)
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, entry in value do
		copy[key] = deepCopy(entry)
	end
	return copy
end

local pendingReleases: { any } = {}
local loadedProfiles: { [string]: any } = {}
local onLoad: any = nil
local failLoads = false

local function endSession(profile)
	if not profile.active then
		return
	end
	profile.active = false
	for _, listener in profile.listeners do
		listener()
	end
end

local function finishReleases()
	local queue = pendingReleases
	pendingReleases = {}
	for _, profile in queue do
		endSession(profile)
	end
end

Env.provide("src/server/Vendor/ProfileService", {
	GetProfileStore = function(_name, template)
		return {
			LoadProfileAsync = function(_self, key)
				if failLoads then
					error("HTTP 429 (too many requests)", 2)
				end
				local profile = { Data = deepCopy(template), active = true, listeners = {} }
				function profile:AddUserId() end
				function profile:Reconcile() end
				function profile:IsActive()
					return self.active
				end
				function profile:ListenToRelease(listener)
					table.insert(self.listeners, listener)
				end
				function profile:Release()
					if self.active then
						table.insert(pendingReleases, self)
					end
				end
				loadedProfiles[key] = profile
				if onLoad then
					onLoad(key)
				end
				return profile
			end,
		}
	end,
})

local remoteHandlers: { [string]: any } = {}

Env.provide("src/server/Net/Remotes", {
	register = function(config)
		remoteHandlers[config.Name] = config
	end,
	fireClient = function() end,
})

local DataService = Env.load("src/server/Services/DataService")
DataService.init()

local function profileOf(player)
	return loadedProfiles["Player_" .. player.UserId]
end

do
	local player = fakePlayer("shutdown")
	DataService.loadPlayer(player)
	check(DataService.isLoaded(player), "a player's profile loads")

	DataService.releaseAll()
	finishReleases()
	check(not DataService.isLoaded(player), "shutdown releases the profile")
	check(
		kicks[player] == nil,
		`shutdown does not tell the player their data was opened elsewhere (got "{tostring(kicks[player])}")`
	)
end

do
	local player = fakePlayer("leaver")
	DataService.loadPlayer(player)
	leave(player)
	DataService.releasePlayer(player)
	finishReleases()
	check(kicks[player] == nil, "a player who leaves is not kicked by their own release")
	check(player:GetAttribute("Loaded") == false, "and is marked as no longer loaded")
end

do
	local player = fakePlayer("stolen")
	DataService.loadPlayer(player)
	check(DataService.isLoaded(player), "the session-lock case starts loaded")

	-- Another server force-loaded this profile: nothing here asked for the
	-- release, and continuing to play would edit data that is no longer ours.
	endSession(profileOf(player))
	check(not DataService.isLoaded(player), "a profile taken by another server stops being writable here")
	check(player:GetAttribute("Loaded") == false, "and the player is marked as not loaded")
	check(
		type(kicks[player]) == "string" and kicks[player]:find("другом сервере") ~= nil,
		`and they are told why they were removed (got "{tostring(kicks[player])}")`
	)
end

do
	local player = fakePlayer("quitter")
	onLoad = function(_key)
		-- The player disconnects while the profile is still being fetched.
		player.Parent = nil
	end
	DataService.loadPlayer(player)
	onLoad = nil
	finishReleases()
	check(not DataService.isLoaded(player), "a player who left during the load never becomes loaded")
	check(kicks[player] == nil, "and the release of their unused profile does not kick anyone")
	check(profileOf(player) ~= nil and not profileOf(player).active, "and the session lock is not left behind")
end

--------------------------------------------------------------------------------
-- Leaderboard
--
-- An OrderedDataStore stand-in that can be told to fail, and counts what it is
-- asked to do: the request budget is part of what is being checked.
--------------------------------------------------------------------------------

heading("Leaderboard")

local orderedStore = {
	data = {} :: { [string]: number },
	sets = 0,
	reads = 0,
	failWrites = 0,
	failReads = false,
}

function orderedStore:SetAsync(key: string, value: number)
	if self.failWrites > 0 then
		self.failWrites -= 1
		error("HTTP 429 (too many requests)", 2)
	end
	self.sets += 1
	self.data[key] = value
end

function orderedStore:GetSortedAsync(_ascending: boolean, count: number)
	self.reads += 1
	if self.failReads then
		error("HTTP 503 (service unavailable)", 2)
	end

	local items = {}
	for key, value in self.data do
		table.insert(items, { key = key, value = value })
	end
	table.sort(items, function(a, b)
		return a.value > b.value
	end)
	while #items > count do
		table.remove(items)
	end
	return {
		IsFinished = true,
		GetCurrentPage = function()
			return items
		end,
	}
end

Env.service("DataStoreService").GetOrderedDataStore = function()
	return orderedStore
end

local board = roblox.Instance.new("SurfaceGui")
board.Name = "TopKills"
local boardRoot = roblox.Instance.new("Frame")
boardRoot.Name = "Root"
boardRoot.Parent = board
local boardContent = roblox.Instance.new("Frame")
boardContent.Name = "Content"
boardContent.Parent = boardRoot

Env.provide("src/server/Services/WorldService", {
	getBoard = function(boardId)
		return if boardId == "TopKills" then board else nil
	end,
})

local LeaderboardService = Env.load("src/server/Services/LeaderboardService")
LeaderboardService.init()

local function loadedPlayer(name: string, kills: number)
	local player = fakePlayer(name)
	DataService.loadPlayer(player)
	DataService.getData(player).Stats.Kills = kills
	return player
end

local function scoreOf(player)
	return orderedStore.data[tostring(player.UserId)]
end

-- The score a player reaches after the last periodic write is still theirs
-- when they go; it must be on the board without waiting for a cycle they will
-- not be here for.
do
	local player = loadedPlayer("closer", 7)
	leave(player)
	DataService.releasePlayer(player)
	check(scoreOf(player) == 7, `a leaving player's kills are written at once (got {tostring(scoreOf(player))})`)
end

do
	local player = loadedPlayer("steady", 4)
	LeaderboardService.flush(player)
	local before = orderedStore.sets
	leave(player)
	DataService.releasePlayer(player)
	check(scoreOf(player) == 4, "a player whose score was already written keeps it")
	check(orderedStore.sets == before, "and leaving with nothing new costs no write request")

	local again = loadedPlayer("idle", 0)
	leave(again)
	DataService.releasePlayer(again)
	check(scoreOf(again) == nil, "a player with no kills never gets an entry")
end

do
	local player = loadedPlayer("unlucky", 9)
	orderedStore.failWrites = 2
	leave(player)
	DataService.releasePlayer(player)
	check(
		not DataService.isLoaded(player),
		"a throttled write does not hold up the leave path: the profile is already released"
	)
	check(scoreOf(player) == nil, "the write is retried in the background, not yet done")
	Env.advance(10)
	check(scoreOf(player) == 9, `and lands once the store recovers (got {tostring(scoreOf(player))})`)
end

do
	local player = loadedPlayer("abandoned", 5)
	orderedStore.failWrites = 100
	leave(player)
	DataService.releasePlayer(player)
	Env.advance(30)
	orderedStore.failWrites = 0
	check(#Env.spawnErrors == 0, "a write that never succeeds ends quietly, not with a dead thread")
end

-- Shutdown: BindToClose flushes everyone still online, then releases them. The
-- release must not write the same scores a second time.
do
	local player = loadedPlayer("lastcall", 12)
	LeaderboardService.flushAll()
	check(scoreOf(player) == 12, "shutdown writes every player still online")
	local before = orderedStore.sets
	DataService.releaseAll()
	finishReleases()
	check(orderedStore.sets == before, "and the release that follows does not write them again")
end

local function rowText(rank: number, column: string): string?
	local row = boardContent:FindFirstChild(`Row{rank}`)
	local label = row and row:FindFirstChild(column)
	return label and label.Text
end

local EMPTY_TEXT = "Пока нет результатов"

-- The board: rendered from the sorted read, and left alone when a read fails.
orderedStore.data = { ["5901"] = 30, ["5902"] = 12 }
userNames[5901] = "alice"
userNames[5902] = "bob"

local runner = Env.spawn(LeaderboardService.start)
Env.advance(8)
check(rowText(1, "PlayerName") == "alice", `the board shows the leader (got {tostring(rowText(1, "PlayerName"))})`)
check(rowText(2, "Kills") == "12", "and each row's kills")

orderedStore.failReads = true
orderedStore.data["5903"] = 50
userNames[5903] = "carol"
Env.advance(140)
check(orderedStore.reads > 1, "the board asks again on the next cycle")
check(
	rowText(1, "PlayerName") == "alice",
	`a failed read keeps the last good rows on the board (got {tostring(rowText(1, "PlayerName"))})`
)
check(rowText(1, "PlayerName") ~= EMPTY_TEXT, "and does not claim there are no results")

local readsBefore = orderedStore.reads
orderedStore.failReads = false
Env.advance(45)
check(orderedStore.reads > readsBefore, "after a failed read the retry comes well before the next full cycle")
check(
	rowText(1, "PlayerName") == "carol",
	`and the board catches up once the read works (got {tostring(rowText(1, "PlayerName"))})`
)

orderedStore.data = {}
Env.advance(130)
check(
	rowText(1, "PlayerName") == EMPTY_TEXT,
	`a successful read of an empty board does say there are no results (got {tostring(rowText(1, "PlayerName"))})`
)
check(runner ~= nil, "the board loop is running")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} economy check(s) failed`, 0)
end
print("  All economy checks passed.")
