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
-- The notice banner
--
-- It is the only way the server explains an idle removal, and it fires from a
-- remote that nothing else in this harness triggers. A banner stuck visible
-- would sit over the game; one that never appears would make being pulled out
-- of a match look arbitrary.
--------------------------------------------------------------------------------

heading("Notice banner")

local NoticeScreen = Env.load("src/client/UI/Screens/NoticeScreen")

check(type(NoticeScreen.show) == "function", "NoticeScreen exposes show()")

local bannerOk, bannerErr = pcall(NoticeScreen.show, "Returned to the hub", "error")
check(bannerOk, `showing a notice does not error{if bannerOk then "" else ": " .. tostring(bannerErr)}`)

-- An empty or non-string message must be ignored rather than rendered as a
-- blank bar the player cannot explain.
check(pcall(NoticeScreen.show, "", "info"), "an empty notice is ignored without erroring")
check(pcall(NoticeScreen.show, nil, "info"), "a nil notice is ignored without erroring")
check(pcall(NoticeScreen.show, "Unknown severity", "not-a-severity"), "an unknown severity falls back")

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
-- The cursor
--
-- The bug this section exists for looked exactly like working code: with a
-- panel open the client set MouseBehavior to Default and MouseIconEnabled to
-- true, and a harness that asked the client what it wanted was green while the
-- player could not move the mouse at all.
--
-- The reason is that Roblox's own camera module writes LockCenter every frame
-- while it believes the camera is first person, which the pinned 0.5 zoom makes
-- permanent. So the only assertion worth making is the one after a frame has
-- passed: the adversary writes LockCenter, the frame runs, and the cursor has
-- to still be free at the end of it.
--------------------------------------------------------------------------------

heading("The cursor")

local UserInputServiceStub = Env.service("UserInputService")
local MouseLock = Env.load("src/client/Controllers/MouseLockController")
local UIControllerModule = Env.load("src/client/UI/UIController")

--[[
	Stands in for CameraModule:Update, which is bound at
	Enum.RenderPriority.Camera and takes the cursor on every rendered frame.
	Registered at exactly that priority so Env.stepRender() runs it in the real
	order relative to the client's own binding.
]]
Env.service("RunService"):BindToRenderStep("HarnessPlayerModule", 200, function()
	UserInputServiceStub.MouseBehavior = roblox.Enum.MouseBehavior.LockCenter
	UserInputServiceStub.MouseIconEnabled = false
end)

check(MouseLock.isEnabled(), "the cursor manager runs on a mouse-and-keyboard client")
check(not MouseLock.isUnlocked(), "the cursor starts captured, with no menu open")

Env.stepRender()
check(
	UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.LockCenter,
	"during play the cursor stays captured across a frame"
)

for _, name in { "Shop", "Spin", "Equip", "Settings", "Friends" } do
	UIControllerModule.openMenu(name)

	check(UIControllerModule.isMenuOpen(name), `{name} registered itself and opens through UIController`)
	check(MouseLock.isUnlocked(), `{name} frees the cursor`)
	check(
		UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.Default,
		`{name} asks for a free cursor (got {UserInputServiceStub.MouseBehavior})`
	)

	-- THE CHECK THAT MATTERS. Everything above passed while the bug was live.
	Env.stepRender()
	check(
		UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.Default,
		`{name} keeps the cursor free after the camera module has run (got {UserInputServiceStub.MouseBehavior})`
	)
	check(UserInputServiceStub.MouseIconEnabled == true, `{name} keeps a cursor drawn to click with`)

	UIControllerModule.closeMenu(name)
	check(not MouseLock.isUnlocked(), `closing {name} recaptures the cursor`)

	Env.stepRender()
	check(
		UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.LockCenter,
		`closing {name} leaves the cursor captured across a frame`
	)
end

-- Switching straight between two panels must never pass through a captured
-- cursor: the player is mid-click and the pointer would jump to screen centre.
UIControllerModule.openMenu("Shop")
UIControllerModule.openMenu("Spin")
check(UIControllerModule.isMenuOpen("Spin"), "opening a second panel switches to it")
check(not UIControllerModule.isMenuOpen("Shop"), "opening a second panel closes the first")
check(MouseLock.isUnlocked(), "switching panels never recaptures the cursor")
Env.stepRender()
check(
	UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.Default,
	"the cursor survives a panel switch and a frame"
)
UIControllerModule.closeMenu("Spin")

-- The camera is never taken out of first person to achieve any of this: doing
-- so would dolly the view out of the player's head every time a panel opened.
check(
	Env.service("Players").LocalPlayer.CameraMode == roblox.Enum.CameraMode.LockFirstPerson,
	"the camera stays first person throughout"
)

-- The wheel is the one widget whose correctness is geometric: it has to paint
-- each segment across its true share of the circle. Nothing else checks that,
-- and a wheel that draws a 30% prize across 43 degrees looks like a bug in the
-- odds rather than in the drawing.
local SpinWheel = Env.load("src/client/UI/Screens/SpinWheel")
local SpinConfig = Env.load("src/shared/Config/SpinConfig")

local wheelOk, wheel = pcall(function()
	return SpinWheel.create(roblox.Instance.new("ScreenGui"))
end)

check(wheelOk, `the reward wheel builds{if wheelOk then "" else ": " .. tostring(wheel)}`)
if wheelOk then
	local rotor = wheel.instance:FindFirstChild("Rotor")
	check(rotor ~= nil, "the wheel has a rotor to spin")
	check(wheel.instance:FindFirstChild("Hub") ~= nil, "the wheel has a centre hub")
	check(wheel.instance:FindFirstChild("Pointer") ~= nil, "the wheel has a pointer to land under")

	local total = SpinConfig.totalWeight()
	local sweepSum = 0

	for _, segment in SpinConfig.Segments do
		local sweep = total > 0 and segment.weight / total * 360 or 0
		sweepSum += sweep

		local wedge = rotor and rotor:FindFirstChild(segment.id)
		check(wedge ~= nil, `the wheel draws a wedge for {segment.id}`)
		if not wedge then
			continue
		end

		check(wedge:FindFirstChild("Divider") ~= nil, `{segment.id} has a boundary line`)
		check(wedge:FindFirstChild("Tag") ~= nil, `{segment.id} is labelled`)

		local lowest, highest = math.huge, -math.huge
		local barWidth, radius, bars = 0, 0, 0
		for _, child in wedge:GetChildren() do
			if child.Name == "Slice" then
				bars += 1
				lowest = math.min(lowest, child.Rotation)
				highest = math.max(highest, child.Rotation)
				barWidth = child.Size.X.Scale
				radius = child.Size.Y.Scale
			end
		end

		check(bars > 0, `{segment.id} is drawn with at least one bar`)
		if bars == 0 then
			continue
		end

		-- A bar is a rectangle: at the rim it spans a chord, and the angle that
		-- chord subtends is how much of the circle the bar actually covers.
		local subtended = 2 * math.deg(math.asin(math.clamp(barWidth / (2 * radius), -1, 1)))
		local painted = (highest - lowest) + subtended

		-- Below its own sweep and the wheel lies about the odds in the player's
		-- favour or against it; far above and it eats the neighbouring prize.
		check(
			painted >= sweep - 0.5,
			`{segment.id} covers its {string.format("%.1f", sweep)} degrees (painted {string.format("%.1f", painted)})`
		)
		check(
			painted <= sweep + 8,
			`{segment.id} does not spill into its neighbour (sweep {string.format("%.1f", sweep)}, painted {string.format(
				"%.1f",
				painted
			)})`
		)
	end

	check(math.abs(sweepSum - 360) < 0.001, `the segments account for the whole circle (got {sweepSum})`)

	wheel:destroy()
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
