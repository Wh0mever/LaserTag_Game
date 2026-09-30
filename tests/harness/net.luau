--!nonstrict
--[[
	tests/harness/net.luau
	Runs the real Remotes pipeline and RateLimiter against stand-in remote
	instances.

	The pure rate-limit policy has unit tests; what those cannot say is what the
	pipeline does with it: who gets kicked, what the kick says, and what a hostile
	client can make the server write to its log. Both matter to a player who is
	not cheating — a child tapping a refused button is not an attacker, and the
	message they are shown when the server has had enough is read by them, not by
	an operator.

	Run:  lune run tests/harness/net
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

--------------------------------------------------------------------------------
-- Stand-in remote instances
--------------------------------------------------------------------------------

local folder = { Name = "Remotes", Parent = {} }
local made: { [string]: any } = {}

function folder.IsA(_self, className: string)
	return className == "Folder" or className == "Instance"
end

function folder.FindFirstChild(_self, name: string)
	if not made[name] then
		made[name] = {
			Name = name,
			Parent = folder,
			OnServerEvent = Env.liveSignal(),
			OnServerInvoke = nil,
			IsA = function(_self2, className: string)
				return className == "RemoteEvent" or className == "RemoteFunction" or className == "Instance"
			end,
		}
	end
	return made[name]
end

rawset(Env.service("ReplicatedStorage"), "Remotes", folder)

local kicks: { string } = {}
local function fakePlayer(name: string)
	return {
		Name = name,
		Parent = {},
		Kick = function(_self, message: string)
			table.insert(kicks, message)
		end,
	}
end

local Constants = Env.load("src/shared/Constants")
-- The pipeline's own two-second cooldown after a violation would spread the
-- hammering below over real seconds; it is a separate mechanism with its own
-- spec, and turning it off is what lets a burst reach the kick threshold.
Constants.REMOTE_DEFAULTS.cooldownSeconds = 0

local Remotes = Env.load("src/server/Net/Remotes")
local RemoteNames = Env.load("src/shared/RemoteNames")

local function hammer(callFn, player, times: number)
	for _ = 1, times do
		callFn(player)
	end
end

--------------------------------------------------------------------------------
-- Who is kicked
--------------------------------------------------------------------------------

heading("Rate limit kicks")

do
	-- Stands in for a combat remote: a client firing it faster than any weapon
	-- can is not playing the game.
	Remotes.register({
		Name = "ProbeCombat",
		Handler = function() end,
		RateLimit = 3,
		WindowSeconds = 5,
	})
	local attacker = fakePlayer("attacker")
	table.clear(kicks)
	hammer(function(p)
		made.ProbeCombat.OnServerEvent:Fire(p)
	end, attacker, 30)
	check(#kicks >= 1, "a client flooding a gameplay remote is still kicked")
	check(
		kicks[1] ~= nil and string.find(kicks[1], "Слишком много запросов", 1, true) ~= nil,
		`and is told why in Russian (got "{tostring(kicks[1])}")`
	)
end

do
	-- A button a person taps. Being refused ("this would unbalance the teams")
	-- and tapping again is the natural reaction, and it must cost a message on
	-- screen, not the connection.
	Remotes.register({
		Name = RemoteNames.ChooseSideRequest,
		Type = "Function",
		Handler = function()
			return { ok = false }
		end,
		RateLimit = 6,
		WindowSeconds = 10,
	})
	local child = fakePlayer("child")
	table.clear(kicks)
	hammer(function(p)
		made[RemoteNames.ChooseSideRequest].OnServerInvoke(p, "A")
	end, child, 60)
	check(#kicks == 0, `tapping a refused side button is never a kick ({#kicks} kicks)`)
end

do
	for _, name in
		{
			RemoteNames.TeamCountsRequest,
			RemoteNames.SpinRequest,
			RemoteNames.BuySkinRequest,
			RemoteNames.EquipSkinRequest,
			RemoteNames.SaveSettingsRequest,
			RemoteNames.GetFriendsRequest,
		}
	do
		Remotes.register({
			Name = name,
			Type = "Function",
			Handler = function() end,
			RateLimit = 2,
			WindowSeconds = 10,
		})
		local player = fakePlayer(`ui-{name}`)
		table.clear(kicks)
		hammer(function(p)
			made[name].OnServerInvoke(p, "x")
		end, player, 40)
		check(#kicks == 0, `{name} is a screen control and never kicks ({#kicks} kicks)`)
	end
end

--------------------------------------------------------------------------------
-- What a client can make the server write
--------------------------------------------------------------------------------

heading("Log hygiene")

do
	local hostile = string.rep("A", 400) .. "\n[Remotes] forged line from the server itself"
	Remotes.register({
		Name = "ProbeValidated",
		Handler = function() end,
		Validator = function()
			return false, hostile
		end,
		RateLimit = 100,
		WindowSeconds = 5,
	})

	local prober = fakePlayer("prober")
	table.clear(Env.warnings)
	hammer(function(p)
		made.ProbeValidated.OnServerEvent:Fire(p)
	end, prober, 50)

	local lines = {}
	for _, line in Env.warnings do
		if string.find(line, "failed validation", 1, true) then
			table.insert(lines, line)
		end
	end

	check(#lines == 1, `fifty rejected requests write one validation line, not fifty ({#lines})`)
	local line = lines[1] or ""
	check(#line < 200, `and it is short whatever the client sent ({#line} characters)`)
	check(not string.find(line, "[\r\n]"), "and the client's text cannot break it into two lines")
end

do
	Remotes.register({
		Name = "ProbeCrash",
		Handler = function()
			error("boom " .. string.rep("B", 400))
		end,
		RateLimit = 100,
		WindowSeconds = 5,
	})
	local prober = fakePlayer("prober2")
	table.clear(Env.warnings)
	hammer(function(p)
		made.ProbeCrash.OnServerEvent:Fire(p)
	end, prober, 50)

	local count, longest = 0, 0
	for _, line in Env.warnings do
		if string.find(line, "ProbeCrash", 1, true) then
			count += 1
			longest = math.max(longest, #line)
		end
	end
	check(count == 1, `a handler that keeps erroring is logged once per interval ({count} lines)`)
	check(longest < 340, `and its message is capped ({longest} characters)`)
end

do
	-- A real bug has to stay findable: the location in our own code is the
	-- whole point of the line.
	local realBug = "Services.ShopService:88: attempt to index nil with 'price'"
	Remotes.register({
		Name = "ProbeBug",
		Handler = function()
			error(realBug, 0)
		end,
		RateLimit = 100,
		WindowSeconds = 5,
	})
	table.clear(Env.warnings)
	made.ProbeBug.OnServerEvent:Fire(fakePlayer("prober3"))

	local kept = false
	for _, line in Env.warnings do
		if string.find(line, realBug, 1, true) then
			kept = true
		end
	end
	check(kept, "an error from our own code is logged with its location intact")
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
	error(`{failed} net check(s) failed`, 0)
end
print("  All net checks passed.")
