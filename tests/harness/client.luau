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
	-- A choice stores its option id, a slider stores a number. Both must be
	-- present before any profile lands, or the panel builds a control with
	-- nothing in it.
	local expected = if definition.kind == "choice" then "string" else "number"
	check(
		type(ClientStateModule.settings[definition.id]) == expected,
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

-- A render binding that errors stops running for the rest of the session on a
-- real client, and there is no warning anywhere. Every step below is checked
-- for that, starting with this one.
local function stepFrame(what: string)
	local broken = Env.stepRender()
	for _, failure in broken do
		check(false, `{failure.name} errored during {what}: {failure.err}`)
	end
	check(#broken == 0, `no render binding errored during {what}`)
end

stepFrame("play")
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
	stepFrame(`{name} open`)
	check(
		UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.Default,
		`{name} keeps the cursor free after the camera module has run (got {UserInputServiceStub.MouseBehavior})`
	)
	check(UserInputServiceStub.MouseIconEnabled == true, `{name} keeps a cursor drawn to click with`)

	UIControllerModule.closeMenu(name)
	check(not MouseLock.isUnlocked(), `closing {name} recaptures the cursor`)

	stepFrame(`{name} closed`)
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
stepFrame("a panel switch")
check(
	UserInputServiceStub.MouseBehavior == roblox.Enum.MouseBehavior.Default,
	"the cursor survives a panel switch and a frame"
)
UIControllerModule.closeMenu("Spin")

-- Opening and closing a panel must not move the camera. Freeing the cursor by
-- changing perspective would dolly the view in or out of the player's head
-- every time a menu opened, which is what the old implementation did and why
-- it never worked.
local PerspectiveModule = Env.load("src/client/Controllers/PerspectiveController")
local cameraModeBefore = Env.service("Players").LocalPlayer.CameraMode
UIControllerModule.openMenu("Settings")
check(
	Env.service("Players").LocalPlayer.CameraMode == cameraModeBefore,
	"opening a panel does not change the camera mode"
)
UIControllerModule.closeMenu("Settings")
check(
	Env.service("Players").LocalPlayer.CameraMode == cameraModeBefore,
	"closing a panel does not change the camera mode"
)

-- And the camera mode does follow the perspective, which is the one thing that
-- is allowed to move it.
local expectedMode = if PerspectiveModule.isFirstPerson()
	then roblox.Enum.CameraMode.LockFirstPerson
	else roblox.Enum.CameraMode.Classic
check(
	Env.service("Players").LocalPlayer.CameraMode == expectedMode,
	`the camera mode matches the {PerspectiveModule.get()}-person perspective`
)

--------------------------------------------------------------------------------
-- Perspective
--
-- Four things have to move together when the player switches shoulder: the
-- camera, their own body, the viewmodel, and where a shot claims to come from.
-- The last is the one that stops the game working rather than looking wrong.
--------------------------------------------------------------------------------

heading("Perspective")

local Perspective = Env.load("src/client/Controllers/PerspectiveController")
local localPlayer = Env.service("Players").LocalPlayer

check(
	Perspective.get() == SettingsConfig.get("Perspective").default,
	"the perspective starts on its configured default"
)

-- THE CHECK THIS SECTION EXISTS FOR. The server refuses a shot whose claimed
-- origin is more than MAX_ORIGIN_DEVIATION from where it believes the player's
-- eyes are. The third-person camera sits further back than that, so a client
-- sending the camera position — which is what a first-person client can get
-- away with, and what this game used to do — would have every shot in third
-- person rejected as spoofing. WeaponClient sends the head position instead.
check(
	Perspective.THIRD_ZOOM > WeaponConfig.MAX_ORIGIN_DEVIATION,
	string.format(
		"the third-person camera is further from the head than the server's origin tolerance "
			.. "(%d studs vs %d) — which is why a shot is fired from the head, not the camera",
		Perspective.THIRD_ZOOM,
		WeaponConfig.MAX_ORIGIN_DEVIATION
	)
)

for _, case in
	{
		{ mode = Perspective.THIRD, first = false, camera = roblox.Enum.CameraMode.Classic },
		{ mode = Perspective.FIRST, first = true, camera = roblox.Enum.CameraMode.LockFirstPerson },
	}
do
	SettingsController.apply({ Perspective = case.mode })

	check(Perspective.get() == case.mode, `the {case.mode} perspective is adopted`)
	check(Perspective.isFirstPerson() == case.first, `{case.mode} reports first person as {tostring(case.first)}`)
	check(localPlayer.CameraMode == case.camera, `{case.mode} sets the matching camera mode`)

	-- Pinned to a single distance in both modes: a scrollable zoom silently
	-- changes how far a player can see round a corner.
	check(
		localPlayer.CameraMinZoomDistance == localPlayer.CameraMaxZoomDistance,
		`{case.mode} pins the zoom to one distance`
	)
	check(localPlayer.CameraMinZoomDistance == Perspective.zoom(), `{case.mode} uses its own zoom distance`)
end

-- The shoulder offset. Roblox's Classic camera sits dead centre behind the
-- character, which puts the player's own head under the crosshair — reported in
-- a playtest as "the head is in the way wherever I look". CameraController
-- slides the camera sideways every frame to clear it.
--
-- Measured in the camera's OWN space, so it is exact and does not care that this
-- sandbox has no camera module putting the CFrame back each frame.
local harnessCamera = Env.service("Workspace").CurrentCamera
check(harnessCamera ~= nil, "the sandbox has a camera to move")

if harnessCamera then
	for _, case in
		{
			{ mode = Perspective.THIRD, shifted = true },
			{ mode = Perspective.FIRST, shifted = false },
		}
	do
		SettingsController.apply({ Perspective = case.mode })

		local before = harnessCamera.CFrame
		stepFrame(`a frame in {case.mode} person`)
		local moved = before:PointToObjectSpace(harnessCamera.CFrame.Position)

		if case.shifted then
			-- Right and up, and not forward or back: moving the camera along its
			-- own look vector would change how far it sees, which is a balance
			-- property rather than a framing one.
			check(moved.X > 0.5, `third person slides the camera off the spine (moved {moved.X} right)`)
			check(moved.Y > 0, `third person raises the camera a little (moved {moved.Y} up)`)
			check(math.abs(moved.Z) < 0.001, `third person does not change the camera's distance (moved {moved.Z})`)
		else
			check(
				moved.Magnitude < 0.001,
				`first person leaves the camera exactly where the engine put it (moved {moved.Magnitude})`
			)
		end
	end
end

-- An unrecognised value is not "leave it alone": it resolves to the default, so
-- a corrupt profile cannot strand the camera somewhere no menu option matches.
SettingsController.apply({ Perspective = "Sideways" })
check(
	Perspective.get() == SettingsConfig.get("Perspective").default,
	"an unknown perspective falls back to the default"
)

-- The control the player actually uses. A slider would imply a middle setting
-- between first and third person, and there is not one.
local ChoiceRow = Env.load("src/client/UI/Components/ChoiceRow")
local choiceOk, choice = pcall(function()
	return ChoiceRow.create({
		settingId = "Perspective",
		value = Perspective.FIRST,
		parent = roblox.Instance.new("ScreenGui"),
	})
end)

check(choiceOk and choice ~= nil, `the perspective control builds{if choiceOk then "" else ": " .. tostring(choice)}`)
if choiceOk and choice then
	check(choice:getValue() == Perspective.FIRST, "the control starts on its given option")

	local notified = 0
	choice._onChanged = function()
		notified += 1
	end

	choice:setValue(Perspective.THIRD)
	check(choice:getValue() == Perspective.THIRD, "setValue selects the other option")
	check(notified == 0, "setValue does not fire onChanged")

	choice:setValue("Sideways")
	check(choice:getValue() == SettingsConfig.get("Perspective").default, "an unknown option falls back to the default")

	local options = choice.instance:FindFirstChild("Options")
	check(options ~= nil, "the control has a row of options")
	if options then
		local buttons = 0
		local widthScale = 0
		for _, child in options:GetChildren() do
			if child:IsA("TextButton") then
				buttons += 1
				widthScale += child.Size.X.Scale
			end
		end
		check(buttons == #SettingsConfig.optionsFor("Perspective"), "there is a button per option")
		check(widthScale <= 1.0001, `the option buttons fit across the row ({string.format("%.3f", widthScale)})`)
	end

	choice:destroy()
end

-- The panel picks its control from the definition's kind, so a choice control
-- asked to render a slider setting must refuse rather than draw an empty row.
check(
	ChoiceRow.create({ settingId = "Sensitivity", value = 1, parent = roblox.Instance.new("ScreenGui") }) == nil,
	"a slider setting cannot be built as a choice"
)
-- Leave the perspective as the player's default so later checks see a clean
-- state rather than whatever the last case in the loop set.
SettingsController.apply(ClientStateModule.settings)

-- The equip panel lays its weapons out side by side, and the width of a column
-- was a constant rather than a fraction of however many weapons exist. Adding
-- the third left it off the right edge of the panel, unreachable, with nothing
-- anywhere failing. Adding a fourth would do it again.
heading("Equip columns")

local equipGui = UIControllerModule.getScreen("EquipMenu")
local columnsHolder = nil
if equipGui then
	for _, descendant in equipGui:GetDescendants() do
		if descendant.Name == "Columns" then
			columnsHolder = descendant
			break
		end
	end
end

check(columnsHolder ~= nil, "the equip panel has a column holder")
if columnsHolder then
	local widthScale, widthOffset, found = 0, 0, 0
	for _, weaponId in WeaponConfig.Order do
		local column = columnsHolder:FindFirstChild(weaponId)
		check(column ~= nil, `the equip panel has a column for {weaponId}`)
		if column then
			found += 1
			widthScale += column.Size.X.Scale
			widthOffset += column.Size.X.Offset
		end
	end

	local layout = columnsHolder:FindFirstChildOfClass("UIListLayout")
	local padding = if layout then layout.Padding.Offset * (found - 1) else 0

	-- Scale is the part that can silently overflow: the offsets only ever pull
	-- columns narrower to pay for the padding between them.
	check(
		widthScale <= 1.0001,
		string.format("the columns fit across the panel (%.3f of its width for %d weapons)", widthScale, found)
	)
	check(
		widthOffset + padding >= -1 and widthOffset + padding <= 1,
		string.format(
			"the gaps between columns are paid for out of their width (%d px left over)",
			widthOffset + padding
		)
	)
end

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
