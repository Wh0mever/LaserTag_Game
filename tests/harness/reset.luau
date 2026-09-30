--!nonstrict
--[[
	tests/harness/reset.luau
	The escape menu's Reset Character button, which the game turns off during a
	match.

	A player losing a duel could press it: health goes to zero, the other player
	gets no kill, and the loser comes back at full strength three seconds later.
	The server credits such a death to whoever hurt the player last, but the
	better answer is not to offer the button while it can only be used to escape.

	The core script that draws the button registers its callback a moment after
	the player joins, and SetCore raises until it has. So the request is retried,
	and the retry has to follow the player: one who entered and left a match while
	it was still failing must end up with the state they are in NOW.

	Run:  lune run tests/harness/reset
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

local ResetButton = Env.load("src/client/ResetButton")
local player = Env.service("Players").LocalPlayer

-- A StarterGui whose core script becomes ready after `failures` attempts.
local function fakeGui(failuresLeft: number)
	local gui = { calls = {}, enabled = nil, failuresLeft = failuresLeft }
	function gui.SetCore(self, name: string, value: any)
		table.insert(self.calls, { name = name, value = value })
		if self.failuresLeft > 0 then
			self.failuresLeft -= 1
			error("ResetButtonCallback has not been registered by the CoreScripts yet", 0)
		end
		if name == "ResetButtonCallback" then
			self.enabled = value
		end
	end
	return gui
end

--------------------------------------------------------------------------------
-- Follows the match
--------------------------------------------------------------------------------

heading("In the hub and in a match")

player:SetAttribute("InMatch", "")
local gui = fakeGui(0)
check(type(ResetButton.watch) == "function", "there is a watcher to start")
local stop = ResetButton.watch(gui)

check(gui.enabled == true, "in the hub the reset button is left on")

player:SetAttribute("InMatch", "Dust")
check(gui.enabled == false, "entering a match turns it off")

player:SetAttribute("InMatch", "")
check(gui.enabled == true, "and leaving turns it back on")

player:SetAttribute("InMatch", "Dust")
player:SetAttribute("InMatch", "Mirage")
check(gui.enabled == false, "moving between matches leaves it off")
player:SetAttribute("InMatch", "")

if type(stop) == "function" then
	stop()
end

--------------------------------------------------------------------------------
-- The core script is late
--------------------------------------------------------------------------------

heading("Before the core script is ready")

do
	player:SetAttribute("InMatch", "Dust")
	local late = fakeGui(3)
	local stopLate = ResetButton.watch(late)
	check(late.enabled == nil, "the first attempts fail while the core script has not registered")

	Env.advance(1)
	Env.advance(1)
	Env.advance(1)
	Env.advance(1)
	check(late.enabled == false, "and it is retried until it takes, without anyone asking again")

	if type(stopLate) == "function" then
		stopLate()
	end
end

do
	-- Entered a match while it was failing, and left again before it took: the
	-- state applied must be the one they are in now.
	player:SetAttribute("InMatch", "")
	local flappy = fakeGui(2)
	local stopFlappy = ResetButton.watch(flappy)
	player:SetAttribute("InMatch", "Dust")
	player:SetAttribute("InMatch", "")
	Env.advance(6)
	check(flappy.enabled == true, "a player who left the match ends up with the button on, not the stale state")

	local last = flappy.calls[#flappy.calls]
	check(last ~= nil and last.value == true, "and the last thing asked for is what they are now")

	if type(stopFlappy) == "function" then
		stopFlappy()
	end
end

do
	-- A core script that never comes: the retry gives up instead of spinning.
	local never = fakeGui(math.huge)
	local stopNever = ResetButton.watch(never)
	Env.advance(600)
	check(#never.calls < 100, `a core script that never answers is not asked forever ({#never.calls} attempts)`)
	if type(stopNever) == "function" then
		stopNever()
	end
end

heading("Result")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} reset check(s) failed`, 0)
end
print("  All reset checks passed.")
