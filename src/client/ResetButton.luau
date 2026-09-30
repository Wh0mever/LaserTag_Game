--!nonstrict
--[[
	ResetButton.luau
	Keeps Roblox's own "Reset Character" option out of matches.

	It lives in the escape menu of every player and sets the character's health to
	zero. In a match that makes it a way out of a lost duel: no kill for the other
	player, no point for their team, no coins, and the loser is back at full
	health three seconds later. The server credits such a death to whoever hurt
	the player last (PlayerService.noteDamage), but a button that can only be used
	to escape is better not offered at all. In the hub it is harmless and stays.

	Like ClientState this is not loaded by the Loader: init.client.luau starts it
	directly, because it has to watch from the first moment the player is here.

	SetCore raises until the core script that owns the button has registered its
	callback, which happens a little after the player joins. So the request is
	retried, and every attempt re-reads where the player is NOW: a player who went
	into a match and out again while the first attempts were still failing must
	end up with the state they are in, not the one they had when they asked.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.ClientState)
local Trove = require(Shared.Util.Trove)

local ResetButton = {}

local RETRY_SECONDS = 1
-- A minute of trying. If the core script has not registered by then it is not
-- going to, and looping for the whole session would help nobody.
local MAX_ATTEMPTS = 60

local player = Players.LocalPlayer

--[[
	Start following the player. `gui` is the StarterGui to configure and defaults
	to the real one; tests pass their own. Returns a function that stops it.
]]
function ResetButton.watch(gui: any?): () -> ()
	local target = gui or StarterGui
	local trove = Trove.new()
	-- Bumped on every change and on stop, so an attempt loop that is still
	-- waiting sees it is out of date and ends.
	local generation = 0

	local function sync()
		generation += 1
		local mine = generation

		task.spawn(function()
			for _ = 1, MAX_ATTEMPTS do
				if mine ~= generation then
					return
				end

				local allowed = not ClientState.isInMatch()
				if pcall(target.SetCore, target, "ResetButtonCallback", allowed) then
					return
				end
				task.wait(RETRY_SECONDS)
			end
		end)
	end

	trove:Connect(player:GetAttributeChangedSignal("InMatch"), sync)
	sync()

	return function()
		generation += 1
		trove:Clean()
	end
end

return ResetButton
