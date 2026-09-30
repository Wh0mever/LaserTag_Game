--!nonstrict
--[[
	tests/harness/queue.luau
	What the portal sign says about the match behind it.

	A player standing on a pad while a match runs is seated into it as a late
	joiner, except in the last minute, when there is no point (they could not play
	long enough to share in the result). A sign that still said the match was
	going would leave them standing on the pad wondering why nothing happens.

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
	fireClient = function() end,
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
