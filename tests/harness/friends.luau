--!nonstrict
--[[
	tests/harness/friends.luau
	Runs the real friends panel against a stand-in server and a stand-in friends
	list.

	The "online, but somewhere else" list was always empty: it was filled from
	the IsOnline field of Players:GetFriendsAsync, which the engine no longer
	sets. The list now comes from the local player's GetFriendsOnlineAsync (the
	engine allows that call on the LocalPlayer only), so what is checked here is
	the panel's own filtering: who is listed, who is not, and what it says when
	the lookup fails.

	Run:  lune run tests/harness/friends
]]

local Env = require("./env")
local luneTask = require("@lune/task")

Env.enableClientRuntime()

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

--------------------------------------------------------------------------------
-- Stand-ins
--------------------------------------------------------------------------------

local Players = Env.service("Players")
local localPlayer = Players.LocalPlayer

-- What GetFriendsRequest answers: friends in this server, as the server sees
-- them. The server no longer says anything about friends elsewhere.
local serverPayload: any = {
	inServer = { { userId = 11, name = "ann", displayName = "Ann" } },
}

local remote = Env.service("ReplicatedStorage").Remotes:WaitForChild("GetFriendsRequest")
remote.InvokeServer = function()
	return serverPayload
end

-- Player:GetFriendsOnlineAsync as the documentation describes its result.
local onlineCalls = 0
local onlineResult: any = {}
localPlayer.GetFriendsOnlineAsync = function(_self, maxFriends)
	onlineCalls += 1
	assert(type(maxFriends) == "number" and maxFriends <= 200, "maxFriends must be a number of at most 200")
	if onlineResult == "error" then
		error("HTTP 429 (too many requests)", 2)
	end
	return onlineResult
end

-- Somebody who joined after the server last answered: not in the payload, but
-- in the room, so they are not "elsewhere" either.
Players.GetPlayers = function()
	return { { UserId = 44, Name = "dan", DisplayName = "Dan" } }
end

local UIController = Env.load("src/client/UI/UIController")
local FriendsScreen = Env.load("src/client/UI/Screens/FriendsScreen")

UIController.init()
FriendsScreen.init()

local function section(key: string)
	local gui = UIController.getScreen("FriendsMenu")
	for _, descendant in gui:GetDescendants() do
		if descendant.Name == key and descendant:IsA("Frame") and descendant:FindFirstChild("Header") then
			return descendant
		end
	end
	return nil
end

local function rowTitles(key: string): { string }
	local titles = {}
	local holder = section(key)
	local list = holder and holder:FindFirstChild("List")
	if not list then
		return titles
	end
	for _, row in list:GetChildren() do
		if row.Name ~= "ListRow" or not row.Visible then
			continue
		end
		-- The first text on a row is its title; the rest is subtitle and value.
		for _, descendant in row:GetDescendants() do
			if descendant:IsA("TextLabel") and descendant.Text ~= "" and descendant.Name == "Title" then
				table.insert(titles, descendant.Text)
				break
			end
		end
	end
	table.sort(titles)
	return titles
end

local function headerText(key: string): string
	local holder = section(key)
	return holder and holder.Header.Text or ""
end

local function emptyText(key: string): string
	local holder = section(key)
	return holder and holder.Empty.Text or ""
end

--------------------------------------------------------------------------------
-- Online, but not here
--------------------------------------------------------------------------------

heading("Friends online elsewhere")

onlineResult = {
	-- In this server according to the server: listed above, not again here.
	{ VisitorId = 11, UserName = "ann", DisplayName = "Ann", IsOnline = true, PlaceId = 1, GameId = "job-a" },
	{ VisitorId = 22, UserName = "bob", DisplayName = "Bob", IsOnline = true, PlaceId = 2, GameId = "job-b" },
	-- Offline entries are ignored whatever else they carry.
	{ VisitorId = 33, UserName = "cat", DisplayName = "Cat", IsOnline = false },
	-- In the room right now, though the cached server answer does not know it.
	{ VisitorId = 44, UserName = "dan", DisplayName = "Dan", IsOnline = true, PlaceId = 1, GameId = "job-a" },
	-- The player themself is never their own friend.
	{ VisitorId = localPlayer.UserId, UserName = "me", DisplayName = "Me", IsOnline = true },
	-- No display name: the username stands in.
	{ VisitorId = 55, UserName = "eve", IsOnline = true, PlaceId = 3, GameId = "job-c" },
	-- Malformed entries must not take the panel down.
	{ UserName = "ghost", IsOnline = true },
	"not a table",
}

UIController.openMenu("Friends")
Env.advance(0)

check(onlineCalls == 1, `opening the panel asks the engine who is online once (got {onlineCalls})`)
local inServer = rowTitles("inServer")
check(
	#inServer == 1 and inServer[1] == "Ann",
	`the in-server list comes from the server (got {table.concat(inServer, ",")})`
)

local elsewhere = rowTitles("online")
check(
	#elsewhere == 2 and elsewhere[1] == "Bob" and elsewhere[2] == "eve",
	`only online friends who are not in the room are listed (got {table.concat(elsewhere, ",")})`
)
check(headerText("online"):find("%(2%)") ~= nil, `and the heading counts them (got "{headerText("online")}")`)
check(
	headerText("online"):find("В СЕТИ, НО В ДРУГОМ МЕСТЕ", 1, true) ~= nil,
	"under the wording the panel already had"
)

UIController.closeMenu("Friends")

--------------------------------------------------------------------------------
-- The lookup fails
--
-- Stays honest: "nobody is online" and "could not find out" are different
-- statements, and the first would be a lie about a friend list that exists.
--------------------------------------------------------------------------------

heading("When the online lookup fails")

-- The panel refuses a second refresh inside its own cooldown, measured on the
-- real clock, so this has to wait it out for real.
luneTask.wait(6.5)

onlineResult = "error"
UIController.openMenu("Friends")
Env.advance(0)

check(onlineCalls == 2, "the lookup is attempted again on the next open")
local stillHere = rowTitles("inServer")
check(#stillHere == 1 and stillHere[1] == "Ann", "a failed online lookup does not cost the in-server list")
check(#rowTitles("online") == 0, "and nobody is listed as online")
check(
	emptyText("online") ~= "Сейчас никого из друзей нет в сети",
	`the panel does not claim nobody is online when it could not ask (got "{emptyText("online")}")`
)
check(emptyText("online") ~= "", "and says something about it")

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
	error(`{failed} friends check(s) failed`, 0)
end
print("  All friends checks passed.")
