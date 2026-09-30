--!nonstrict
--[[
	tests/harness/weapon.luau
	Runs the client's real firing loop on a virtual clock.

	WeaponClient is timing all the way down: when the next shot is due, when a
	reload ends, which server sync may overwrite a prediction. None of that shows
	in a unit test of pure maths, and all of it is felt the moment someone holds
	the trigger. Here the frames come from Env.advance / Env.stepHeartbeat, so a
	phone at 30 fps and a monitor at 240 run the same loop for the same virtual
	seconds and the shots they send can be compared exactly.

	The controllers WeaponClient drives (input, recoil, sound, the viewmodel)
	are replaced by recorders; ClientState is a stand-in that keeps what the
	firing loop reads and hands back the remotes it sends on.

	Run:  lune run tests/harness/weapon
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
-- Stand-ins
--------------------------------------------------------------------------------

-- What the client sent, with the moment it sent it.
local sentShots: { { at: number, weaponId: string, seq: number } } = {}
local sentReloads: { number } = {}
local sentEquips: { number } = {}

local function fakeRemote(name: string)
	return {
		Name = name,
		FireServer = function(_self, ...)
			local args = table.pack(...)
			if name == "ShootRequest" then
				table.insert(sentShots, { at = Env.virtualTime, weaponId = args[1], seq = args[2] })
			elseif name == "ReloadRequest" then
				table.insert(sentReloads, Env.virtualTime)
			elseif name == "EquipWeaponRequest" then
				table.insert(sentEquips, args[1])
			end
		end,
	}
end

local ClientState = {
	isDead = false,
	match = { phase = "InProgress" },
	ammo = nil,
	AmmoChanged = Env.liveSignal(),
	SlotChanged = Env.liveSignal(),
	Died = Env.liveSignal(),
	Respawned = Env.liveSignal(),
}
function ClientState.init() end
function ClientState.isInMatch()
	return true
end
function ClientState.getRemote(name: string)
	return fakeRemote(name)
end
Env.provide("src/client/ClientState", ClientState)

local held = false
local InputController = {
	FirePressed = Env.liveSignal(),
	ReloadPressed = Env.liveSignal(),
	SlotPressed = Env.liveSignal(),
}
function InputController.isFireHeld()
	return held
end
Env.provide("src/client/Controllers/InputController", InputController)

Env.provide("src/client/Controllers/RecoilController", {
	onShot = function()
		return 1
	end,
	resetSpray = function() end,
})

Env.provide("src/client/UI/UIController", {
	isAnyMenuOpen = function()
		return false
	end,
})

local noop = setmetatable({}, {
	__index = function()
		return function() end
	end,
})
Env.provide("src/client/Controllers/VFXController", noop)
Env.provide("src/client/Controllers/ViewmodelController", noop)

local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
local WeaponClient = Env.load("src/client/Controllers/WeaponClient")

local localPlayer = Env.service("Players").LocalPlayer

-- A living character, so the gun may be used at all.
do
	local character = roblox.Instance.new("Model")
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = character
	local head = roblox.Instance.new("Part")
	head.Name = "Head"
	head.Position = roblox.Vector3.new(0, 4.5, 0)
	head.CFrame = roblox.CFrame.new(0, 4.5, 0)
	head.Parent = character
	localPlayer.Character = character
end

localPlayer:SetAttribute("InMatch", "Dust")
localPlayer:SetAttribute("CurrentWeapon", "Rifle")

WeaponClient.init()
WeaponClient.start()

-- One frame of the game: the clock moves, then Heartbeat fires.
local function frame(dt: number)
	Env.advance(dt)
	Env.stepHeartbeat(dt)
end

local function idle(seconds: number)
	local step = 1 / 60
	local elapsed = 0
	while elapsed < seconds do
		frame(step)
		elapsed += step
	end
end

local function freshLife()
	ClientState.Respawned:Fire()
	table.clear(sentShots)
	table.clear(sentReloads)
end

-- Deterministic jitter in [-1, 1].
local function jitterSource(seed: number)
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return (state / 2147483648) * 2 - 1
	end
end

-- What the server would send for the client's weapon: (weaponId, mag, magSize,
-- reloading, ackSeq), as ClientState.onAmmoSync turns it into a table.
local function serverSync(weaponId: string, mag: number, reloading: boolean, ackSeq: number)
	ClientState.ammo = {
		weaponId = weaponId,
		mag = mag,
		magSize = WeaponConfig.Weapons[weaponId].magSize,
		reloading = reloading,
		ackSeq = ackSeq,
	}
	ClientState.AmmoChanged:Fire(ClientState.ammo)
end

--------------------------------------------------------------------------------
-- Holding the trigger
--
-- Shots leave on Heartbeat, so a frame is the smallest step a schedule can
-- move in. Waiting for the first frame at or after the interval loses the
-- remainder of every frame, and at 30 fps that remainder is a third of an
-- interval: the rifle fired about a quarter slower on a phone than on a PC.
-- What the trigger is owed is the weapon's rate, whatever the frame rate.
--------------------------------------------------------------------------------

heading("Held trigger, by frame rate")

do
	local rifle = WeaponConfig.Weapons.Rifle
	-- Never faster than the server's own floor allows. The server tolerates 40 ms
	-- early; the client's carry is a fraction of that.
	local MAX_CARRY = 0.012

	for _, fps in { 30, 45, 60, 120, 240 } do
		for _, jittered in { false, true } do
			freshLife()
			idle(0.5)
			table.clear(sentShots)

			local jitter = jitterSource(fps)
			held = true
			local startedAt = Env.virtualTime
			-- One magazine: the rifle reloads by itself when it empties, and this is
			-- about the sustained rate, not the reload.
			while #sentShots < rifle.magSize and Env.virtualTime - startedAt < 10 do
				local dt = 1 / fps
				if jittered then
					dt *= 1 + 0.25 * jitter()
				end
				frame(dt)
			end
			held = false

			local label = `{fps} fps{if jittered then " with uneven frames" else ""}`
			check(#sentShots == rifle.magSize, `{label}: the whole magazine is fired ({#sentShots} shots)`)

			if #sentShots == rifle.magSize then
				local span = sentShots[#sentShots].at - sentShots[1].at
				local rpm = (#sentShots - 1) / span * 60
				-- Frames of very different lengths lose the part of a late frame that
				-- the carry does not cover, so they get a wider floor; it used to be
				-- 15-25% short.
				local slowest = if jittered then 570 else 588
				check(
					rpm >= slowest and rpm <= 606,
					`{label}: sustained rate is the weapon's 600 RPM (got {string.format("%.0f", rpm)})`
				)

				local shortest = math.huge
				for index = 2, #sentShots do
					shortest = math.min(shortest, sentShots[index].at - sentShots[index - 1].at)
				end
				check(
					shortest >= rifle.fireRate - MAX_CARRY - 1e-6,
					`{label}: no two shots closer than the carry allows (shortest {string.format(
						"%.1f",
						shortest * 1000
					)} ms)`
				)
			end

			idle(3)
		end
	end
end

heading("A tap after a pause")

do
	local pistol = WeaponConfig.Weapons.Pistol
	freshLife()
	localPlayer:SetAttribute("CurrentWeapon", "Pistol")
	ClientState.SlotChanged:Fire(2, "Pistol")
	idle(1)
	table.clear(sentShots)

	-- Semi-automatic: one shot per press. Two presses closer than the interval
	-- are one shot; a press a full interval after the first is a second.
	InputController.FirePressed:Fire()
	idle(pistol.fireRate * 0.5)
	InputController.FirePressed:Fire()
	check(#sentShots == 1, "a second press inside the interval is ignored")
	idle(pistol.fireRate * 0.6)
	InputController.FirePressed:Fire()
	check(#sentShots == 2, "and one past it fires")

	-- After a real pause the schedule starts clean: no head start carried over.
	idle(3)
	InputController.FirePressed:Fire()
	idle(pistol.fireRate - 0.02)
	InputController.FirePressed:Fire()
	check(#sentShots == 3, "a press 20 ms short of the interval, after a pause, is still ignored")
	localPlayer:SetAttribute("CurrentWeapon", "Rifle")
	ClientState.SlotChanged:Fire(1, "Rifle")
	idle(1)
end

--------------------------------------------------------------------------------
-- The last round and the reload that follows
--
-- The rifle reloads by itself when its magazine empties. The server, though, is
-- still working through the shots that got the client there, and each one it
-- processes sends a sync saying "not reloading" -- true when it was sent. Taken
-- at face value they cancel the reload the client just started, and the HUD
-- flickers reload, empty, reload as the server catches up.
--------------------------------------------------------------------------------

heading("Syncs from shots still in flight")

do
	local rifle = WeaponConfig.Weapons.Rifle
	freshLife()
	idle(0.5)

	held = true
	local guard = 0
	while #sentShots < rifle.magSize and guard < 600 do
		frame(1 / 60)
		guard += 1
	end
	held = false

	local lastSeq = sentShots[#sentShots].seq
	local mag, _, reloading = WeaponClient.getAmmo("Rifle")
	check(mag == 0 and reloading, "emptying the magazine starts a reload by itself")

	-- The server has handled the shot before the last one, and nothing since.
	serverSync("Rifle", 1, false, lastSeq - 1)
	local _, _, stillReloading = WeaponClient.getAmmo("Rifle")
	check(stillReloading, "a sync sent before the last shot arrived does not cancel the reload")

	-- Now the last shot too, but not yet the reload request behind it.
	serverSync("Rifle", 0, false, lastSeq)
	_, _, stillReloading = WeaponClient.getAmmo("Rifle")
	check(stillReloading, "nor does the sync for the last shot, which was sent before the reload request was read")

	-- The server has the request: reloading, then done.
	serverSync("Rifle", 0, true, lastSeq)
	idle(rifle.reloadTime + 0.1)
	serverSync("Rifle", rifle.magSize, false, lastSeq)
	mag, _, reloading = WeaponClient.getAmmo("Rifle")
	check(mag == rifle.magSize and not reloading, "the completion sync ends it with a full magazine")

	-- Outside a reload the server's word is still taken.
	held = false
	InputController.FirePressed:Fire()
	idle(0.2)
	serverSync("Rifle", rifle.magSize - 5, false, sentShots[#sentShots].seq)
	mag = WeaponClient.getAmmo("Rifle")
	check(mag == rifle.magSize - 5, "a lower count from the server is still adopted when nothing is reloading")
end

--------------------------------------------------------------------------------
-- How long a reload takes
--
-- The client starts its reload the moment the key goes down; the server hears
-- about it a trip later and answers with a sync. That sync says "reloading",
-- not how much is left, and treating it as a fresh start pushed the client's
-- own deadline back by a whole round trip: on a 200 ms connection every reload
-- felt 200 ms longer than the weapon's reload time.
--------------------------------------------------------------------------------

heading("Reload duration")

do
	local pistol = WeaponConfig.Weapons.Pistol
	freshLife()
	localPlayer:SetAttribute("CurrentWeapon", "Pistol")
	ClientState.SlotChanged:Fire(2, "Pistol")
	idle(1)
	table.clear(sentShots)

	InputController.FirePressed:Fire()
	idle(0.4)

	local startedAt = Env.virtualTime
	InputController.ReloadPressed:Fire()
	local _, _, reloading = WeaponClient.getAmmo("Pistol")
	check(reloading, "the reload starts on the key press")

	-- The server's answer, a round trip later.
	idle(0.2)
	serverSync("Pistol", pistol.magSize - 1, true, sentShots[#sentShots].seq)

	while Env.virtualTime - startedAt < pistol.reloadTime + 0.05 do
		frame(1 / 60)
	end
	local mag
	mag, _, reloading = WeaponClient.getAmmo("Pistol")
	check(
		not reloading and mag == pistol.magSize,
		"the reload ends on the weapon's reload time, not a round trip later"
	)

	-- A reload the client did not start (the server's word on its own) still
	-- runs for the full time from when it is heard of.
	InputController.FirePressed:Fire()
	idle(0.4)
	serverSync("Pistol", pistol.magSize - 1, true, sentShots[#sentShots].seq)
	_, _, reloading = WeaponClient.getAmmo("Pistol")
	check(reloading, "a reload announced by the server shows as reloading")
	idle(pistol.reloadTime - 0.1)
	_, _, reloading = WeaponClient.getAmmo("Pistol")
	check(reloading, "and lasts the weapon's reload time from then")
	idle(0.3)
	_, _, reloading = WeaponClient.getAmmo("Pistol")
	check(not reloading, "and then ends")

	localPlayer:SetAttribute("CurrentWeapon", "Rifle")
	ClientState.SlotChanged:Fire(1, "Rifle")
	idle(1)
end

--------------------------------------------------------------------------------
-- The swap lockout is the config's
--------------------------------------------------------------------------------

heading("Weapon swap lockout")

do
	freshLife()
	idle(1)

	local original = WeaponConfig.SWITCH_TIME
	WeaponConfig.SWITCH_TIME = 0.8
	WeaponClient.equipSlot(2)
	check(sentEquips[#sentEquips] == 2, "the swap is announced to the server with its slot")
	idle(0.5)
	check(not WeaponClient.canFire(), "the client's lockout follows WeaponConfig.SWITCH_TIME")
	idle(0.4)
	check(WeaponClient.canFire(), "and ends when it does")
	WeaponConfig.SWITCH_TIME = original

	localPlayer:SetAttribute("CurrentWeapon", "Pistol")
	ClientState.SlotChanged:Fire(2, "Pistol")
	idle(1)
	WeaponClient.equipSlot(1)
	idle(1)
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
	error(`{failed} weapon check(s) failed`, 0)
end

print("  All weapon checks passed.")
