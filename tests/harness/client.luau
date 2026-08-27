--!nonstrict
--[[
	tests/harness/client.luau
	Loads every client module and runs the controllers' lifecycle.

	Client code is the half of this game that no other check reaches. The unit
	tests cover pure modules, the world and model harnesses cover the two big
	Instance builders, and all of that is server-side. Meanwhile the client owns
	everything the player actually feels — input, camera, recoil, the HUD — and
	a typo there means a client that boots into a black screen.

	Nothing is rendered here, so this proves the modules evaluate, expose the
	lifecycle the loader expects, and survive init() and start() without a
	running game. It does not prove anything looks right; only a playtest can.

	Run:  lune run tests/harness/client
]]

local Env = require("./env")
local fs = require("@lune/fs")
-- The sandbox hands `Instance` to the modules it loads, not to this file, so a
-- check that needs to construct one takes it from the same place the sandbox
-- does.
local roblox = require("@lune/roblox")

-- Client code lives on the runtime side of Roblox — cameras, viewports, signals
-- — which Lune's data model does not carry. This swaps in stand-ins for those
-- before anything is required.
Env.enableClientRuntime()

local passed = 0
local failed = 0
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
-- Collect
--------------------------------------------------------------------------------

local SKIP = {
	-- The bootstrap: requiring it would start the whole client.
	["src/client/init.client"] = true,
}

local function collect(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collect(full, out)
		elseif entry:match("%.luau$") then
			table.insert(out, (full:gsub("%.luau$", "")))
		end
	end
	return out
end

local modules = collect("src/client", {})
table.sort(modules)

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------

heading(`Loading {#modules} client modules`)

local loadedModules: { { path: string, value: any } } = {}

for _, path in modules do
	if SKIP[path] then
		print(`  skip  {path}`)
		continue
	end

	local ok, result = pcall(function()
		return Env.load(path)
	end)

	check(ok, `{path} loads{if ok then "" else ": " .. tostring(result)}`)
	if ok and type(result) == "table" then
		table.insert(loadedModules, { path = path, value = result })
	end
end

print(`  {#loadedModules} modules returned a table`)

--------------------------------------------------------------------------------
-- Lifecycle contract
--
-- The loader calls init() on everything, then start(). A controller that names
-- one of them something else is silently never run.
--------------------------------------------------------------------------------

heading("Lifecycle")

local withInit = 0
local withStart = 0

for _, entry in loadedModules do
	local module = entry.value

	if module.Priority ~= nil then
		check(type(module.Priority) == "number", `{entry.path} Priority is a number`)
	end

	if type(module.init) == "function" then
		withInit += 1
	end
	if type(module.start) == "function" then
		withStart += 1
	end
end

print(`  {withInit} modules define init(), {withStart} define start()`)

--------------------------------------------------------------------------------
-- Run init() and start()
--
-- This is where a nil index or a missing service surfaces. Each call is isolated
-- so one broken controller does not hide the rest.
--------------------------------------------------------------------------------

heading("Running init()")

for _, entry in loadedModules do
	local module = entry.value
	if type(module.init) ~= "function" then
		continue
	end

	local ok, err = pcall(module.init)
	check(ok, `{entry.path}.init(){if ok then "" else " -> " .. tostring(err)}`)
end

heading("Running start()")

for _, entry in loadedModules do
	local module = entry.value
	if type(module.start) ~= "function" then
		continue
	end

	local ok, err = pcall(module.start)
	check(ok, `{entry.path}.start(){if ok then "" else " -> " .. tostring(err)}`)
end

--------------------------------------------------------------------------------
-- Every weapon must make a noise
--
-- A missing sound key returns silently, so a weapon added without one simply
-- fires without a sound and nothing anywhere complains. That is exactly the
-- kind of gap that survives to production, so it is asserted rather than left
-- to be noticed.
--------------------------------------------------------------------------------

heading("Weapon sounds")

local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
local VFXSound = Env.load("src/client/Controllers/VFX/VFXSound")

for _, weaponId in WeaponConfig.Order do
	check(VFXSound.has(weaponId), `{weaponId} has a firing sound`)
end

-- Every sound must be a real uploaded asset. An engine-local `rbxasset://`
-- path is a development placeholder and a malformed id loads as silence, and
-- neither announces itself — the game simply goes quiet in one place.
local SOUND_KEYS = { "Impact", "Hitmarker", "Kill", "Reload", "Equip", "Empty", "Hurt" }
for _, weaponId in WeaponConfig.Order do
	table.insert(SOUND_KEYS, weaponId)
end

for _, key in SOUND_KEYS do
	local id = VFXSound.soundId(key)
	check(id ~= nil, `{key} has a sound id`)
	if id then
		check(id:match("^rbxassetid://%d+$") ~= nil, `{key} points at an uploaded asset (got "{id}")`)
	end
end

--------------------------------------------------------------------------------
-- Settings reach the things they configure
--
-- Each setting is a number stored on a profile that has to end up written onto
-- some engine property. A value that is stored, replicated and never applied
-- looks completely healthy from every side except the player's.
--------------------------------------------------------------------------------

heading("Settings")

local SettingsConfig = Env.load("src/shared/Config/SettingsConfig")
local SettingsController = Env.load("src/client/Controllers/SettingsController")
local ClientStateModule = Env.load("src/client/ClientState")

check(type(SettingsController.apply) == "function", "SettingsController exposes apply()")

-- Push a value that is nowhere near any default, so a property that merely
-- happens to hold the right number cannot pass by luck.
local PROBE = { Sensitivity = 2.5, Volume = 0.25, FieldOfView = 95 }
local applyOk, applyErr = pcall(SettingsController.apply, PROBE)
check(applyOk, `applying settings does not error{if applyOk then "" else ": " .. tostring(applyErr)}`)

if applyOk then
	local CameraControllerModule = Env.load("src/client/Controllers/CameraController")
	check(
		CameraControllerModule.getFieldOfView() == PROBE.FieldOfView,
		`field of view reaches the camera (got {CameraControllerModule.getFieldOfView()})`
	)

	local group = VFXSound.getGroup()
	check(group ~= nil, "the sound group exists after start()")
	if group then
		check(group.Volume == PROBE.Volume, `volume reaches the sound group (got {group.Volume})`)
	end
end

-- ClientState must hold a complete settings table from the very first frame:
-- the sliders are built before any profile arrives.
check(type(ClientStateModule.settings) == "table", "ClientState starts with a settings table")
check(SettingsConfig.sanitize(ClientStateModule.settings) ~= nil, "the starting settings sanitise cleanly")
for _, definition in SettingsConfig.Definitions do
	check(
		type(ClientStateModule.settings[definition.id]) == "number",
		`ClientState has a starting value for {definition.id}`
	)
end

--------------------------------------------------------------------------------
-- The welcome card shows to new players and nobody else
--
-- An onboarding card that reopens for a returning player is worse than no card
-- at all: it becomes a door to close on every join. The gate is one comparison
-- against a stat, which is exactly the kind of thing that looks right and is
-- inverted.
--------------------------------------------------------------------------------

heading("Welcome card")

local UIControllerModule = Env.load("src/client/UI/UIController")
local WelcomeScreen = Env.load("src/client/UI/Screens/WelcomeScreen")

check(type(WelcomeScreen.open) == "function", "the welcome card can be reopened from settings")

-- Veteran first: a successful open latches the once-per-session flag, so
-- checking the other order would prove nothing.
ClientStateModule.stats = { MatchesPlayed = 5 }
ClientStateModule.ProfileChanged:Fire({ stats = ClientStateModule.stats })
check(not UIControllerModule.isMenuOpen("Welcome"), "a player who has played is not shown the card")

ClientStateModule.stats = { MatchesPlayed = 0 }
ClientStateModule.ProfileChanged:Fire({ stats = ClientStateModule.stats })
check(UIControllerModule.isMenuOpen("Welcome"), "a player who has never played is shown the card")

-- ...and only once, however many times the profile lands.
UIControllerModule.closeMenu("Welcome")
ClientStateModule.ProfileChanged:Fire({ stats = ClientStateModule.stats })
check(not UIControllerModule.isMenuOpen("Welcome"), "the card does not reopen on a second profile push")

--------------------------------------------------------------------------------
-- Shared UI helpers
--
-- A screen only builds its widgets when the player opens it, so a helper that
-- one screen borrows from another is never touched by init() or start(). If it
-- is missing the game boots perfectly and then errors the first time somebody
-- presses SHOP — which is precisely the kind of failure a load-time harness
-- would otherwise wave through.
--------------------------------------------------------------------------------

heading("Shared UI helpers")

local CurrencyLabel = Env.load("src/client/UI/Components/CurrencyLabel")

check(type(CurrencyLabel.format) == "function", "CurrencyLabel exposes format() for other screens")
if type(CurrencyLabel.format) == "function" then
	-- Prices reach five digits, which is where an unformatted number starts
	-- reading as a different currency to the grouped balance beside it.
	check(CurrencyLabel.format(48000) == "48,000", `format groups thousands (got "{CurrencyLabel.format(48000)}")`)
	check(CurrencyLabel.format(600) == "600", `format leaves short numbers alone (got "{CurrencyLabel.format(600)}")`)
end

-- The HUD is the one screen whose widgets a player never opens deliberately —
-- it appears when a match starts — so nothing else here would build it. Doing
-- so proves the whole widget tree constructs, and that HUDScreen's reads of it
-- have something to read.
-- The slider is the newest component and the only one with a drag model, so it
-- is built here rather than trusted to have been built by a screen that may
-- have bailed out early.
local Slider = Env.load("src/client/UI/Components/Slider")
local sliderOk, slider = pcall(function()
	return Slider.create({
		settingId = "Sensitivity",
		value = 1,
		parent = roblox.Instance.new("ScreenGui"),
	})
end)

check(sliderOk, `a slider builds{if sliderOk then "" else ": " .. tostring(slider)}`)
if sliderOk then
	check(slider:getValue() == 1, `the slider starts on its given value (got {slider:getValue()})`)

	-- setValue must move the knob without pretending the player dragged it.
	local notified = false
	slider._onChanged = function()
		notified = true
	end
	slider:setValue(2)
	check(slider:getValue() == 2, `setValue moves the slider (got {slider:getValue()})`)
	check(not notified, "setValue does not fire onChanged")

	-- Out-of-range input is the normal case: a drag that leaves the track sends
	-- positions past both ends.
	slider:setValue(999)
	check(slider:getValue() == SettingsConfig.get("Sensitivity").max, "setValue clamps above the range")
	slider:setValue(-999)
	check(slider:getValue() == SettingsConfig.get("Sensitivity").min, "setValue clamps below the range")

	slider:destroy()
end

local HUDWidgets = Env.load("src/client/UI/Screens/HUDWidgets")
local hudOk, hud = pcall(function()
	local screen = roblox.Instance.new("ScreenGui")
	return HUDWidgets.build(screen, function() end)
end)

check(hudOk, `the HUD widget tree builds{if hudOk then "" else ": " .. tostring(hud)}`)
if hudOk then
	for _, name in { "timer", "scoreTarget", "healthFill", "ammoMag", "crosshair" } do
		check(hud[name] ~= nil, `HUD exposes {name}`)
	end
	check(hud.scores and hud.scores.A ~= nil and hud.scores.B ~= nil, "HUD exposes a score chip per team")
	-- The kill target starts hidden: there is no match, so there is no target,
	-- and "FIRST TO 0" is worse than nothing.
	check(hud.scoreTarget and hud.scoreTarget.Visible == false, "the kill target is hidden until a match runs")
end

--------------------------------------------------------------------------------
-- What the run left behind
--------------------------------------------------------------------------------

heading("After start()")

local bindings = {}
for name in Env.renderBindings do
	table.insert(bindings, name)
end
table.sort(bindings)
if #bindings > 0 then
	print("  render bindings: " .. table.concat(bindings, ", "))
end

local calls = Env.calls()
local summary = {}
for name, count in calls do
	table.insert(summary, `{name}={count}`)
end
table.sort(summary)
if #summary > 0 then
	print("  sandbox calls: " .. table.concat(summary, "  "))
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")
print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} client check(s) failed`, 0)
end

print("  All client checks passed.")
