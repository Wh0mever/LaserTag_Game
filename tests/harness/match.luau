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

-- What the match paid each player and what it wrote to their record.
local paid: { [any]: { amount: number, reason: string } } = {}
local results: { [any]: { won: boolean, kills: number } } = {}

Env.provide("src/server/Services/DataService", {
	addCoins = function(player, amount, reason)
		paid[player] = { amount = amount, reason = reason }
		return true
	end,
	recordMatchResult = function(player, won, kills)
		results[player] = { won = won, kills = kills }
	end,
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
local EconomyConfig = Env.load("src/shared/Config/EconomyConfig")
local GameConfig = Env.load("src/shared/Config/GameConfig")
local R = EconomyConfig.REWARDS

local InProgress = MatchStateMachine.States.InProgress

-- A running 2v1 with three players placed the way the runtime places them.
local function runningMatch()
	table.clear(alive)
	table.clear(respawning)
	table.clear(spawned)
	table.clear(protectedFor)
	table.clear(fired)

	table.clear(paid)
	table.clear(results)

	local runtime = MatchRuntime.new("Dust")
	local a1, b1, a2 = fakePlayer("a1"), fakePlayer("b1"), fakePlayer("a2")
	runtime.state.phase = InProgress
	-- A match that has just begun: the clock is what a payout is scaled by.
	runtime.state.timeLeft = runtime.state.config.matchDuration
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
-- A side that empties
--
-- The players left used to stand in an empty arena for thirty seconds with no
-- word, and then be told they had won a match the scoreboard said they were
-- losing.
--------------------------------------------------------------------------------

heading("A side empties")

local function noticesTo(player): { string }
	local lines = {}
	for _, event in fired do
		if event.name == "Notice" and event.player == player then
			table.insert(lines, event.args[1])
		end
	end
	return lines
end

do
	local runtime, a1, b1, a2 = runningMatch()
	runtime.state.timeLeft = 600
	runtime.state.scores.A, runtime.state.scores.B = 3, 9
	runtime:_syncRoster()
	table.clear(fired)

	runtime:onPlayerRemoving(b1)

	local told = noticesTo(a1)
	check(#told == 1, `a player left alone is told the other side is empty ({#told} notices)`)
	check(
		told[1] ~= nil and string.find(told[1], "30", 1, true) ~= nil,
		`and how long they have to wait (got "{tostring(told[1])}")`
	)
	check(#noticesTo(a2) == 1, "and so is their teammate")
	check(#noticesTo(b1) == 0, "and the one who left is not")

	-- A stray departure while the grace runs does not repeat the announcement.
	table.clear(fired)
	runtime:onPlayerRemoving(a2)
	check(#noticesTo(a1) == 0, "a second departure does not say it again")

	table.clear(fired)
	runtime:tick(31)
	check(runtime.state.phase == MatchStateMachine.States.Results, "the grace running out ends the match")

	local payload = nil
	for _, event in fired do
		if event.args[2] == MatchStateMachine.States.Results then
			payload = event.args[3]
			break
		end
	end
	check(payload ~= nil and payload.winnerTeam == "A", "the players left win")
	check(
		payload ~= nil and payload.reason == "forfeit",
		`and the results say the opponents left (got {tostring(payload and payload.reason)})`
	)
end

do
	local runtime, a1, b1 = runningMatch()
	runtime.state.timeLeft = 600
	runtime:_syncRoster()
	runtime:onPlayerRemoving(b1)
	table.clear(fired)

	local late = fakePlayer("late2")
	late:SetAttribute("InMatch", "")
	runtime:_joinMidMatch({ late })
	local told = noticesTo(a1)
	check(#told == 1, `somebody joining the empty side tells the waiting player the match goes on ({#told} notices)`)
end

do
	local runtime = runningMatch()
	runtime.state.timeLeft = 600
	runtime.state.scores.A = 1
	runtime:_syncRoster()
	table.clear(fired)
	runtime:tick(1)
	runtime:_endMatch({ winnerTeam = "A", scores = { A = 10, B = 4 } })
	local payload = nil
	for _, event in fired do
		if event.args[2] == MatchStateMachine.States.Results then
			payload = event.args[3]
		end
	end
	check(payload ~= nil and payload.reason == nil, "a match played out carries no forfeit reason")
end

--------------------------------------------------------------------------------
-- Who is let in late, and what they are paid
--
-- The payout depended on the scoreline alone: a player seated five seconds
-- before the end, or left alone thirty seconds after an alt account
-- disconnected, was paid the full win.
--------------------------------------------------------------------------------

heading("Late joiners and the payout")

do
	local runtime = runningMatch()
	local late = fakePlayer("toolate")
	late:SetAttribute("InMatch", "")
	runtime.state.timeLeft = GameConfig.LATE_JOIN_CUTOFF_SECONDS - 1
	runtime:_joinMidMatch({ late })
	check(runtime.roster[late] == nil, "nobody is seated in the last minute of a match")
	check((late:GetAttribute("InMatch") or "") == "", "and they are not marked as playing it")

	local early = fakePlayer("justintime")
	early:SetAttribute("InMatch", "")
	runtime.state.timeLeft = GameConfig.LATE_JOIN_CUTOFF_SECONDS + 1
	runtime:_joinMidMatch({ early })
	check(runtime.roster[early] ~= nil, "but a minute and a second before the end is still worth joining")
end

do
	local runtime, a1, b1, a2 = runningMatch()
	runtime.state.timeLeft = 500
	local late = fakePlayer("late")
	late:SetAttribute("InMatch", "")
	runtime:_joinMidMatch({ late })
	check(runtime.roster[late] == "B", "the joiner takes the smaller side")

	-- The score limit ends the match five seconds after they arrive.
	runtime.state.timeLeft = 495
	runtime:_endMatch({ winnerTeam = "B", scores = { A = 3, B = 9 }, elapsed = 105 })
	check(
		paid[late] ~= nil and paid[late].amount == R.MATCH_PARTICIPATION,
		`five seconds in the match is paid as taking part (got {tostring(paid[late] and paid[late].amount)})`
	)
	check(results[late] ~= nil and results[late].won == false, "and is not written down as a win")
	check(
		paid[b1] ~= nil and paid[b1].amount == R.MATCH_WIN,
		`while the player who played all of it is paid the win (got {tostring(paid[b1] and paid[b1].amount)})`
	)
	check(results[b1] ~= nil and results[b1].won == true, "and it is a win on their record")
	check(paid[a1] ~= nil and paid[a1].amount == R.MATCH_PARTICIPATION, "the losing side is paid for taking part")
	check(paid[a2] ~= nil and paid[a2].amount == R.MATCH_PARTICIPATION, "all of it")
end

do
	local runtime, a1 = runningMatch()
	-- The other side left after 10 seconds and the survivors waited out the grace.
	runtime:_endMatch({
		winnerTeam = "A",
		scores = { A = 0, B = 0 },
		reason = "forfeit",
		elapsed = 10 + GameConfig.EMPTY_TEAM_GRACE,
	})
	check(
		paid[a1] ~= nil and paid[a1].amount == R.MATCH_PARTICIPATION,
		`a win by the opponent leaving straight away pays the ordinary award (got {tostring(
			paid[a1] and paid[a1].amount
		)})`
	)
	check(results[a1] ~= nil and results[a1].won == false, "and is not a win on their record")
end

do
	local runtime, a1 = runningMatch()
	runtime:_endMatch({
		winnerTeam = "A",
		scores = { A = 4, B = 9 },
		reason = "forfeit",
		elapsed = GameConfig.MATCH_DURATION / 2,
	})
	local expected = R.MATCH_PARTICIPATION + math.floor((R.MATCH_WIN - R.MATCH_PARTICIPATION) / 2)
	check(
		paid[a1] ~= nil and paid[a1].amount == expected,
		`a forfeit halfway through pays half way between the two (got {tostring(paid[a1] and paid[a1].amount)})`
	)
	check(results[a1] ~= nil and results[a1].won == true, "and does count as a win")
end

--------------------------------------------------------------------------------
-- Lopsided teams are evened out as players come back from a death
--
-- A match that lost three players from one side stayed lopsided for the rest of
-- the game; only a new arrival was ever put on the smaller side.
--------------------------------------------------------------------------------

heading("Rebalancing")

-- A running match with `a` players on A and `b` on B; returns the runtime and
-- the two lists.
local function lopsided(a: number, b: number)
	local runtime = runningMatch()
	table.clear(runtime.roster)
	table.clear(runtime.kills)
	local onA, onB = {}, {}
	for index = 1, a do
		local player = fakePlayer(`A{index}`)
		runtime.roster[player] = "A"
		runtime.kills[player] = 0
		runtime:_place(player, "A")
		table.insert(onA, player)
	end
	for index = 1, b do
		local player = fakePlayer(`B{index}`)
		runtime.roster[player] = "B"
		runtime.kills[player] = 0
		runtime:_place(player, "B")
		table.insert(onB, player)
	end
	runtime:_syncRoster()
	table.clear(fired)
	return runtime, onA, onB
end

do
	local runtime, onA = lopsided(3, 1)
	check(type(runtime.rebalanceOnRespawn) == "function", "the runtime can rebalance a player coming back from a death")
	if type(runtime.rebalanceOnRespawn) == "function" then
		local mover = onA[2]
		local moved = runtime:rebalanceOnRespawn(mover)
		check(moved == "B", `a player from the side that is two ahead is moved to the other (got {tostring(moved)})`)
		check(runtime.roster[mover] == "B", "the roster follows")
		check(mover:GetAttribute("TeamId") == "B", "and so does their team, which is what the respawn reads")
		local a, b = runtime:_countTeams()
		check(a == 2 and b == 2, `so the match is level ({a} v {b})`)

		local told = noticesTo(mover)
		check(
			#told == 1
				and string.find(told[1], "Браво", 1, true) ~= nil
				and string.find(told[1], "баланса", 1, true) ~= nil,
			`and told which side and why (got "{tostring(told[1])}")`
		)

		-- Now level, so the next player to die stays where they are.
		local again = runtime:rebalanceOnRespawn(onA[3])
		check(again == nil, "once level nobody else is moved")
	end
end

do
	local runtime, _, onB = lopsided(3, 1)
	if type(runtime.rebalanceOnRespawn) == "function" then
		check(runtime:rebalanceOnRespawn(onB[1]) == nil, "the smaller side's player is never the one moved")
	end
end

do
	local runtime, onA = lopsided(2, 1)
	if type(runtime.rebalanceOnRespawn) == "function" then
		check(runtime:rebalanceOnRespawn(onA[1]) == nil, "one player apart is as level as an odd number allows")
	end
end

do
	-- The other side is EMPTY: that is a forfeit running its grace, not
	-- something to fix by dragging a teammate over.
	local runtime, onA = lopsided(2, 0)
	if type(runtime.rebalanceOnRespawn) == "function" then
		check(runtime:rebalanceOnRespawn(onA[1]) == nil, "an empty opposing side is left to the forfeit rule")
	end
end

do
	local runtime, onA = lopsided(4, 1)
	if type(runtime.rebalanceOnRespawn) == "function" then
		runtime.state.phase = MatchStateMachine.States.Results
		check(runtime:rebalanceOnRespawn(onA[1]) == nil, "nobody is moved once the match is over")
		runtime.state.phase = InProgress
		check(
			runtime:rebalanceOnRespawn(fakePlayer("stranger")) == nil,
			"and a player who is not in the match is ignored"
		)
	end
end

--------------------------------------------------------------------------------
-- Paid kills
--------------------------------------------------------------------------------

heading("Paid kills")

do
	local runtime, a1, b1 = runningMatch()
	local limit = EconomyConfig.MAX_PAID_KILLS_PER_PAIR
	local firstUnpaid = nil
	for kill = 1, limit + 3 do
		local paidKill = runtime:registerKill(b1, a1, "Rifle", false)
		if not paidKill and not firstUnpaid then
			firstUnpaid = kill
		end
	end
	check(firstUnpaid == limit + 1, `the same victim stops paying after {limit} kills (first unpaid: {firstUnpaid})`)
	check(runtime.state.scores.A == limit + 3, "but every kill still scores for the team")

	local other = runtime:registerKill(a1, b1, "Rifle", false)
	check(other == true, "the victim killing back is paid")
	check(runtime:registerKill(b1, b1, "Rifle", false) == false, "a suicide pays nothing")
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
