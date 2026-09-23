--!nonstrict
--[[
	tests/harness/match.luau
	Runs the real MatchRuntime against stand-in services.

	The match loop is the part of the server with the most rules and, until
	this, no execution outside a live server: the state machine had unit tests,
	but the runtime that turns its effects into spawns, payouts and broadcasts
	had none. Every service it calls (spawning, teams, profiles, the network) is
	replaced by a recorder here, so what is under test is the runtime's own
	decisions: who may switch sides and when, what the Results payload carries,
	what a late joiner is told.

	Run:  lune run tests/harness/match
]]

local Env = require("./env")

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

local alive: { [any]: boolean } = {}
local respawning: { [any]: boolean } = {}
local spawned: { { player: any, teamId: string } } = {}
local protectedFor: { [any]: number } = {}
local fired: { { name: string, player: any, args: { any } } } = {}

Env.provide("src/server/Services/PlayerService", {
	spawnInMatch = function(player, _mapId, teamId)
		table.insert(spawned, { player = player, teamId = teamId })
		alive[player] = true
	end,
	spawnInHub = function() end,
	extendSpawnProtection = function(player, seconds)
		protectedFor[player] = seconds
	end,
	isRespawning = function(player)
		return respawning[player] == true
	end,
	scheduleRespawn = function(player)
		respawning[player] = true
	end,
})

Env.provide("src/server/Services/TeamService", {
	assignToTeam = function(player, teamId)
		player:SetAttribute("TeamId", teamId)
	end,
	moveToLobby = function(player)
		player:SetAttribute("TeamId", "LOBBY")
	end,
	getTeamId = function(player)
		return player:GetAttribute("TeamId")
	end,
	balanceAssign = function(players)
		local out = {}
		for index, player in players do
			out[player] = if index % 2 == 1 then "A" else "B"
		end
		return out
	end,
	smallestTeamIn = function(roster)
		local a, b = 0, 0
		for _, teamId in roster do
			if teamId == "A" then
				a += 1
			elseif teamId == "B" then
				b += 1
			end
		end
		return if b < a then "B" else "A"
	end,
})

Env.provide("src/server/Services/DataService", {
	addCoins = function()
		return true
	end,
	recordMatchResult = function() end,
})

local noop = setmetatable({}, {
	__index = function()
		return function() end
	end,
})
Env.provide("src/server/Services/AnalyticsService", noop)
Env.provide("src/server/Services/LeaderboardService", noop)

Env.provide("src/server/Net/Remotes", {
	fireClient = function(name, player, ...)
		table.insert(fired, { name = name, player = player, args = table.pack(...) })
	end,
})

Env.provide("src/server/Net/Validators", {
	isAlive = function(player)
		return alive[player] == true
	end,
})

local Players = Env.service("Players")

local nextUserId = 1000
local function fakePlayer(name: string)
	nextUserId += 1
	local attributes = {}
	return {
		Name = name,
		DisplayName = name,
		UserId = nextUserId,
		GetAttribute = function(_self, key)
			return attributes[key]
		end,
		SetAttribute = function(_self, key, value)
			attributes[key] = value
		end,
		IsDescendantOf = function(_self, ancestor)
			return ancestor == Players
		end,
	}
end

local MatchRuntime = Env.load("src/server/Match/MatchRuntime")
local MatchStateMachine = Env.load("src/server/Match/MatchStateMachine")
local SideAssignment = Env.load("src/server/Match/SideAssignment")
local Constants = Env.load("src/shared/Constants")

local InProgress = MatchStateMachine.States.InProgress

-- A running 2v1 with three players placed the way the runtime places them.
local function runningMatch()
	table.clear(alive)
	table.clear(respawning)
	table.clear(spawned)
	table.clear(protectedFor)
	table.clear(fired)

	local runtime = MatchRuntime.new("Dust")
	local a1, b1, a2 = fakePlayer("a1"), fakePlayer("b1"), fakePlayer("a2")
	runtime.state.phase = InProgress
	runtime.state.scoreLimit = 54
	for player, teamId in { [a1] = "A", [b1] = "B", [a2] = "A" } do
		runtime.roster[player] = teamId
		runtime.kills[player] = 0
		runtime:_place(player, teamId)
	end
	-- _place spawns on its own task; the harness runs spawned work inline up
	-- to its first wait, which is all spawning does here.
	return runtime, a1, b1, a2
end

--------------------------------------------------------------------------------
-- Changing sides
--
-- A switch respawns the player at full health in the new side's spawn room.
-- With no limits a client could call it mid-fight to escape any duel, over and
-- over, or with a second left to be paid as the winning side. It is the answer
-- to the question asked on entry, so it is only taken while that is open.
--------------------------------------------------------------------------------

heading("Changing sides")

do
	local runtime, a1 = runningMatch()
	check(
		protectedFor[a1] == Constants.SIDE_CHOICE_SECONDS,
		"a placed player is protected while the side question is up"
	)

	local moved, reason = runtime:switchSide(a1, "B")
	check(moved, `an alive player may even up a 2v1 while the question is open ({reason})`)
	check(a1:GetAttribute("TeamId") == "B", "and ends up on the side they asked for")

	moved, reason = runtime:switchSide(a1, "A")
	check(not moved and reason == SideAssignment.TOO_LATE, `only one switch per match (got {reason})`)
end

do
	local runtime, a1 = runningMatch()
	-- The question has closed: its deadline is in the past. (A runtime with no
	-- deadlines at all, as before this rule existed, gets an empty table so the
	-- check reports the missing rule instead of crashing on it.)
	runtime.sideDeadline = runtime.sideDeadline or {}
	runtime.sideDeadline[a1] = os.clock() - 0.1
	local moved, reason = runtime:switchSide(a1, "B")
	check(
		not moved and reason == SideAssignment.TOO_LATE,
		`a switch after the question has closed is refused (got {reason})`
	)
	check(a1:GetAttribute("TeamId") == "A", "and the player stays where they were")
end

do
	local runtime, a1 = runningMatch()
	alive[a1] = false
	respawning[a1] = true
	local spawnsBefore = #spawned
	local moved, reason = runtime:switchSide(a1, "B")
	check(not moved and reason == SideAssignment.NOT_ALIVE, `a dead player cannot switch (got {reason})`)
	check(#spawned == spawnsBefore, "and is not respawned a second time on top of the pending respawn")
end

do
	local runtime, a1 = runningMatch()
	runtime.state.phase = MatchStateMachine.States.Results
	local moved, reason = runtime:switchSide(a1, "B")
	check(not moved, `nobody changes sides once the match is over (got {reason})`)
end

--------------------------------------------------------------------------------
-- Late joiners are told the kill target
--------------------------------------------------------------------------------

heading("Joining a match in progress")

do
	local runtime = runningMatch()
	local late = fakePlayer("late")
	late:SetAttribute("InMatch", "")
	table.clear(fired)
	runtime:_joinMidMatch({ late })

	local payload = nil
	for _, event in fired do
		if event.player == late and event.args[2] == InProgress then
			payload = event.args[3]
		end
	end
	check(payload ~= nil, "a late joiner is sent the running match")
	check(
		payload ~= nil and payload.scoreLimit == 54,
		`and the kill target with it (got {tostring(payload and payload.scoreLimit)})`
	)
end

--------------------------------------------------------------------------------
-- The Results payload survives the network
--
-- The rewards table was keyed by numeric UserId, and a RemoteEvent does not
-- carry large numeric keys as numbers. Every player read "no coins" under a
-- match that paid them.
--------------------------------------------------------------------------------

heading("Match results")

do
	local runtime, a1, b1 = runningMatch()
	table.clear(fired)
	runtime:_endMatch({ winnerTeam = "A", scores = { A = 10, B = 4 } })

	local rewards = nil
	for _, event in fired do
		if event.args[2] == MatchStateMachine.States.Results then
			rewards = event.args[3].rewards
			break
		end
	end
	check(type(rewards) == "table", "the results carry the rewards")
	if type(rewards) == "table" then
		local numericKeys = 0
		for key in rewards do
			if type(key) ~= "string" then
				numericKeys += 1
			end
		end
		check(numericKeys == 0, `every rewards key is a string, which is what arrives ({numericKeys} are not)`)
		check(rewards[tostring(a1.UserId)] ~= nil, "a winner's reward is found by their UserId as text")
		check(rewards[tostring(b1.UserId)] ~= nil, "and so is a loser's")
	end
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} match check(s) failed`, 0)
end
print("  All match checks passed.")
