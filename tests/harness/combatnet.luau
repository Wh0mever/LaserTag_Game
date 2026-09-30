--!nonstrict
--[[
	tests/harness/combatnet.luau
	Runs CombatService's remotes through the real Remotes pipeline and the real
	RateLimiter, with stand-in remote instances and a virtual clock.

	The combat harness drives the handlers directly, which is right for what a
	shot does and blind to what the pipeline in front of it does to a player. That
	matters for one request in particular: the weapon switch. The touch HUD's
	switch button and a controller's bumpers can be pressed as fast as a thumb
	moves, the client does nothing to slow them, and the server already ignores a
	switch to the weapon in hand and charges the real cost through the swap
	lockout. Being limited for it is fine. Being disconnected for it is not.

	Run:  lune run tests/harness/combatnet
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

Env.useVirtualClock()
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
local world = Env.workspace()

-- Nobody joins this game through PlayerAdded here; the requests are fired at the
-- remotes directly, as the engine would deliver them.
Players.GetPlayers = function()
	return {}
end
Players.PlayerAdded = Env.liveSignal()
Players.PlayerRemoving = Env.liveSignal()

local kicks: { string } = {}
pcall(function()
	roblox.implementMethod("Player", "Kick", function(self, message: string?)
		table.insert(kicks, message or "")
		-- The connection is gone; the pipeline only kicks a player who is still in.
		self.Parent = nil
	end)
end)

-- The remotes folder, with remote stand-ins that can be fired at and from.
local folder = { Name = "Remotes", Parent = {} }
local made: { [string]: any } = {}
local firedAtClients = 0

function folder.IsA(_self, className: string)
	return className == "Folder" or className == "Instance"
end

function folder.FindFirstChild(_self, name: string)
	if not made[name] then
		made[name] = {
			Name = name,
			Parent = folder,
			OnServerEvent = Env.liveSignal(),
			IsA = function(_self2, className: string)
				return className == "RemoteEvent" or className == "Instance"
			end,
			FireClient = function()
				firedAtClients += 1
			end,
		}
	end
	return made[name]
end

rawset(Env.service("ReplicatedStorage"), "Remotes", folder)

-- What CombatService talks to that is not under test. It only reaches them from
-- the shot and kill paths, which nothing here fires.
for _, path in
	{
		"src/server/Services/DataService",
		"src/server/Services/MatchService",
		"src/server/Services/PlayerService",
		"src/server/Services/TeamService",
	}
do
	Env.provide(path, {})
end

local RemoteNames = Env.load("src/shared/RemoteNames")
local CombatService = Env.load("src/server/Services/CombatService")
CombatService.init()

-- A player standing in the world with a live character, holding the rifle.
local function newPlayer(name: string)
	local player = roblox.Instance.new("Player")
	player.Name = name
	player:SetAttribute("CurrentWeapon", "Rifle")
	player.Parent = world

	local character = roblox.Instance.new("Model")
	character.Name = name
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.Health = 100
	humanoid.Parent = character
	character.Parent = world
	player.Character = character
	return player
end

--------------------------------------------------------------------------------
-- Mashing the switch button
--------------------------------------------------------------------------------

heading("Switching weapons as fast as a thumb can")

do
	local player = newPlayer("Masher")
	table.clear(kicks)
	firedAtClients = 0

	-- Six presses a second for two minutes, alternating rifle and pistol so that
	-- every one of them is a real switch. Sustained, because a burst is easy to
	-- forgive and a habit is not.
	local presses = 6 * 120
	local slot = 1
	for _ = 1, presses do
		slot = if slot == 1 then 2 else 1
		made[RemoteNames.EquipWeaponRequest].OnServerEvent:Fire(player, slot)
		Env.advance(1 / 6)
	end

	check(#kicks == 0, `mashing the switch button for two minutes is never a kick ({#kicks} kicks)`)

	-- Each switch that got through tells the client about both weapons.
	local switches = firedAtClients / 2
	check(
		switches > 0 and switches < presses,
		`but it is still limited: the excess is dropped ({switches} of {presses} switches went through)`
	)
	check(
		switches <= 20 * (120 / 5 + 1),
		`at the pipeline's own rate, twenty in five seconds ({switches} switches in two minutes)`
	)
end

--------------------------------------------------------------------------------
-- And the requests that are attacks still are
--------------------------------------------------------------------------------

heading("Flooding shots")

do
	-- The same rig has to be able to see a kick, or the check above proves
	-- nothing. Nothing legitimate sends shots faster than a weapon fires.
	local flooder = newPlayer("Flooder")
	table.clear(kicks)

	for _ = 1, 8 do
		for _ = 1, 100 do
			made[RemoteNames.ShootRequest].OnServerEvent:Fire(
				flooder,
				"Rifle",
				1,
				roblox.Vector3.new(0, 0, 0),
				roblox.Vector3.new(0, 0, -1)
			)
		end
		-- Past the two-second cooldown each violation opens, so the next one counts.
		Env.advance(2.1)
	end

	check(#kicks >= 1, "a client flooding ShootRequest is still kicked")
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
	error(`{failed} combat network check(s) failed`, 0)
end
print("  All combat network checks passed.")
