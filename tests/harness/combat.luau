--!nonstrict
--[[
	tests/harness/combat.luau
	Runs the real combat stack against stand-in services.

	Combat is where a wrong number costs a match: a fire-rate gate that eats one
	honest shot in six, a reload that finishes on the wrong life, a beam sent to
	every player on the server. The pure maths under it has unit specs; what
	decides whether a shot counts (WeaponState, ShootValidation, ShotResolver,
	CombatService, the position tracker) is Roblox-facing and had no execution
	outside a live server.

	Everything the stack calls (the network, profiles, matches, teams) is
	replaced by a recorder, so what is under test is combat's own decisions.
	Time is virtual: nothing here sleeps, Env.advance() moves the clock, and the
	same run gives the same answer every time.

	Run:  lune run tests/harness/combat
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
		print(`  FAIL  {message}`)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

--------------------------------------------------------------------------------
-- WeaponState: the fire-rate gate
--
-- The gate has two jobs that pull against each other. An honest client sends
-- shots on its own frame clock and the network adds jitter on top, so
-- consecutive requests arrive a frame early about as often as a frame late and
-- the gate has to let that through. But whatever slack it allows must not turn
-- into a faster weapon: the rate a client can SUSTAIN has to stay at or below
-- one shot per fireRate no matter how the arrivals are spaced.
--------------------------------------------------------------------------------

local WeaponState = Env.load("src/server/Combat/WeaponState")
local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
local SprayPatterns = Env.load("src/shared/Config/SprayPatterns")

-- Deterministic jitter in [-1, 1]: a fixed sequence so a failing run fails the
-- same way every time.
local function jitterSource(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return (state / 2147483648) * 2 - 1
	end
end

heading("Fire-rate gate")

do
	local rifle = WeaponConfig.Weapons.Rifle
	local player = {}

	-- 1. A perfect 600 RPM client whose packets arrive up to 20 ms early or late.
	-- Nothing about that is cheating, so every shot must be honoured.
	local jitter = jitterSource(7)
	local accepted, total = 0, 300
	for shot = 0, total - 1 do
		local entry = WeaponState.get(player, "Rifle")
		entry.mag = rifle.magSize
		local arrival = 100 + shot * rifle.fireRate + jitter() * 0.020
		if WeaponState.consumeShot(player, "Rifle", arrival) then
			accepted += 1
		end
	end
	check(
		accepted == total,
		`a steady 600 RPM client with +/-20 ms of arrival jitter is never dropped ({accepted}/{total} accepted)`
	)

	-- 2. Someone pacing shots just inside the old floor. Whatever the slack, the
	-- sustained rate must not beat the weapon's own: 20 seconds at 0.1 s is 200
	-- shots, plus the one that opens the burst.
	WeaponState.clear(player)
	local pacing = 0.087
	local sustained = 0
	for shot = 0, math.floor(20 / pacing) do
		local entry = WeaponState.get(player, "Rifle")
		entry.mag = rifle.magSize
		if WeaponState.consumeShot(player, "Rifle", 100 + shot * pacing) then
			sustained += 1
		end
	end
	check(
		sustained <= 20 / rifle.fireRate + 1,
		`shots paced just under the interval cannot beat the weapon's fire rate ({sustained} accepted in 20 s, cap {20 / rifle.fireRate + 1})`
	)

	-- 3. And a real burst: ten shots at exactly the cadence all land.
	WeaponState.clear(player)
	local burst = 0
	for shot = 0, 9 do
		if WeaponState.consumeShot(player, "Rifle", 200 + shot * rifle.fireRate) then
			burst += 1
		end
	end
	check(burst == 10, `ten shots at exactly the fire rate all land ({burst}/10)`)
end

--------------------------------------------------------------------------------
-- WeaponState: the spray reset
--
-- The server's spray index only sets the accuracy cone, but it has to agree with
-- the client's crosshair or the same burst is drawn one way and shot another.
-- The client resets when its own gap between shots exceeds the weapon's reset
-- time; the server sees that gap plus whatever the network added, so it must
-- not reset a burst the client believes is still going.
--------------------------------------------------------------------------------

heading("Spray reset tolerance")

do
	local rifle = WeaponConfig.Weapons.Rifle
	local resetTime = rifle.sprayResetTime
	local player = {}

	local function burstThenGap(gap: number): number
		WeaponState.clear(player)
		local now = 300
		for _ = 1, 5 do
			WeaponState.consumeShot(player, "Rifle", now)
			now += rifle.fireRate
		end
		-- The last of those shots was at now - fireRate.
		local _, index = WeaponState.consumeShot(player, "Rifle", now - rifle.fireRate + gap)
		return index
	end

	check(burstThenGap(0.1) == 6, "a burst continues while the trigger is held")
	check(
		burstThenGap(resetTime - 0.01) == 6,
		"a gap just inside the reset time continues the pattern (client and server agree)"
	)
	check(
		burstThenGap(resetTime + 0.03) == 6,
		"a gap a few milliseconds past the reset time still continues: network timing must not restart a burst the client sees as unbroken"
	)
	check(burstThenGap(resetTime + 0.2) == 1, "a genuine pause restarts the pattern")
	check(
		SprayPatterns.nextIndex("Rifle", 5, 0.1, resetTime) == 6,
		"the client's own two-argument reset is untouched by the server's tolerance"
	)
end

--------------------------------------------------------------------------------
-- WeaponState: reloads
--------------------------------------------------------------------------------

heading("Reloads across lives")

do
	local pistol = WeaponConfig.Weapons.Pistol
	local player = {}

	-- Life one: a reload is under way, its timer is still pending, and the
	-- player respawns before it fires (switching side does exactly that).
	WeaponState.clear(player)
	local first = WeaponState.get(player, "Pistol")
	first.mag = 2
	local started, staleToken = WeaponState.beginReload(player, "Pistol", 500)
	check(started, "a reload starts on the first life")
	WeaponState.reset(player)

	-- Life two starts its own reload before the old timer fires.
	local entry = WeaponState.get(player, "Pistol")
	entry.mag = 1
	local startedAgain, freshToken = WeaponState.beginReload(player, "Pistol", 500.5)
	check(startedAgain, "and a reload starts on the second life")
	check(freshToken ~= staleToken, "the second life's reload does not reuse the first life's token")

	-- The old life's timer now fires with the old token.
	local finished = WeaponState.finishReload(player, "Pistol", staleToken)
	check(not finished, "a timer left over from the previous life cannot finish this life's reload")
	check(WeaponState.get(player, "Pistol").mag == 1, "the magazine is untouched by the stale timer")
	check(WeaponState.finishReload(player, "Pistol", freshToken), "the reload's own timer still finishes it")
	check(WeaponState.get(player, "Pistol").mag == pistol.magSize, "and the magazine is full")
end

heading("The window between a reload's end and its timer")

do
	local pistol = WeaponConfig.Weapons.Pistol
	local player = {}

	WeaponState.clear(player)
	local entry = WeaponState.get(player, "Pistol")
	entry.mag = 0
	local started = WeaponState.beginReload(player, "Pistol", 600)
	check(started, "the reload starts")

	-- The reload ended a frame ago; the task.delay that completes it has not run.
	local due = 600 + pistol.reloadTime
	local fired = WeaponState.consumeShot(player, "Pistol", due + 0.01)
	check(fired, "a shot arriving after the reload has ended is honoured even before its timer has run")
	check(
		WeaponState.get(player, "Pistol").mag == pistol.magSize - 1,
		`and it fires from a full magazine (mag {WeaponState.get(player, "Pistol").mag})`
	)

	-- The same window must not swallow a follow-up reload request either.
	WeaponState.clear(player)
	entry = WeaponState.get(player, "Pistol")
	entry.mag = 3
	WeaponState.beginReload(player, "Pistol", 700)
	local again = WeaponState.beginReload(player, "Pistol", 700 + pistol.reloadTime + 0.01)
	check(not again, "a reload requested just after one has ended does not restart it")
	check(WeaponState.get(player, "Pistol").mag == pistol.magSize, "the finished reload is not thrown away")

	-- A shot a little before the server's own clock says the reload is over is
	-- what an honest client sends: it started its reload one trip earlier and
	-- so did the request, and both trips take the same time.
	WeaponState.clear(player)
	entry = WeaponState.get(player, "Pistol")
	entry.mag = 0
	WeaponState.beginReload(player, "Pistol", 800)
	local early = WeaponState.consumeShot(player, "Pistol", 800 + pistol.reloadTime - 0.05)
	check(early, "a shot 50 ms before the reload ends is honoured: latency jitter, not a cheat")
	WeaponState.clear(player)
	entry = WeaponState.get(player, "Pistol")
	entry.mag = 0
	WeaponState.beginReload(player, "Pistol", 900)
	local tooEarly = WeaponState.consumeShot(player, "Pistol", 900 + pistol.reloadTime - 0.4)
	check(not tooEarly, "but a shot well before the reload ends is still refused")
end

--------------------------------------------------------------------------------
-- The stack
--
-- CombatService, ShootValidation, ShotResolver and WeaponState run for real.
-- What they talk to does not: the network is a recorder that also plays the
-- part of Remotes' pipeline (validator, then handler), and players, characters
-- and the world are Instances built here.
--------------------------------------------------------------------------------

local Players = Env.service("Players")
local world = Env.workspace()
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

-- Lune models Roblox's data, not its runtime, so the few engine behaviours the
-- combat code leans on are declared here. Each is installed once per process,
-- and tolerantly: if the shared sandbox learns one of them, its version wins.
local function tryImplement(install: () -> ())
	pcall(install)
end

local function liveEvent(class: string, name: string)
	tryImplement(function()
		roblox.implementProperty(class, name, function(self)
			return Env.instanceEvent(self, name)
		end)
	end)
end

liveEvent("Player", "CharacterAdded")
liveEvent("Humanoid", "Died")
liveEvent("Instance", "DescendantAdded")

tryImplement(function()
	roblox.implementMethod("Humanoid", "TakeDamage", function(self, amount: number)
		self.Health = math.max(self.Health - amount, 0)
	end)
end)

-- What the engine would report as a player's one-way network latency.
local pingSeconds: { [any]: number } = {}
tryImplement(function()
	roblox.implementMethod("Player", "GetNetworkPing", function(self)
		return pingSeconds[self] or 0
	end)
end)

local roster: { any } = {}
Players.GetPlayers = function()
	return table.clone(roster)
end
Players.PlayerAdded = Env.liveSignal()
Players.PlayerRemoving = Env.liveSignal()

-- The network: every server-to-client message, in order, plus the request
-- pipeline for the client-to-server ones.
local sent: { { name: string, player: any, args: { any } } } = {}
local remoteConfigs: { [string]: any } = {}

local function record(name: string, player: any, ...)
	table.insert(sent, { name = name, player = player, args = table.pack(...) })
end

Env.provide("src/server/Net/Remotes", {
	register = function(config)
		remoteConfigs[config.Name] = config
	end,
	fireClient = record,
	fireAllClientsExcept = function(name: string, excluded: any, ...)
		for _, other in Players:GetPlayers() do
			if other ~= excluded then
				record(name, other, ...)
			end
		end
	end,
	fireAllClients = function(name: string, ...)
		for _, other in Players:GetPlayers() do
			record(name, other, ...)
		end
	end,
})

local SkinCatalog = Env.load("src/shared/Config/SkinCatalog")

Env.provide("src/server/Services/DataService", {
	getEquippedSkin = function()
		return SkinCatalog.DEFAULT_SKIN_ID
	end,
	recordKill = function() end,
	recordDeath = function() end,
})

Env.provide("src/server/Services/MatchService", {
	markActivity = function() end,
	isInProgress = function()
		return true
	end,
	registerKill = function() end,
})

Env.provide("src/server/Services/TeamService", {
	sameTeam = function(a, b)
		return a:GetAttribute("TeamId") == b:GetAttribute("TeamId")
	end,
	getTeamId = function(player)
		return player:GetAttribute("TeamId")
	end,
})

Env.provide("src/server/Services/PlayerService", {
	isSpawnProtected = function(player)
		local protectedUntil = player:GetAttribute("SpawnProtectedUntil")
		return type(protectedUntil) == "number" and world:GetServerTimeNow() < protectedUntil
	end,
	clearSpawnProtection = function(player)
		player:SetAttribute("SpawnProtectedUntil", 0)
	end,
})

local nextUserId = 100

local function newPlayer(name: string, mapId: string, teamId: string)
	nextUserId += 1
	local player = roblox.Instance.new("Player")
	player.Name = name
	player.DisplayName = name
	player.UserId = nextUserId
	player:SetAttribute("InMatch", mapId)
	player:SetAttribute("TeamId", teamId)
	player:SetAttribute("CurrentWeapon", "Rifle")
	player:SetAttribute("SpawnProtectedUntil", 0)
	table.insert(roster, player)
	return player
end

-- Lune keeps Position and CFrame as separate stored values, so both are written.
local function place(part: any, position: any)
	part.Position = position
	part.CFrame = CFrame.new(position)
end

local function newPart(name: string, parent: any, position: any, size: any?)
	local part = roblox.Instance.new("Part")
	part.Name = name
	part.Size = size or Vector3.new(2, 2, 1)
	place(part, position)
	part.Parent = parent
	return part
end

-- A character standing with its root at `position`: a Humanoid, the root part,
-- a head and a torso, in the workspace.
local function newCharacter(player: any, position: any)
	local character = roblox.Instance.new("Model")
	character.Name = player.Name

	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = character

	local root = newPart("HumanoidRootPart", character, position)
	newPart("Head", character, position + Vector3.new(0, 1.5, 0), Vector3.new(1.2, 1.2, 1.2))
	newPart("UpperTorso", character, position + Vector3.new(0, 0.2, 0), Vector3.new(2, 1.6, 1))

	character.Parent = world
	player.Character = character
	return character, humanoid, root
end

-- Puts a character on the field and tells the game about it, the way a
-- LoadCharacter does.
local function spawnPlayer(player: any, position: any)
	local previous = player.Character
	if previous then
		previous:Destroy()
	end
	local character, humanoid, root = newCharacter(player, position)
	Env.instanceEvent(player, "CharacterAdded"):Fire(character)
	return character, humanoid, root
end

-- Sends a client-to-server request through the same validate-then-handle steps
-- Remotes runs. Returns whether it got through and, if not, why.
local function request(name: string, player: any, ...): (boolean, string?)
	local config = remoteConfigs[name]
	if config.Validator then
		local ok, reason = config.Validator(player, ...)
		if not ok then
			return false, reason
		end
	end
	local handled, err = pcall(config.Handler, player, ...)
	if not handled then
		check(false, `{name} handler raised: {err}`)
		return false, tostring(err)
	end
	return true, nil
end

local seqByPlayer: { [any]: number } = {}

local function shoot(player: any, weaponId: string, direction: any?): boolean
	seqByPlayer[player] = (seqByPlayer[player] or 0) + 1
	local root = player.Character.HumanoidRootPart
	local origin = root.Position + Vector3.new(0, 1.5, 0)
	local ok =
		request("ShootRequest", player, weaponId, seqByPlayer[player], origin, direction or Vector3.new(0, 0, -1))
	return ok
end

local function countSent(name: string, recipient: any?): number
	local count = 0
	for _, message in sent do
		if message.name == name and (recipient == nil or message.player == recipient) then
			count += 1
		end
	end
	return count
end

local function clearSent()
	table.clear(sent)
end

local CombatService = Env.load("src/server/Services/CombatService")
CombatService.init()

local function join(player: any)
	Players.PlayerAdded:Fire(player)
end

--------------------------------------------------------------------------------
-- Weapon swaps
--
-- The fire rate is tracked per weapon, so nothing stopped a modified client
-- from asking for the lance, the pistol and the rifle in one frame and landing
-- a shot from each. The swap has to cost time on the server too, not only in
-- the client's raise animation.
--------------------------------------------------------------------------------

heading("Weapon swap lockout")

do
	local shooter = newPlayer("Swapper", "Dust", "A")
	join(shooter)
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	Env.advance(10)
	clearSent()

	local lance = WeaponConfig.Weapons.Lance
	local pistol = WeaponConfig.Weapons.Pistol

	local function magOf(weaponId: string): number
		return WeaponState.get(shooter, weaponId).mag
	end

	-- The lance is out and fired.
	request("EquipWeaponRequest", shooter, 3)
	Env.advance(WeaponConfig.SWITCH_TIME)
	shoot(shooter, "Lance")
	check(magOf("Lance") == lance.magSize - 1, "a swap followed by the lockout's end fires normally")

	-- Then, in the same instant: pistol, and rifle.
	request("EquipWeaponRequest", shooter, 2)
	shoot(shooter, "Pistol")
	check(magOf("Pistol") == pistol.magSize, "a shot in the same instant as the swap is refused")

	Env.advance(0.2)
	shoot(shooter, "Pistol")
	check(magOf("Pistol") == pistol.magSize, "and still refused while the raise animation would be under way")

	Env.advance(0.1)
	shoot(shooter, "Pistol")
	check(magOf("Pistol") == pistol.magSize - 1, "but allowed once the swap has had time to finish, less network slack")

	-- Asking for the weapon already in hand changes nothing and locks nothing.
	Env.advance(2)
	request("EquipWeaponRequest", shooter, 2)
	shoot(shooter, "Pistol")
	check(magOf("Pistol") == pistol.magSize - 2, "re-selecting the weapon in hand does not lock it out")

	-- Swapping back and forth cannot be used to fire every weapon at once.
	Env.advance(2)
	local before = magOf("Rifle") + magOf("Pistol") + magOf("Lance")
	request("EquipWeaponRequest", shooter, 1)
	shoot(shooter, "Rifle")
	request("EquipWeaponRequest", shooter, 3)
	shoot(shooter, "Lance")
	request("EquipWeaponRequest", shooter, 2)
	shoot(shooter, "Pistol")
	local after = magOf("Rifle") + magOf("Pistol") + magOf("Lance")
	check(after == before, `three swaps in one instant land no shots ({before - after} rounds spent)`)

	-- A new life clears it: the client drops its own lockout on respawn, so an
	-- honest player may fire immediately.
	request("EquipWeaponRequest", shooter, 1)
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	shoot(shooter, "Rifle")
	check(
		magOf("Rifle") == WeaponConfig.Weapons.Rifle.magSize - 1,
		"a swap made just before dying does not lock the next life"
	)
end

--------------------------------------------------------------------------------
-- Who is told about a shot
--
-- Every map runs its own match at the same time, and the hub is full of people
-- with no gun. A beam is worth drawing only for those who could see it, and
-- ShotFired is an unreliable remote with a small queue per client: a shot on
-- Dust must not spend a hub player's queue.
--------------------------------------------------------------------------------

heading("Shot broadcast")

do
	local shooter = newPlayer("Sharpshooter", "Dust", "A")
	local ally = newPlayer("Ally", "Dust", "A")
	local enemy = newPlayer("Enemy", "Dust", "B")
	local elsewhere = newPlayer("Elsewhere", "Mirage", "B")
	local lobbyist = newPlayer("Lobbyist", "", "LOBBY")

	local everyone = { shooter, ally, enemy, elsewhere, lobbyist }
	for index, player in everyone do
		join(player)
		spawnPlayer(player, Vector3.new(index * 40, 3, 300))
	end

	Env.advance(5)
	clearSent()
	shoot(shooter, "Rifle")

	check(countSent("ShotFired", ally) == 1, "a teammate in the same match sees the beam")
	check(countSent("ShotFired", enemy) == 1, "so does an opponent in the same match")
	check(countSent("ShotFired", shooter) == 0, "the shooter drew their own beam and is not sent a second one")
	check(countSent("ShotFired", elsewhere) == 0, "a match on another map is not sent it")
	check(countSent("ShotFired", lobbyist) == 0, "and neither is the hub")
end

--------------------------------------------------------------------------------
-- Report
--------------------------------------------------------------------------------

print("")
print(string.rep("-", 60))
print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	print("")
	error(`{failed} combat check(s) failed`, 0)
end

print("  All combat checks passed.")
