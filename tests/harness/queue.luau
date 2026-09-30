--!nonstrict
--[[
	tests/harness/queue.luau
	What the portal sign says about the match behind it.

	A player standing on a pad while a match runs is seated into it as a late
	joiner, except in the last minute, when there is no point (they could not play
	long enough to share in the result). A sign that still said the match was
	going would leave them standing on the pad wondering why nothing happens.

	The same fact goes to the client as the fifth argument of QueueUpdate, so the
	chip over the screen cannot say "В ОЧЕРЕДИ 1/2" under a sign that says the
	match is ending.

	Run:  lune run tests/harness/queue
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

Env.enableClientRuntime()

-- One pad with a sign built the way MapBuilder builds it: SurfaceGui > Root > Status.
local status = roblox.Instance.new("TextLabel")
status.Name = "Status"
local signRoot = roblox.Instance.new("Frame")
signRoot.Name = "Root"
status.Parent = signRoot

local pad = {
	mapId = "Dust",
	padPart = roblox.Instance.new("Part"),
	gui = signRoot.Parent,
}
-- FindFirstChild is all the service asks of the gui.
pad.gui = {
	FindFirstChild = function(_self, name: string)
		return if name == "Root" then signRoot else nil
	end,
}

local match = { phase = "InProgress", joinable = true, countdown = nil }

-- Every QueueUpdate the service sent, in order.
local updates: { { player: any, args: { any } } } = {}

Env.provide("src/server/Services/WorldService", {
	isBuilt = function()
		return true
	end,
	getPortalPads = function()
		return { pad }
	end,
})
Env.provide("src/server/Services/MatchService", {
	getPhase = function()
		return match.phase
	end,
	getCountdown = function()
		return match.countdown
	end,
	acceptsJoiners = function()
		return match.joinable
	end,
	onQueueChanged = function() end,
})
Env.provide("src/server/Net/Remotes", {
	fireClient = function(name, player, ...)
		if name == "QueueUpdate" then
			table.insert(updates, { player = player, args = table.pack(...) })
		end
	end,
})

local QueueService = Env.load("src/server/Services/QueueService")
QueueService.init()
Env.spawn(QueueService.start)

heading("The sign")

check(status.Text == "МАТЧ ИДЁТ", `a match that takes joiners reads as going (got "{status.Text}")`)

match.joinable = false
Env.advance(1)
check(
	status.Text == "МАТЧ ЗАВЕРШАЕТСЯ",
	`a match in its last minute says it is ending (got "{status.Text}")`
)

match.joinable = true
Env.advance(1)
check(status.Text == "МАТЧ ИДЁТ", `and goes back if the answer changes (got "{status.Text}")`)

match.phase = "Results"
match.joinable = false
Env.advance(1)
check(status.Text == "МАТЧ ЗАВЕРШАЕТСЯ", `the results screen reads as ending too (got "{status.Text}")`)

match.phase = "Countdown"
match.countdown = 7
Env.advance(1)
check(status.Text == "СТАРТ ЧЕРЕЗ 7", `a countdown still reads as one (got "{status.Text}")`)

heading("What the chip is told")

-- A player standing on the pad: a character with a live root part, the way
-- QueueService looks for one.
local Players = Env.service("Players")
local byCharacter: { [any]: any } = {}
local present: { any } = {}
local onPad: { any } = {}

local function padPlayer(name: string)
	local attributes: { [string]: any } = { Loaded = true, InMatch = "" }
	local humanoid = { Health = 100 }
	local root: any = {
		IsA = function(_self, className: string)
			return className == "BasePart"
		end,
	}
	local character: any = {
		FindFirstChild = function(_self, childName: string)
			return if childName == "HumanoidRootPart" then root else nil
		end,
		FindFirstChildOfClass = function(_self, className: string)
			return if className == "Humanoid" then humanoid else nil
		end,
	}
	root.Parent = character

	local player: any = {
		Name = name,
		Character = character,
		GetAttribute = function(_self, key: string)
			return attributes[key]
		end,
		IsDescendantOf = function(_self, ancestor: any)
			return ancestor == Players
		end,
	}
	byCharacter[character] = player
	table.insert(present, player)
	return player, root
end

Players.GetPlayers = function()
	return present
end
Players.GetPlayerFromCharacter = function(_self, character: any)
	return byCharacter[character]
end
Env.partBoundsHandler = function()
	local roots = {}
	for _, root in onPad do
		table.insert(roots, root)
	end
	return roots
end
pad.padPart.Parent = Env.workspace()

local function latest(player: any): { any }?
	for index = #updates, 1, -1 do
		if updates[index].player == player then
			return updates[index].args
		end
	end
	return nil
end

local function sentTo(player: any): number
	local n = 0
	for _, update in updates do
		if update.player == player then
			n += 1
		end
	end
	return n
end

do
	local ann, annRoot = padPlayer("ann")
	onPad = { annRoot }

	match.phase = "InProgress"
	match.joinable = false
	match.countdown = nil
	table.clear(updates)
	QueueService.poll()

	local args = latest(ann)
	check(args ~= nil, "a player on the pad is sent an update")
	check(
		args ~= nil and args[1] == "Dust" and args[2] == 1 and args[3] == 2 and args[4] == nil,
		"which still carries the map, the count, the number needed and no countdown"
	)
	check(
		args ~= nil and args[5] == true,
		`and says the match is closing when the sign does ({tostring(args and args[5])})`
	)

	-- Nothing else changed: the count, the countdown and the members are the
	-- same. The answer to "will I be seated" is the only thing that moved.
	match.joinable = true
	local before = sentTo(ann)
	QueueService.poll()
	check(sentTo(ann) == before + 1, "a change in the closing flag alone is sent")
	args = latest(ann)
	check(
		args ~= nil and args[5] == false,
		`and the flag is off when the match takes joiners ({tostring(args and args[5])})`
	)

	local settled = sentTo(ann)
	QueueService.poll()
	check(sentTo(ann) == settled, "while an unchanged state is not sent again")

	match.joinable = false
	QueueService.poll()
	args = latest(ann)
	check(args ~= nil and args[5] == true, "and it turns back on when the last minute begins")

	-- The sign says the match is ending during the results as well; so must the chip.
	match.phase = "Results"
	QueueService.poll()
	args = latest(ann)
	check(args ~= nil and args[5] == true, "the results screen counts as closing too, as it does on the sign")

	match.phase = "Idle"
	QueueService.poll()
	args = latest(ann)
	check(args ~= nil and args[5] == false, "and a match that has not started is not closing")

	match.phase = "Countdown"
	match.countdown = 7
	QueueService.poll()
	args = latest(ann)
	check(args ~= nil and args[4] == 7 and args[5] == false, "a countdown carries the flag off")

	-- Stepping off: told they are in no queue, and that nothing is closing.
	match.phase = "InProgress"
	match.countdown = nil
	onPad = {}
	QueueService.poll()
	args = latest(ann)
	check(
		args ~= nil and args[1] == "" and args[2] == 0 and args[3] == 2 and args[4] == nil and args[5] == false,
		"a player who stepped off is sent an empty queue, with the flag off"
	)
end

heading("The chip's words")

local ClientState = Env.load("src/client/ClientState")
local UIController = Env.load("src/client/UI/UIController")
local QueueScreen = Env.load("src/client/UI/Screens/QueueScreen")

check(QueueScreen.textFor("Dust", 1, 2, nil, false) == "DUST  ·  В ОЧЕРЕДИ 1/2", "one of two reads as a queue")
check(
	QueueScreen.textFor("Dust", 2, 2, nil, false) == "DUST  ·  МАТЧ СОБРАН",
	"two of two reads as assembled"
)
check(
	QueueScreen.textFor("Dust", 2, 2, 7, false) == "DUST  ·  СТАРТ ЧЕРЕЗ 7",
	"a countdown reads as a start"
)
check(
	QueueScreen.textFor("Dust", 1, 2, nil, nil) == "DUST  ·  В ОЧЕРЕДИ 1/2",
	"a client that is not told about closing reads as it always did"
)

check(
	QueueScreen.textFor("Dust", 1, 2, nil, true) == "DUST  ·  МАТЧ ЗАВЕРШАЕТСЯ",
	`a match that takes nobody new says it is ending, as the sign does (got "{tostring(
		QueueScreen.textFor("Dust", 1, 2, nil, true)
	)}")`
)
check(
	QueueScreen.textFor("Mirage", 3, 2, nil, true) == "MIRAGE  ·  МАТЧ ЗАВЕРШАЕТСЯ",
	"and not that the match is assembled, whatever the head count"
)
check(QueueScreen.textFor("Dust", 0, 2, nil, true) == nil, "with nobody on the pad there is still nothing to show")
check(QueueScreen.textFor("", 0, 2, nil, false) == nil, "and stepping off shows nothing")

-- The chip on screen follows what ClientState holds.
UIController.init()
QueueScreen.init()
local chip = QueueScreen.chip()
check(chip ~= nil, "the chip is built")
if chip then
	local text = chip:FindFirstChild("Text")
	local function show(queue: { [string]: any })
		ClientState.queue = queue
		ClientState.QueueChanged:Fire(queue.mapId, queue.count, queue.needed, queue.countdown, queue.closing)
	end

	show({ mapId = "Dust", count = 1, needed = 2, closing = false })
	check(chip.Visible and text.Text == "DUST  ·  В ОЧЕРЕДИ 1/2", `a queue shows on the chip ("{text.Text}")`)

	show({ mapId = "Dust", count = 1, needed = 2, closing = true })
	check(
		chip.Visible and text.Text == "DUST  ·  МАТЧ ЗАВЕРШАЕТСЯ",
		`and the closing flag changes it with the count untouched ("{text.Text}")`
	)

	show({ mapId = "", count = 0, needed = 2, closing = false })
	check(not chip.Visible, "stepping off hides it")
end

heading("Result")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} queue check(s) failed`, 0)
end
print("  All queue checks passed.")
