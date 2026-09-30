--!nonstrict
--[[
	tests/harness/sides.luau
	The side question, answered the way a child at a phone answers it: by tapping
	the same button again when it says no.

	Every tap is a request, and a burst of them is what the server's rate limit
	exists to drop. What the player is owed is a sentence saying why nothing
	happened and a button that rests for a moment, not a generic "try again" that
	invites the next tap.

	Run:  lune run tests/harness/sides
]]

local Env = require("./env")

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

Env.setDevice("phone")
Env.enableClientRuntime()

local ClientState = Env.load("src/client/ClientState")
local RemoteNames = Env.load("src/shared/RemoteNames")
local SideScreen = Env.load("src/client/UI/Screens/SideScreen")
local UIController = Env.load("src/client/UI/UIController")

local player = Env.service("Players").LocalPlayer

ClientState.init()
UIController.init()
SideScreen.init()

-- What the server answers the next InvokeServer with; nil is a request it
-- dropped without a word, which is what the rate limiter does.
local reply: any = nil
local requests = 0
local remote = ClientState.getRemote(RemoteNames.ChooseSideRequest)
remote.InvokeServer = function()
	requests += 1
	return reply
end

local function statusText(): string
	local panel = SideScreen.panel()
	for _, descendant in panel.content:GetDescendants() do
		if descendant.Name == "Status" and descendant:IsA("TextLabel") then
			return descendant.Text
		end
	end
	return ""
end

local function enterMatch()
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
end

local function press(teamId: string)
	SideScreen.buttons()[teamId].instance.Activated:Fire()
end

local function resting(): boolean
	return not SideScreen.buttons().A:isEnabled() and not SideScreen.buttons().B:isEnabled()
end

--------------------------------------------------------------------------------
-- A refusal
--------------------------------------------------------------------------------

heading("A refused side")

do
	enterMatch()
	check(SideScreen.isOpen(), "the question is open")
	reply = { ok = false, reason = "wouldUnbalance", counts = { A = 1, B = 1 } }
	press("B")

	check(requests == 1, "the press asked the server once")
	check(
		string.find(statusText(), "неравными", 1, true) ~= nil,
		`the reason is on screen (got "{statusText()}")`
	)
	check(resting(), "and the buttons rest so a second tap cannot be a second request")

	Env.advance(1.6)
	check(resting(), "still resting after a second and a half: a refusal needs a couple of seconds to be read")
	Env.advance(0.6)
	check(not resting(), "and pressable again after two seconds")
end

--------------------------------------------------------------------------------
-- A request the server dropped
--------------------------------------------------------------------------------

heading("A dropped request")

do
	enterMatch()
	requests = 0
	reply = nil
	press("A")

	check(requests == 1, "the press asked the server once")
	check(
		string.find(statusText(), "Не получилось", 1, true) == nil,
		`the generic retry text does not invite another tap (got "{statusText()}")`
	)
	check(
		string.find(statusText(), "Слишком", 1, true) ~= nil,
		`the player is told they were too quick (got "{statusText()}")`
	)
	check(resting(), "and the buttons rest instead of staying open for the next tap")

	Env.advance(2.1)
	check(not resting(), "they come back after two seconds")

	-- The way out is never taken away.
	local stay = SideScreen.stayButton()
	check(stay ~= nil and stay:isEnabled(), "ИГРАТЬ stays pressable throughout")
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
	error(`{failed} side check(s) failed`, 0)
end
print("  All side checks passed.")
