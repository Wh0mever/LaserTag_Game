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

	-- 1b. The client's own schedule leans on a little carried lateness (see
	-- WeaponClient.FIRE_CARRY): the shortest gap it sends is 12 ms under the
	-- interval, alternating with a longer one. On top of 10 ms of jitter that must
	-- still never be refused.
	WeaponState.clear(player)
	local leaning = jitterSource(11)
	local leanAccepted, leanTotal, sentAt = 0, 300, 400
	for shot = 0, leanTotal - 1 do
		local entry = WeaponState.get(player, "Rifle")
		entry.mag = rifle.magSize
		sentAt += rifle.fireRate + (if shot % 2 == 0 then -0.012 else 0.012)
		if WeaponState.consumeShot(player, "Rifle", sentAt + leaning() * 0.010) then
			leanAccepted += 1
		end
	end
	check(
		leanAccepted == leanTotal,
		`shots at the client's shortest gap, with jitter, are never dropped ({leanAccepted}/{leanTotal} accepted)`
	)

	-- 2. Someone pacing shots just inside the old floor. Whatever the slack, the
	-- sustained rate must not beat the weapon's own: 20 seconds at 0.1 s is 200
	-- shots, plus the one that opens the burst, plus the single round of catch-up
	-- a client is owed after a quiet spell (WeaponState.MAX_LATE). Pacing at 87 ms
	-- and being let through would be 229.
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
		sustained <= 20 / rifle.fireRate + 2,
		`shots paced just under the interval cannot beat the weapon's fire rate ({sustained} accepted in 20 s, cap {20 / rifle.fireRate + 2})`
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
-- WeaponState: the fire-rate gate on a phone's connection
--
-- The checks above jitter each arrival around its own slot. A mobile link does
-- not behave like that: a packet is held up, and the next one, sent on time, is
-- then closer behind it than a rifle's interval. Remote events are ordered, so
-- nothing overtakes; what changes is the gap between arrivals. A gate that
-- books each shot where it ARRIVED takes the late packet's word for when the
-- burst is running, and refuses the honest shot behind it.
--------------------------------------------------------------------------------

heading("Fire-rate gate on a phone's connection")

do
	local rifle = WeaponConfig.Weapons.Rifle
	local player = {}

	-- A perfect client at the weapon's own rate, whose packets each take
	-- `delay()` seconds to arrive and are delivered in the order they were sent.
	local function heldTrigger(shots: number, delay: () -> number, from: number): { number }
		local arrivals = {}
		local previous = -math.huge
		for shot = 0, shots - 1 do
			local arrival = math.max(from + shot * rifle.fireRate + delay(), previous)
			previous = arrival
			table.insert(arrivals, arrival)
		end
		return arrivals
	end

	local function accepted(arrivals: { number }): number
		WeaponState.clear(player)
		local count = 0
		for _, arrival in arrivals do
			WeaponState.get(player, "Rifle").mag = rifle.magSize
			if WeaponState.consumeShot(player, "Rifle", arrival) then
				count += 1
			end
		end
		return count
	end

	local function uniformDelay(seed: number, longest: number): () -> number
		local source = jitterSource(seed)
		return function()
			return (source() + 1) * 0.5 * longest
		end
	end

	local function exponentialDelay(seed: number, mean: number): () -> number
		local source = jitterSource(seed)
		return function()
			return -math.log(1 - (source() + 1) * 0.5) * mean
		end
	end

	-- Half a minute of a held trigger is 300 shots; every one of these is a
	-- client doing exactly what it should.
	local total = 300

	for _, longest in { 0.020, 0.060, 0.100, 0.150 } do
		local got = accepted(heldTrigger(total, uniformDelay(3, longest), 1000))
		check(
			got == total,
			`a steady 600 RPM client is never dropped with 0-{longest * 1000} ms of delivery delay ({got}/{total} accepted)`
		)
	end

	local mean30 = accepted(heldTrigger(total, exponentialDelay(5, 0.030), 1000))
	check(
		mean30 >= total * 0.99,
		`at most a shot in a hundred is lost to exponentially distributed delay with a 30 ms mean ({mean30}/{total} accepted)`
	)
	local mean50 = accepted(heldTrigger(total, exponentialDelay(9, 0.050), 1000))
	check(mean50 >= total * 0.95, `and at most one in twenty at a 50 ms mean ({mean50}/{total} accepted)`)

	-- A stall: the link goes quiet for half a second and delivers everything
	-- queued behind it at once. Five shots were sent in that time. The gate may
	-- not honour all five (that would be a rifle that fires five in an instant),
	-- but it must not throw all but one away either: the player held the trigger
	-- for a tenth of a second per shot, and a little of that is owed back.
	local stallAt = 2000
	local queued = {}
	for shot = 0, 4 do
		queued[shot + 1] = stallAt + 0.5
	end
	local landedFromStall = accepted(queued)
	check(
		landedFromStall >= 2,
		`a half-second stall delivering five queued shots at once honours more than one ({landedFromStall}/5 accepted)`
	)
	check(
		landedFromStall <= 3,
		`but not the whole queue: a stall is not a way to bank a magazine ({landedFromStall}/5 accepted)`
	)

	-- And the shots the client went on sending, on time, behind the burst.
	local behind = {}
	for shot = 0, 4 do
		behind[shot + 1] = stallAt + 0.5
	end
	for shot = 1, 20 do
		table.insert(behind, stallAt + 0.5 + shot * rifle.fireRate)
	end
	local landedBehind = accepted(behind) - landedFromStall
	check(
		landedBehind >= 19,
		`the stream behind a stall is served: at most one of the next twenty shots is lost ({landedBehind}/20 accepted)`
	)

	-- None of it is a rate. However long a client sat quiet, or however hard it
	-- floods, the gate hands out no more than one shot per interval beyond a
	-- fixed, small allowance.
	local idle = {}
	for _ = 1, 30 do
		table.insert(idle, 3000)
	end
	local fromIdle = accepted(idle)
	check(
		fromIdle <= 3,
		`thirty shots in one instant after a long quiet spell land at most three ({fromIdle} accepted)`
	)

	local flood = {}
	for step = 0, 60 * 1000 do
		table.insert(flood, 4000 + step / 1000)
	end
	WeaponState.clear(player)
	local early, late = 0, 0
	for _, arrival in flood do
		WeaponState.get(player, "Rifle").mag = rifle.magSize
		if WeaponState.consumeShot(player, "Rifle", arrival) then
			if arrival < 4020 then
				early += 1
			else
				late += 1
			end
		end
	end
	check(
		late <= 40 / rifle.fireRate + 1,
		`a thousand requests a second for a minute settle at the weapon's rate ({late} accepted in the last 40 s, cap {40 / rifle.fireRate + 1})`
	)
	check(
		early <= 20 / rifle.fireRate + 3,
		`and the first 20 s hold only the opening shot and a little catch-up ({early} accepted, cap {20 / rifle.fireRate + 3})`
	)
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
Players.GetPlayerFromCharacter = function(_self, character: any)
	for _, player in roster do
		if player.Character == character then
			return player
		end
	end
	return nil
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

-- What CombatService tells its neighbours, for the section that checks it.
-- `killPays` is the answer the match gives to "does this kill pay": nil when no
-- match claims it, false once a pair has traded too many.
local told = { activity = {}, noted = {}, kills = 0, deaths = 0, killPays = nil }

Env.provide("src/server/Services/DataService", {
	getEquippedSkin = function()
		return SkinCatalog.DEFAULT_SKIN_ID
	end,
	recordKill = function()
		told.kills += 1
	end,
	recordDeath = function()
		told.deaths += 1
	end,
})

Env.provide("src/server/Services/MatchService", {
	markActivity = function(player, shot)
		table.insert(told.activity, { player = player, shot = shot })
	end,
	isInProgress = function()
		return true
	end,
	registerKill = function()
		return told.killPays
	end,
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
	noteDamage = function(victim, shooter, weaponId)
		table.insert(told.noted, { victim = victim, shooter = shooter, weaponId = weaponId })
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
-- A little engine
--
-- Hit resolution is a raycast, and the sandbox has no physics. So the ray is
-- cast here against axis-aligned boxes: enough geometry for bodies, hats and
-- walls, and faithful on the two points that decide who gets hit -- a part with
-- CanQuery off is invisible to it, and it honours the filter list and its type
-- the way the engine does.
--------------------------------------------------------------------------------

local rays: { { origin: any, direction: any } } = {}

local function rayBox(part: any, origin: any, unit: any, reach: number): number?
	local center, half = part.Position, part.Size * 0.5
	local nearest, farthest = 0, reach
	local inside = true

	for _, axis in { "X", "Y", "Z" } do
		local o, d = origin[axis], unit[axis]
		local low, high = center[axis] - half[axis], center[axis] + half[axis]
		if o < low or o > high then
			inside = false
		end
		if math.abs(d) < 1e-9 then
			if o < low or o > high then
				return nil
			end
		else
			local t1, t2 = (low - o) / d, (high - o) / d
			if t1 > t2 then
				t1, t2 = t2, t1
			end
			nearest, farthest = math.max(nearest, t1), math.min(farthest, t2)
			if nearest > farthest then
				return nil
			end
		end
	end

	-- A ray that starts inside a part does not hit it; the engine skips it too.
	if inside then
		return nil
	end
	return nearest
end

local function passesFilter(part: any, params: any): boolean
	local listed = false
	for _, instance in params.FilterDescendantsInstances or {} do
		if part == instance or part:IsDescendantOf(instance) then
			listed = true
			break
		end
	end
	if params.FilterType == roblox.Enum.RaycastFilterType.Include then
		return listed
	end
	return not listed
end

local function castRay(origin: any, direction: any, params: any)
	table.insert(rays, { origin = origin, direction = direction })

	local reach, unit = direction.Magnitude, direction.Unit
	local hitPart, hitAt = nil, math.huge
	for _, instance in world:GetDescendants() do
		if instance:IsA("BasePart") and instance.CanQuery and passesFilter(instance, params) then
			local distance = rayBox(instance, origin, unit, reach)
			if distance and distance < hitAt then
				hitPart, hitAt = instance, distance
			end
		end
	end

	if not hitPart then
		return nil
	end
	return {
		Instance = hitPart,
		Position = origin + unit * hitAt,
		Distance = hitAt,
		Normal = Vector3.new(0, 1, 0),
	}
end

-- Takes everyone off the field, the way a round ending would, so each scene
-- starts with only the people it puts there.
local function clearField()
	for _, player in table.clone(roster) do
		Players.PlayerRemoving:Fire(player)
		if player.Character then
			player.Character:Destroy()
		end
	end
	table.clear(roster)
	for _, instance in world:GetChildren() do
		if instance:IsA("Model") or instance:IsA("BasePart") then
			instance:Destroy()
		end
	end
	table.clear(rays)
	table.clear(pingSeconds)
	clearSent()
end

local function moveTo(character: any, position: any)
	place(character.HumanoidRootPart, position)
	place(character.Head, position + Vector3.new(0, 1.5, 0))
	place(character.UpperTorso, position + Vector3.new(0, 0.2, 0))
end

local function eyeOf(player: any): any
	return player.Character.HumanoidRootPart.Position + Vector3.new(0, 1.5, 0)
end

-- One frame of the game: the clock moves, `update` places whatever moves, and
-- Heartbeat fires -- physics first, then the scripts that read it.
local function frame(dt: number, update: (() -> ())?)
	Env.advance(dt)
	if update then
		update()
	end
	Env.stepHeartbeat(dt)
end

local function frames(seconds: number, update: (() -> ())?)
	local dt = 1 / 60
	local elapsed = 0
	while elapsed < seconds - 1e-9 do
		frame(dt, update)
		elapsed += dt
	end
end

local function lastMessage(name: string, recipient: any)
	for index = #sent, 1, -1 do
		if sent[index].name == name and sent[index].player == recipient then
			return sent[index]
		end
	end
	return nil
end

local function shootAt(player: any, weaponId: string, target: any): boolean
	return shoot(player, weaponId, (target - eyeOf(player)).Unit)
end

--------------------------------------------------------------------------------
-- Shooting at what the shooter saw
--
-- A player fires at what their screen shows, which is other players as they
-- were a round trip and a little interpolation ago. Testing the shot against
-- where targets are by the time it arrives misses everything that moves: at
-- running speed a tenth of a second is nearly two studs, wider than a body.
--------------------------------------------------------------------------------

heading("Lag compensation")

do
	clearField()
	Env.raycastHandler = castRay

	local SPEED = 18
	local shooter = newPlayer("Marksman", "Dust", "A")
	local runner = newPlayer("Runner", "Dust", "B")
	join(shooter)
	join(runner)
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	local runnerBody, runnerHumanoid = spawnPlayer(runner, Vector3.new(-100, 3, -40))
	Env.advance(5)

	local startedAt = Env.virtualTime
	local function runnerX(at: number): number
		return -100 + SPEED * (at - startedAt)
	end
	local function run(seconds: number)
		frames(seconds, function()
			moveTo(runnerBody, Vector3.new(runnerX(Env.virtualTime), 3, -40))
		end)
	end
	-- Long enough between shots for the rifle's spray to settle, so every attempt
	-- is a first shot and only the rewind decides whether it lands.
	local function rest()
		run(0.4)
	end
	-- The runner's head as it was `secondsAgo`, which is what the shooter saw.
	local function headThen(secondsAgo: number): any
		return Vector3.new(runnerX(Env.virtualTime - secondsAgo), 4.5, -40)
	end
	local function landed(): boolean
		return lastMessage("HitConfirmed", shooter) ~= nil
	end
	local function attempt(secondsAgo: number, ping: number): boolean
		pingSeconds[shooter] = ping
		-- A headshot is 44: without this the runner would be dead by the third try.
		runnerHumanoid.Health = 100
		clearSent()
		shootAt(shooter, "Rifle", headThen(secondsAgo))
		return landed()
	end

	run(1)
	check(attempt(0.15, 0.05), "a shot at where the runner was 150 ms ago lands for a shooter with 50 ms of latency")
	local beam = lastMessage("ShotFired", runner)
	check(
		beam ~= nil and math.abs(beam.args[4].X - headThen(0.15).X) < 1,
		"and the beam ends where the shooter saw the runner, not where the runner has run to since"
	)

	rest()
	check(
		not attempt(0.25, 0),
		"the rewind follows the shooter's own latency: with none, an aim 250 ms behind the runner misses"
	)

	rest()
	check(attempt(0.1, 0), "and the interpolation delay alone is enough to hit a target seen 100 ms ago")

	rest()
	check(attempt(0.1, 0 / 0), "a latency reading that is not a number counts as none")

	rest()
	check(not attempt(0, 0.05), "aiming at where the runner is now misses what the shooter would have seen")

	rest()
	check(not attempt(0.5, 0.5), "the rewind is capped: a shooter cannot reach half a second into the past")
	rest()
	check(
		attempt(0.3, 0.5),
		"but the cap itself is honoured, so a bad connection is not left shooting behind everything"
	)

	-- Cover between the shooter and where the runner was seen still stops the shot.
	rest()
	local blocker = newPart(
		"Blocker",
		world,
		headThen(0.15) * Vector3.new(0.25, 0, 0) + Vector3.new(0, 4.5, -10),
		Vector3.new(4, 6, 1)
	)
	check(not attempt(0.15, 0.05), "cover between the shooter and the rewound target stops the shot")
	blocker:Destroy()

	-- A wall the runner has just gone behind. From the shooter's eye the runner
	-- is in the open for x < 0 and covered for x >= 0.
	local wall = newPart("Wall", world, Vector3.new(15, 10, -20), Vector3.new(30, 20, 1))
	while runnerX(Env.virtualTime) < 1 do
		run(1 / 60)
	end
	local okWall = attempt(0.15, 0.05)
	check(okWall, "a runner who stepped behind cover after the shooter saw them in the open is still hit")
	rest()
	check(not attempt(0, 0.05), "and one aimed at where they are behind the wall is not")
	wall:Destroy()

	-- A new life starts a new history. The old one ends nowhere near the spawn.
	run(0.3)
	spawnPlayer(runner, Vector3.new(200, 3, -40))
	frames(2 / 60)
	pingSeconds[shooter] = 0.05
	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(200, 4.5, -40))
	check(landed(), "a player who has just respawned is hit where they stand, not where their last life was")
end

do
	-- A teammate in the way still takes the shot, as before.
	clearField()
	Env.raycastHandler = castRay

	local shooter = newPlayer("Marksman", "Dust", "A")
	local ally = newPlayer("Ally", "Dust", "A")
	local enemy = newPlayer("Enemy", "Dust", "B")
	for _, player in { shooter, ally, enemy } do
		join(player)
	end
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	spawnPlayer(ally, Vector3.new(0, 3, -20))
	local _, enemyHumanoid = spawnPlayer(enemy, Vector3.new(0, 3, -40))
	Env.advance(5)
	frames(0.5)

	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(0, 4.5, -40))
	check(
		enemyHumanoid.Health == 100,
		"a shot that meets a teammate first stops there and does not reach the enemy behind"
	)
	check(lastMessage("HitConfirmed", shooter) == nil, "and confirms no hit")
end

--------------------------------------------------------------------------------
-- Hair, hats and hit boxes
--
-- Accessories are parts, and a ray hits parts. A shot at the head that meets the
-- hair first is a hit on "Handle", which is not the head, so it paid body
-- damage; a wide hat made the head a bigger target than it is.
--------------------------------------------------------------------------------

heading("Accessories")

do
	clearField()
	Env.raycastHandler = castRay

	local function addHair(character: any, size: number, offset: any?): any
		local head = character.Head
		local accessory = roblox.Instance.new("Accessory")
		accessory.Name = "Hair"
		local centre = head.Position + (offset or Vector3.new(0, 0, 0))
		local handle = newPart("Handle", accessory, centre, Vector3.new(size, size, size))
		local weld = roblox.Instance.new("Weld")
		weld.Name = "AccessoryWeld"
		weld.Part0 = head
		weld.Part1 = handle
		weld.Parent = handle
		accessory.Parent = character
		return handle
	end

	local shooter = newPlayer("Marksman", "Dust", "A")
	local victim = newPlayer("Wearer", "Dust", "B")
	join(shooter)
	join(victim)
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	local character = spawnPlayer(victim, Vector3.new(0, 3, -30))
	Env.advance(5)
	frames(0.5)

	-- Accessories arrive after the character, from the asset servers.
	local hair = addHair(character, 1.6)
	Env.instanceEvent(character, "DescendantAdded"):Fire(hair.Parent)
	Env.instanceEvent(character, "DescendantAdded"):Fire(hair)
	check(not hair.CanQuery, "an accessory that arrives after the character cannot be hit")

	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(0, 4.5, -30))
	local hit = lastMessage("HitConfirmed", shooter)
	check(hit ~= nil and hit.args[3] == true, "a shot at the middle of a head that is wearing hair is a headshot")
	check(hit ~= nil and hit.args[2] == 44, `and pays headshot damage (got {hit and hit.args[2]})`)

	Env.advance(1)
	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(0, 5.2, -30))
	check(
		lastMessage("HitConfirmed", shooter) == nil,
		"a shot just over the head, through where the hair stands, misses"
	)

	-- Accessories that were already on the character when the game first saw it.
	local worn = newPlayer("Early", "Dust", "B")
	local wornCharacter = newCharacter(worn, Vector3.new(60, 3, -30))
	local wornHair = addHair(wornCharacter, 1.6)
	join(worn)
	check(not wornHair.CanQuery, "an accessory already on the character is handled too")

	-- The mapping in the resolver is the second line of defence, for a hat that
	-- is somehow still hittable: it counts as the part it is worn on.
	local bare = newPlayer("Bare", "Dust", "B")
	local bareCharacter = newCharacter(bare, Vector3.new(-60, 3, -30))
	local bareHair = addHair(bareCharacter, 1.6)
	check(bareHair.CanQuery, "(this hat was never seen by the hitbox hook)")
	Env.advance(1)
	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(-60, 4.5, -30))
	local mapped = lastMessage("HitConfirmed", shooter)
	check(mapped ~= nil and mapped.args[3] == true, "a hit on a hat worn on the head still counts as a headshot")

	local pack = addHair(bareCharacter, 1.5, Vector3.new(0, -1.3, 0))
	pack.Parent.Name = "Backpack"
	pack:FindFirstChild("AccessoryWeld").Part0 = bareCharacter.UpperTorso
	Env.advance(1)
	clearSent()
	shootAt(shooter, "Rifle", Vector3.new(-60, 3.5, -30))
	local body = lastMessage("HitConfirmed", shooter)
	check(body ~= nil and body.args[3] == false, "and a hit on something worn on the torso counts as a body shot")
end

--------------------------------------------------------------------------------
-- Where a shot comes from
--
-- The character belongs to its client, so its position is only as honest as the
-- client. A shot resolved from wherever the character claims to be lets a
-- modified client jump across the map and fire in the same frame.
--------------------------------------------------------------------------------

heading("Movement limits")

do
	clearField()
	Env.raycastHandler = castRay

	local shooter = newPlayer("Runner", "Dust", "A")
	join(shooter)
	local body = spawnPlayer(shooter, Vector3.new(0, 3, 0))
	-- The server places a character and stamps its spawn protection straight after.
	Env.setAttribute(shooter, "SpawnProtectedUntil", Env.virtualTime + 3)
	Env.advance(5)
	frames(0.5)

	local function magOf(): number
		return WeaponState.get(shooter, "Rifle").mag
	end
	-- Fires as an honest client does: from where its own character is.
	local function fireFromWhereIStand(): boolean
		local before = magOf()
		table.clear(rays)
		shoot(shooter, "Rifle")
		return magOf() < before
	end
	local function leftFrom(place_: any): boolean
		return rays[1] ~= nil and (rays[1].origin - place_).Magnitude < 0.5
	end

	-- Running flat out for three seconds, firing every 0.3 s: every shot counts,
	-- and every shot starts where the player really is.
	local x = 0
	local fired, fromWrongPlace = 0, 0
	for _ = 1, 10 do
		frames(0.3, function()
			x += 18 / 60
			moveTo(body, Vector3.new(x, 3, 0))
		end)
		if fireFromWhereIStand() then
			fired += 1
			if not leftFrom(eyeOf(shooter)) then
				fromWrongPlace += 1
			end
		end
	end
	check(fired == 10, `a player running at full speed is never refused ({fired}/10 shots)`)
	check(fromWrongPlace == 0, `and every shot leaves from where they are ({fromWrongPlace} did not)`)

	-- A connection that stalls for a second and a half, then delivers all of it.
	Env.advance(3)
	frames(1.5)
	x += 27
	moveTo(body, Vector3.new(x, 3, 0))
	frames(1 / 60)
	check(fireFromWhereIStand(), "a phone that freezes for a second and a half and then catches up is not refused")
	check(leftFrom(eyeOf(shooter)), "and its shot leaves from where it caught up to")

	-- Now a jump across the map, and a shot in the same instant.
	Env.advance(3)
	frames(1)
	moveTo(body, Vector3.new(x + 150, 3, 0))
	frames(1 / 60)
	check(not fireFromWhereIStand(), "a shot fired in the same frame as a 150-stud jump is refused")

	-- The server's picture of the player walks after them at a legal speed and
	-- gets there; from then on they are exactly as before.
	frames(2)
	check(not fireFromWhereIStand(), "two seconds later it has still not covered that distance")
	frames(2)
	check(fireFromWhereIStand(), "and once it has, shots resume")
	check(leftFrom(eyeOf(shooter)), "from the new position")
end

do
	-- A new life: LoadCharacter puts the character at the default spawn, PivotTo
	-- then moves it to the team's room, and the server stamps spawn protection
	-- straight after -- which is when that place becomes the reference point.
	clearField()
	Env.raycastHandler = castRay

	local shooter = newPlayer("Newcomer", "Dust", "A")
	join(shooter)
	local body = spawnPlayer(shooter, Vector3.new(0, 3, 0))
	Env.advance(5)
	frames(0.5)

	moveTo(body, Vector3.new(400, 3, 0))
	Env.setAttribute(shooter, "SpawnProtectedUntil", Env.virtualTime + 3)
	frames(2 / 60)

	table.clear(rays)
	shoot(shooter, "Rifle")
	check(
		WeaponState.get(shooter, "Rifle").mag == WeaponConfig.Weapons.Rifle.magSize - 1,
		"a player placed at their spawn can fire from it at once"
	)
	check(
		rays[1] ~= nil and (rays[1].origin - eyeOf(shooter)).Magnitude < 0.5,
		"and the shot leaves from the spawn, not from wherever the character was created"
	)

	-- Until the server has said it placed a character, there is nothing to hold
	-- it to, and it is taken as it stands: never worse than not having the rule.
	local drifter = newPlayer("Unplaced", "Dust", "A")
	join(drifter)
	local drifterBody = spawnPlayer(drifter, Vector3.new(0, 3, 50))
	Env.advance(5)
	frames(0.5)
	moveTo(drifterBody, Vector3.new(-400, 3, 50))
	frames(2 / 60)
	shoot(drifter, "Rifle")
	check(
		WeaponState.get(drifter, "Rifle").mag == WeaponConfig.Weapons.Rifle.magSize - 1,
		"a character the server has not placed is shot from where it stands"
	)
end

--------------------------------------------------------------------------------
-- What the match is told
--
-- Three things the match needs from combat and cannot see for itself: who hurt
-- whom (so a reset or a fall after a hit is still blamed on the shooter),
-- whether a kill pays (so two accounts cannot feed each other), and what a shot
-- showed (so a held trigger does not count as being present).
--------------------------------------------------------------------------------

heading("What the match is told")

do
	clearField()
	Env.raycastHandler = castRay

	local shooter = newPlayer("Reporter", "Dust", "A")
	local target = newPlayer("Reported", "Dust", "B")
	join(shooter)
	join(target)
	spawnPlayer(shooter, Vector3.new(0, 3, 0))
	local _, targetHumanoid = spawnPlayer(target, Vector3.new(0, 3, -30))
	Env.advance(5)
	frames(0.5)

	local function fresh()
		table.clear(told.activity)
		table.clear(told.noted)
		told.kills, told.deaths = 0, 0
		clearSent()
		Env.advance(1)
	end

	-- A round into the empty air.
	fresh()
	shoot(shooter, "Rifle", Vector3.new(1, 0, 0))
	local missed = told.activity[#told.activity]
	check(missed ~= nil, "a shot that hits nothing is still reported to the match")
	check(missed ~= nil and missed.shot ~= nil and missed.shot.damaged == false, "and reported as having hurt nobody")
	check(
		missed ~= nil and missed.shot ~= nil and missed.shot.sprayIndex == 1,
		"with the place it holds in the burst, so the match can tell a burst's first round"
	)
	check(
		missed ~= nil and missed.shot ~= nil and missed.shot.direction == Vector3.new(1, 0, 0),
		"and where it was aimed, so a burst pointed the same way as the last can be recognised"
	)
	check(#told.noted == 0, "nobody is blamed for a round that hit nothing")

	-- A hit.
	fresh()
	shootAt(shooter, "Rifle", Vector3.new(0, 3.2, -30))
	local hit = told.activity[#told.activity]
	check(
		hit ~= nil and hit.shot ~= nil and hit.shot.damaged == true,
		"a shot that hurts someone is reported as having done so"
	)
	check(#told.noted == 1, "and the hit is recorded against its victim")
	check(
		told.noted[1] ~= nil
			and told.noted[1].victim == target
			and told.noted[1].shooter == shooter
			and told.noted[1].weaponId == "Rifle",
		"naming who shot whom with what, so a reset a second later is the shooter's kill"
	)

	-- A kill the match is happy to pay for, and one it is not.
	fresh()
	told.killPays = nil
	targetHumanoid.Health = 1
	shootAt(shooter, "Rifle", Vector3.new(0, 3.2, -30))
	check(told.kills == 1, "a kill nobody objects to is paid for")
	check(told.deaths == 1, "and the death is recorded either way")

	fresh()
	told.killPays = true
	targetHumanoid.Health = 1
	shootAt(shooter, "Rifle", Vector3.new(0, 3.2, -30))
	check(told.kills == 1, "a kill the match says pays is paid for")

	fresh()
	told.killPays = false
	targetHumanoid.Health = 1
	shootAt(shooter, "Rifle", Vector3.new(0, 3.2, -30))
	check(told.kills == 0, "a kill the match says has been traded too often pays nothing")
	check(told.deaths == 1, "but the victim still dies and is counted dead")
	told.killPays = nil
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
