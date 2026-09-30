--!nonstrict
--[[
	tests/harness/deaths.luau
	The real PlayerService, on the deaths that no bullet finished.

	Roblox's own Reset Character option is in the escape menu of every player, and
	it sets the character's health to zero. Nothing in the combat path sees that,
	so a player losing a duel could escape it, deny the other player the kill, the
	team its point and the coins, and come back at full health three seconds later.
	The same is true of a fall from the map in the second after being shot.

	So the service remembers who last hurt whom, and a death that combat has not
	claimed is credited to that player if the hit was recent.

	Run:  lune run tests/harness/deaths
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

-- Gives Workspace the runtime methods a server takes for granted
-- (GetServerTimeNow is what spawn protection is measured against).
Env.enableClientRuntime()

local Players = Env.service("Players")

--------------------------------------------------------------------------------
-- Stand-ins
--------------------------------------------------------------------------------

local kills: { { killer: any, victim: any } } = {}
local deaths: { any } = {}
local registered: { { victim: any, killer: any, weaponId: any } } = {}
local rebalanced: { any } = {}
local spawnTeams: { { player: any, mapId: string, teamId: string } } = {}
-- What the stand-in match answers when asked whether a kill pays.
local killPays: boolean? = true
local PlayerService: any = nil

Env.provide("src/server/Services/DataService", {
	getEquippedSkin = function()
		return "default"
	end,
	recordKill = function(killer)
		table.insert(kills, { killer = killer })
	end,
	recordDeath = function(victim)
		table.insert(deaths, victim)
	end,
	loadPlayer = function() end,
	releasePlayer = function() end,
})

Env.provide("src/server/Net/Remotes", {
	fireClient = function() end,
})

Env.provide("src/server/World/SpawnDoors", {
	applyToCharacter = function() end,
})

Env.provide("src/shared/GunModelFactory", {
	build = function()
		return nil
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
		return player:GetAttribute("TeamId") or "LOBBY"
	end,
})

Env.provide("src/server/Services/WorldService", {
	isBuilt = function()
		return true
	end,
	getHubSpawn = function()
		return roblox.CFrame.new()
	end,
	getSpawn = function(mapId, teamId)
		table.insert(spawnTeams, { mapId = mapId, teamId = teamId })
		return roblox.CFrame.new()
	end,
	getKillY = function()
		return -60
	end,
})

-- The parts of MatchService a death touches, behaving the way the real one does:
-- a registered kill schedules the victim's respawn.
Env.provide("src/server/Services/MatchService", {
	isInProgress = function()
		return true
	end,
	registerKill = function(victim, killer, weaponId)
		table.insert(registered, { victim = victim, killer = killer, weaponId = weaponId })
		PlayerService.scheduleRespawn(
			victim,
			victim:GetAttribute("InMatch"),
			"A",
			if killer then killer.UserId else nil
		)
		return killPays
	end,
	rebalanceOnRespawn = function(player)
		table.insert(rebalanced, player)
		if player:GetAttribute("MoveTo") then
			player:SetAttribute("TeamId", player:GetAttribute("MoveTo"))
		end
	end,
	onPlayerRemoving = function() end,
})

local nextUserId = 100
local function fakePlayer(name: string)
	nextUserId += 1
	local attributes = {}
	local signals = {}

	local player
	player = {
		Name = name,
		UserId = nextUserId,
		Character = nil,
		GetAttribute = function(_self, key)
			return attributes[key]
		end,
		SetAttribute = function(_self, key, value)
			attributes[key] = value
		end,
		GetAttributeChangedSignal = function(_self, key)
			signals[key] = signals[key] or Env.liveSignal()
			return signals[key]
		end,
		IsDescendantOf = function(_self, ancestor)
			return ancestor == Players
		end,
		LoadCharacter = function(self)
			local humanoid = { Died = Env.liveSignal(), Health = 100, MaxHealth = 100 }
			self.Character = {
				Parent = {},
				humanoid = humanoid,
				PivotTo = function() end,
				FindFirstChild = function()
					return nil
				end,
				FindFirstChildOfClass = function(_c, className)
					return if className == "Humanoid" then humanoid else nil
				end,
			}
		end,
	}
	return player
end

PlayerService = Env.load("src/server/Services/PlayerService")

-- Put `player` in a match on team A, the way MatchRuntime does.
local function intoMatch(player, mapId: string?)
	player:SetAttribute("InMatch", mapId or "Dust")
	PlayerService.spawnInMatch(player, mapId or "Dust", "A")
end

local function reset()
	table.clear(kills)
	table.clear(deaths)
	table.clear(registered)
	table.clear(rebalanced)
	table.clear(spawnTeams)
	killPays = true
end

-- The Reset Character option: health to zero, and nothing else.
local function resetCharacter(player)
	player.Character.humanoid.Died:Fire()
end

--------------------------------------------------------------------------------
-- A reset or a fall after being shot
--------------------------------------------------------------------------------

heading("A death combat did not claim")

do
	reset()
	local victim, shooter = fakePlayer("victim"), fakePlayer("shooter")
	intoMatch(victim)
	intoMatch(shooter)

	PlayerService.noteDamage(victim, shooter, "Rifle")
	resetCharacter(victim)

	check(#registered == 1, `the death is reported to the match once ({#registered})`)
	check(registered[1] ~= nil and registered[1].killer == shooter, "and credited to the player who shot them")
	check(registered[1] ~= nil and registered[1].weaponId == "Rifle", "with the weapon they used")
	check(#kills == 1 and kills[1].killer == shooter, "who is paid for the kill")
	check(#deaths == 1 and deaths[1] == victim, "and the death goes on the victim's record")
	check(PlayerService.isRespawning(victim), "and the victim respawns as after any death")
end

do
	reset()
	local victim, shooter = fakePlayer("victim2"), fakePlayer("shooter2")
	intoMatch(victim)
	intoMatch(shooter)

	-- Hit by the shooter, but a while ago.
	PlayerService.noteDamage(victim, shooter, "Rifle", os.clock() - 6)
	resetCharacter(victim)
	check(#registered == 1 and registered[1].killer == nil, "a hit from six seconds ago is not the reason they died")
	check(#kills == 0, "so nobody is paid")
	check(#deaths == 1, "but it is still a death")
end

do
	reset()
	local victim = fakePlayer("victim3")
	intoMatch(victim)
	resetCharacter(victim)
	check(#registered == 1 and registered[1].killer == nil, "resetting with nobody to blame credits nobody")
	check(#deaths == 1, "and still counts as a death")
	check(#kills == 0, "and pays nothing")
end

do
	reset()
	local victim, shooter = fakePlayer("victim4"), fakePlayer("shooter4")
	intoMatch(victim)
	intoMatch(shooter)
	shooter:SetAttribute("InMatch", "")
	PlayerService.noteDamage(victim, shooter, "Rifle")
	resetCharacter(victim)
	check(#kills == 0, "a shooter who has left the match is not paid for a kill in it")
end

do
	reset()
	local victim, shooter = fakePlayer("victim5"), fakePlayer("shooter5")
	intoMatch(victim)
	intoMatch(shooter)
	killPays = false
	PlayerService.noteDamage(victim, shooter, "Rifle")
	resetCharacter(victim)
	check(#registered == 1, "the match is still told")
	check(#kills == 0, "and a kill the match says does not pay is not paid")
end

do
	reset()
	local victim = fakePlayer("victim6")
	intoMatch(victim)
	PlayerService.noteDamage(victim, victim, "Rifle")
	resetCharacter(victim)
	check(#kills == 0 and registered[1] ~= nil and registered[1].killer == nil, "hurting yourself is nobody's kill")
end

--------------------------------------------------------------------------------
-- A death combat DID claim
--------------------------------------------------------------------------------

heading("A death combat claimed")

do
	reset()
	local victim, shooter = fakePlayer("victim7"), fakePlayer("shooter7")
	intoMatch(victim)
	intoMatch(shooter)

	-- What CombatService does when a shot kills: note the hit, register the kill,
	-- pay it, record the death. The Humanoid's Died event lands afterwards.
	PlayerService.noteDamage(victim, shooter, "Rifle")
	Env.load("src/server/Services/MatchService").registerKill(victim, shooter, "Rifle", false)
	table.insert(kills, { killer = shooter })
	table.insert(deaths, victim)
	table.clear(registered)
	resetCharacter(victim)

	check(#registered == 0, "the match is not told about the same death twice")
	check(#kills == 1, "nobody is paid twice")
	check(#deaths == 1, "and the death is not written down twice")
end

--------------------------------------------------------------------------------
-- The next life starts clean
--------------------------------------------------------------------------------

heading("A new life")

do
	reset()
	local victim, shooter = fakePlayer("victim8"), fakePlayer("shooter8")
	intoMatch(victim)
	intoMatch(shooter)

	PlayerService.noteDamage(victim, shooter, "Rifle")
	Env.load("src/server/Services/MatchService").registerKill(victim, shooter, "Rifle", false)
	table.clear(registered)
	resetCharacter(victim)
	Env.advance(3.5)
	check(victim.Character ~= nil and not PlayerService.isRespawning(victim), "the victim is back")

	-- The old hit must not follow them into the new life.
	table.clear(registered)
	table.clear(kills)
	resetCharacter(victim)
	check(
		#registered == 1 and registered[1].killer == nil,
		"a reset in the next life does not blame last life's shooter"
	)
	check(#kills == 0, "and pays nobody")
end

do
	reset()
	local player = fakePlayer("hubber")
	player:SetAttribute("InMatch", "")
	PlayerService.spawnInHub(player)
	resetCharacter(player)
	check(#registered == 0 and #deaths == 0, "a reset in the hub is not a match death")
	check(PlayerService.isRespawning(player), "but still respawns")
end

--------------------------------------------------------------------------------
-- Rebalancing happens on the respawn, whatever the death
--------------------------------------------------------------------------------

heading("Respawn team")

do
	reset()
	local player = fakePlayer("mover")
	intoMatch(player)
	player:SetAttribute("MoveTo", "B")
	table.clear(spawnTeams)
	resetCharacter(player)
	Env.advance(3.5)

	-- Other tests' players are still waiting out their own respawns.
	local asked = 0
	for _, who in rebalanced do
		if who == player then
			asked += 1
		end
	end
	check(asked == 1, `the match is asked once before the player is respawned ({asked})`)
	-- Spawning writes the team it was given, so this is the side they came back on.
	check(
		player:GetAttribute("TeamId") == "B",
		`and they come back on the side it chose (got {tostring(player:GetAttribute("TeamId"))})`
	)
end

do
	reset()
	local player = fakePlayer("stayer")
	intoMatch(player)
	resetCharacter(player)
	Env.advance(3.5)
	check(player:GetAttribute("TeamId") == "A", "a player the match leaves alone comes back where they were")
end

--------------------------------------------------------------------------------
-- A respawn timer belongs to the life that started it
--
-- A death in the hub starts a three second timer that puts the player back in
-- the hub. If the match seated them inside that window, the timer used to fire
-- anyway: the character went back to the hub with the lobby team and no match
-- while the roster still listed them, a ghost that counted for the score limit
-- and collected the payout. And a timer left over from an earlier life used to
-- swallow the next death, leaving a corpse for good.
--------------------------------------------------------------------------------

heading("A stale respawn timer")

do
	reset()
	local player = fakePlayer("seated")
	player:SetAttribute("InMatch", "")
	PlayerService.spawnInHub(player)
	resetCharacter(player)
	check(PlayerService.isRespawning(player), "a death in the hub starts a respawn")

	-- The countdown ends inside the window and the match seats them, the way
	-- MatchRuntime._place does.
	Env.advance(1)
	player:SetAttribute("InMatch", "Dust")
	PlayerService.spawnInMatch(player, "Dust", "A")
	check(not PlayerService.isRespawning(player), "the new life is not waiting on the old one's respawn")

	Env.advance(3)
	check(
		player:GetAttribute("InMatch") == "Dust",
		`the hub timer does not take them out of the match (InMatch is "{tostring(player:GetAttribute("InMatch"))}")`
	)
	check(
		player:GetAttribute("TeamId") == "A",
		`nor put them on the lobby team (got {tostring(player:GetAttribute("TeamId"))})`
	)
end

do
	reset()
	local player = fakePlayer("seatedFirst")
	player:SetAttribute("InMatch", "")
	PlayerService.spawnInHub(player)
	resetCharacter(player)

	-- Marked as playing, with the spawn itself not started yet.
	player:SetAttribute("InMatch", "Dust")
	local corpse = player.Character
	Env.advance(3.5)
	check(player.Character == corpse, "a hub timer does not spawn anybody the match has already claimed")
	check(player:GetAttribute("InMatch") == "Dust", "and leaves them marked as playing")
end

do
	reset()
	local player = fakePlayer("twice")
	intoMatch(player)

	-- Dies in the match: a respawn on that map is due at 3 s.
	resetCharacter(player)
	Env.advance(1)

	-- Moved to the hub before it lands (idle removal, a forfeit), and dies there.
	player:SetAttribute("InMatch", "")
	PlayerService.spawnInHub(player)
	Env.advance(1)
	local corpse = player.Character
	resetCharacter(player)
	check(PlayerService.isRespawning(player), "the second death is waiting on a respawn of its own")

	Env.advance(1.5)
	Env.advance(3)
	check(player.Character ~= corpse, "the second death still respawns, whatever timer was pending before it")
	check(not PlayerService.isRespawning(player), "and is not left marked as dead")
	check(player:GetAttribute("InMatch") == "", "in the hub")
end

do
	reset()
	local player = fakePlayer("replaced")
	intoMatch(player)
	resetCharacter(player)
	Env.advance(1)

	-- A new life starts before the timer: its own timer, not the old one's, is
	-- what a later death waits for.
	PlayerService.spawnInMatch(player, "Dust", "A")
	Env.advance(0.5)
	local life = player.Character
	Env.advance(2)
	check(player.Character == life, "the timer of a life that is over does not respawn the new one")
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
	error(`{failed} death check(s) failed`, 0)
end
print("  All death checks passed.")
