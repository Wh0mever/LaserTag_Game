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
-- The card waits out a delay so the hub has finished building behind it. That
-- delay is real now — task.delay schedules instead of firing on the spot — so
-- the clock has to be moved past it, and the card not being up before that is
-- half of what this asserts.
check(not UIControllerModule.isMenuOpen("Welcome"), "the card waits for the hub rather than appearing mid-load")
Env.advance(3)
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

--------------------------------------------------------------------------------
-- The side menu folds away
--
-- Five buttons down the left edge is reasonable chrome on a monitor and half the
-- screen on a phone, where they sat over the arena for the whole match. They now
-- live behind one toggle.
--------------------------------------------------------------------------------

heading("Side menu")

local SideButtons = Env.load("src/client/UI/Screens/SideButtonsScreen")
local sideGui = UIControllerModule.getScreen("SideButtons")
local menuPanel = nil
if sideGui then
	for _, descendant in sideGui:GetDescendants() do
		if descendant.Name == "Menu" then
			menuPanel = descendant
			break
		end
	end
end

check(menuPanel ~= nil, "the side menu has a panel")
if menuPanel then
	local toggleButton = menuPanel:FindFirstChild("MenuToggle")
	local list = menuPanel:FindFirstChild("Buttons")

	check(toggleButton ~= nil, "the panel has a toggle")
	check(list ~= nil, "the panel has the button stack")

	-- Drawn bars rather than a glyph. This project ships no image assets and the
	-- set of glyphs that renders in Gotham on every platform is small; the one
	-- button a player must be able to find is not the place to gamble on a font
	-- carrying U+2630, and a missing glyph leaves a blank button with no error.
	if toggleButton then
		local bars = 0
		for _, descendant in toggleButton:GetDescendants() do
			if descendant:IsA("Frame") and descendant.Name:match("^Bar%d$") then
				bars += 1
			end
		end
		check(bars == 3, `the toggle draws its three bars rather than typing a glyph (found {bars})`)
	end

	-- This client is not a touch device, so the stack starts open: a mouse and
	-- keyboard has both the room for it and the hotkeys without it.
	check(not ClientStateModule.isTouch, "the sandbox client is not a touch device")
	check(SideButtons.isExpanded(), "on a desktop client the stack starts open")
	check(list ~= nil and list.Visible, "the stack is on screen when expanded")

	SideButtons.setExpanded(false)
	check(not SideButtons.isExpanded(), "the toggle folds the stack away")
	check(list ~= nil and not list.Visible, "a folded stack is off screen")

	-- THE PROPERTY THAT MAKES FOLDING SAFE. The buttons are one way in; the
	-- hotkeys are another, and they do not go through these buttons at all. If
	-- folding could take the menus with it, a player who collapsed the stack
	-- would have locked themselves out of the shop.
	UIControllerModule.openMenu("Shop")
	check(UIControllerModule.isMenuOpen("Shop"), "a menu still opens while the stack is folded")
	UIControllerModule.closeMenu("Shop")

	SideButtons.setExpanded(true)
	check(SideButtons.isExpanded(), "the toggle brings the stack back")
	check(list ~= nil and list.Visible, "an unfolded stack is on screen again")

	-- Every menu the stack offers must still have its button, folded or not.
	if list then
		for _, name in { "Equip", "Shop", "Friends", "Spin", "Settings" } do
			check(list:FindFirstChild(name) ~= nil, `the stack still carries the {name} button`)
		end
	end
end

-- The equip panel shows one weapon at a time behind a row of tabs. It used to
-- be a column per weapon side by side, which cut every skin name to "…" on a
-- monitor and on a phone left no room for a single skin row — a player could
-- not equip anything. So the checks are about reaching every weapon's skins,
-- not about how the panel is divided.
heading("Equip tabs")

local EquipScreenModule = Env.load("src/client/UI/Screens/EquipScreen")
local equipTabs = EquipScreenModule.tabs()
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
check(columnsHolder ~= nil, "the equip panel has a holder for the weapons' skin lists")

local tabScale = 0
for _, weaponId in WeaponConfig.Order do
	local tab = equipTabs[weaponId]
	check(tab ~= nil, `the equip panel has a tab for {weaponId}`)
	if not tab then
		continue
	end
	tabScale += tab.instance.Size.X.Scale

	-- Pressing the tab is the only way to that weapon's skins, so it is pressed
	-- the way a player would and the result is read off the screen.
	tab.instance.Activated:Fire()
	check(EquipScreenModule.selectedWeapon() == weaponId, `pressing the {weaponId} tab selects it`)
	if columnsHolder then
		for _, other in WeaponConfig.Order do
			local column = columnsHolder:FindFirstChild(other)
			check(
				column ~= nil and column.Visible == (other == weaponId),
				`with {weaponId} selected, {other}'s skins are {if other == weaponId then "shown" else "hidden"}`
			)
		end
	end
end
check(tabScale <= 1.0001, string.format("the tabs fit across the panel (%.3f of its width)", tabScale))

-- The wheel is the one widget whose correctness is geometric: it has to paint
-- each segment across its true share of the circle, as a WHEEL.
--
-- The previous version of these checks read each bar's Rotation property and
-- concluded the wheel was right, while in the game it was a small fan in the
-- top half of the rim. Roblox turns a GuiObject about its CENTRE, never its
-- AnchorPoint, and the bars were anchored at their bottom edge on the belief
-- that they would sweep about it. A check that reads the property the code set
-- agrees with the code. So this one works out where each bar's outer tip
-- actually lands, applying Roblox's rule up the parent chain, and demands that
-- every tip sits on the rim at its segment's angle.
local SpinWheel = Env.load("src/client/UI/Screens/SpinWheel")
local SpinConfig = Env.load("src/shared/Config/SpinConfig")

-- Where `point` (in `node`'s parent's unrotated space, unit-square units) ends
-- up in `stop`'s space, rotating about each object's own centre. Every part of
-- the wheel is sized by Scale alone, so a unit square is the whole world.
local function box(node, parentW: number, parentH: number)
	local w = node.Size.X.Scale * parentW
	local h = node.Size.Y.Scale * parentH
	local x = node.Position.X.Scale * parentW - node.AnchorPoint.X * w
	local y = node.Position.Y.Scale * parentH - node.AnchorPoint.Y * h
	return x, y, w, h
end

local function throughChain(chain: { any }, px: number, py: number): (number, number)
	-- chain[1] is the outermost frame (the rotor), chain[#chain] the innermost.
	-- Boxes are resolved top-down, then the point is carried bottom-up.
	local boxes = {}
	local originX, originY, parentW, parentH = 0, 0, 1, 1
	for index, node in chain do
		local x, y, w, h = box(node, parentW, parentH)
		boxes[index] = { x = originX + x, y = originY + y, w = w, h = h, rot = node.Rotation }
		originX, originY, parentW, parentH = originX + x, originY + y, w, h
	end
	for index = #chain, 1, -1 do
		local b = boxes[index]
		if b.rot ~= 0 then
			local cx, cy = b.x + b.w / 2, b.y + b.h / 2
			local a = math.rad(b.rot)
			local dx, dy = px - cx, py - cy
			px, py = cx + dx * math.cos(a) - dy * math.sin(a), cy + dx * math.sin(a) + dy * math.cos(a)
		end
	end
	return px, py
end

local function chainTo(node, stop)
	local chain = {}
	local current = node
	while current and current ~= stop do
		table.insert(chain, 1, current)
		current = current.Parent
	end
	return chain
end

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
	local accumulated = 0
	local rimRadius = nil

	for _, segment in SpinConfig.Segments do
		local sweep = total > 0 and segment.weight / total * 360 or 0
		sweepSum += sweep

		local wedge = rotor and rotor:FindFirstChild(segment.id)
		check(wedge ~= nil, `the wheel draws a wedge for {segment.id}`)
		if not wedge then
			accumulated += sweep
			continue
		end

		local divider = wedge:FindFirstChild("Divider", true)
		check(divider ~= nil, `{segment.id} has a boundary line`)

		-- Every bar's outer tip, where it really lands.
		local lowest, highest, bars = math.huge, -math.huge, 0
		local worstRadiusError = 0
		for _, child in wedge:GetDescendants() do
			if child.Name ~= "Slice" then
				continue
			end
			bars += 1
			local chain = chainTo(child, rotor)
			local b = chain[#chain]
			-- The tip is the middle of the bar's top edge, in its parent's space.
			local parentChain = table.clone(chain)
			table.remove(parentChain)
			local _, _, pw, ph = 0, 0, 1, 1
			for _, node in parentChain do
				local _, _, w, h = box(node, pw, ph)
				pw, ph = w, h
			end
			local bx, by, bw = box(b, pw, ph)
			local tipX, tipY = throughChain(chain, bx + bw / 2, by)

			local dx, dy = tipX - 0.5, tipY - 0.5
			local radius = math.sqrt(dx * dx + dy * dy)
			rimRadius = rimRadius or radius
			worstRadiusError = math.max(worstRadiusError, math.abs(radius - rimRadius))

			-- Clockwise from the top, as the pointer reads it.
			local angle = (math.deg(math.atan2(dx, -dy)) + 360) % 360
			-- Unwrap across 0 so a segment that starts at the top stays contiguous.
			if angle < accumulated - 180 then
				angle += 360
			end
			lowest = math.min(lowest, angle)
			highest = math.max(highest, angle)
		end

		check(bars > 0, `{segment.id} is drawn with at least one bar`)
		if bars == 0 then
			accumulated += sweep
			continue
		end

		check(
			worstRadiusError < 0.01,
			`every {segment.id} bar reaches the rim, not a point inside it (worst {string.format(
				"%.3f",
				worstRadiusError
			)} off)`
		)

		-- The bars' tips must fall inside the segment's own arc, and between
		-- them reach close to both of its edges.
		check(
			lowest >= accumulated - 0.5 and highest <= accumulated + sweep + 0.5,
			`{segment.id} is drawn inside its own arc {string.format("%.1f-%.1f", accumulated, accumulated + sweep)} `
				.. `(tips at {string.format("%.1f-%.1f", lowest, highest)})`
		)
		check(
			(highest - lowest) >= sweep - 2 * 3.5,
			`{segment.id} spans its {string.format("%.1f", sweep)} degrees (tips span {string.format(
				"%.1f",
				highest - lowest
			)})`
		)

		accumulated += sweep
	end

	check(math.abs(sweepSum - 360) < 0.001, `the segments account for the whole circle (got {sweepSum})`)
	check(
		rimRadius ~= nil and rimRadius > 0.4,
		`the bars reach out to the rim of the wheel (radius {string.format("%.2f", rimRadius or 0)} of its size)`
	)

	wheel:destroy()
end

--------------------------------------------------------------------------------
-- Recoil comes back down
--
-- Roblox's camera module starts every frame from the look direction Camera
-- .CFrame already has (BaseCamera:GetCameraLookVector), so anything this game
-- rotates the camera by is carried into the next frame. The recoil offset used
-- to be applied IN FULL every frame, which added the decaying kick onto itself
-- over and over: one Lance shot left the view 32 degrees higher for good. The
-- stand-in below behaves like ClassicCamera with no mouse input — it keeps the
-- current look direction — and the view has to rise by the kick and return.
--------------------------------------------------------------------------------

heading("Recoil comes back down")

do
	local CameraControllerModule = Env.load("src/client/Controllers/CameraController")
	local RecoilControllerModule = Env.load("src/client/Controllers/RecoilController")
	local recoilCamera = Env.workspace().CurrentCamera
	local focus = roblox.Vector3.new(0, 5, 0)

	local function pitchOf(cf): number
		return math.deg(math.asin(cf.LookVector.Y))
	end

	-- The ClassicCamera stand-in, at Enum.RenderPriority.Camera like the real one.
	Env.renderBindings["cameraRenderUpdate"] = {
		priority = 200,
		callback = function()
			local look = recoilCamera.CFrame.LookVector
			local p = math.asin(look.Y)
			local y = math.atan2(-look.X, -look.Z)
			local rot = roblox.CFrame.Angles(0, y, 0) * roblox.CFrame.Angles(p, 0, 0)
			recoilCamera.CFrame = roblox.CFrame.new(focus - rot.LookVector * 12) * rot
		end,
	}

	CameraControllerModule.resetRecoil()
	Env.stepRender()
	local before = pitchOf(recoilCamera.CFrame)

	RecoilControllerModule.onShot("Lance", os.clock())
	local kick = select(1, CameraControllerModule.getRecoilOffset())
	local peak = -math.huge
	for _ = 1, 180 do
		local errors = Env.stepRender()
		check(#errors == 0, `the render bindings run cleanly{if errors[1] then ": " .. errors[1].err else ""}`)
		peak = math.max(peak, pitchOf(recoilCamera.CFrame) - before)
	end
	local drift = pitchOf(recoilCamera.CFrame) - before

	check(
		math.abs(peak - kick) < 0.3,
		`one shot lifts the view by its kick and no more (kick {string.format("%.2f", kick)}, rose {string.format(
			"%.2f",
			peak
		)})`
	)
	check(math.abs(drift) < 0.05, `and the view comes back down (left {string.format("%.2f", drift)} degrees off)`)

	-- A full rifle burst, the case players actually meet.
	CameraControllerModule.resetRecoil()
	Env.stepRender()
	before = pitchOf(recoilCamera.CFrame)
	for shot = 1, 10 do
		RecoilControllerModule.onShot("Rifle", os.clock() + shot * 0.1)
		for _ = 1, 6 do
			Env.stepRender()
		end
	end
	for _ = 1, 240 do
		Env.stepRender()
	end
	drift = pitchOf(recoilCamera.CFrame) - before
	check(
		math.abs(drift) < 0.1,
		`a ten-round rifle burst settles back where it started (left {string.format("%.2f", drift)} degrees off)`
	)

	Env.renderBindings["cameraRenderUpdate"] = nil
end

--------------------------------------------------------------------------------
-- A weapon switch settles on what the server says
--
-- The client swaps its gun the moment a key is pressed and tells the server.
-- The server can drop that request without a word (the player died a moment
-- earlier, or the rate limit), and the client used to keep its gun anyway: for
-- the rest of that life every shot named a weapon the server did not think was
-- in hand, and every one was silently thrown away.
--------------------------------------------------------------------------------

heading("Weapon switch reconciliation")

do
	local realTask = require("@lune/task")
	local WeaponClientModule = Env.load("src/client/Controllers/WeaponClient")
	local switchPlayer = Env.service("Players").LocalPlayer

	-- A living character in a running match, so the gun may be used at all.
	local character = roblox.Instance.new("Model")
	local humanoid = roblox.Instance.new("Humanoid")
	-- Lune's Humanoid carries no default health; a real one spawns at 100.
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = character
	switchPlayer.Character = character
	ClientStateModule.isDead = false
	switchPlayer:SetAttribute("InMatch", "Dust")
	ClientStateModule.match.phase = "InProgress"
	switchPlayer:SetAttribute("CurrentWeapon", "Rifle")
	for _ = 1, 3 do
		UIControllerModule.closeAll()
	end
	ClientStateModule.SlotChanged:Fire(1, "Rifle")
	realTask.wait(1.1)
	Env.stepHeartbeat()

	check(WeaponClientModule.getWeaponId() == "Rifle", "the rifle is in hand to begin with")

	-- 1. A switch the server never answers.
	WeaponClientModule.equipSlot(2)
	check(WeaponClientModule.getWeaponId() == "Pistol", "pressing 2 shows the pistol at once")
	Env.stepHeartbeat()
	check(WeaponClientModule.getWeaponId() == "Pistol", "and keeps it while the answer is on its way")
	realTask.wait(1.1)
	Env.stepHeartbeat()
	check(
		WeaponClientModule.getWeaponId() == "Rifle",
		`an unanswered switch gives way to the server's weapon (holding {WeaponClientModule.getWeaponId()})`
	)

	-- 2. A late echo of an older switch.
	WeaponClientModule.equipSlot(2)
	WeaponClientModule.equipSlot(1)
	ClientStateModule.SlotChanged:Fire(2, "Pistol")
	check(
		WeaponClientModule.getWeaponId() == "Rifle",
		`the echo of a switch already replaced does not bounce the gun back (holding {WeaponClientModule.getWeaponId()})`
	)
	ClientStateModule.SlotChanged:Fire(1, "Rifle")

	-- 3. No shooting at the scoreboard. The switch lockout from above is waited
	-- out first, and the same moment in a running match is the control: without
	-- it this check would pass on the lockout alone.
	realTask.wait(0.4)
	Env.stepHeartbeat()
	check(WeaponClientModule.canFire(), "the gun can fire while the match is running")
	ClientStateModule.match.phase = "Results"
	check(not WeaponClientModule.canFire(), "and nothing fires during the results")
	ClientStateModule.match.phase = "InProgress"

	switchPlayer.Character = nil
end

--------------------------------------------------------------------------------
-- A disabled button stays looking disabled
--------------------------------------------------------------------------------

heading("Disabled buttons")

do
	local UIThemeModule = Env.load("src/client/UI/UITheme")
	local ButtonModule = Env.load("src/client/UI/Components/Button")
	local tweens = Env.service("TweenService")
	local inertCreate = tweens.Create
	-- Tweens land at once for this check: the bug is where a tween ENDS.
	tweens.Create = function(_self, instance, _info, goals)
		return {
			Play = function()
				for property, value in goals do
					(instance :: any)[property] = value
				end
			end,
			Cancel = function() end,
			Completed = Env.liveSignal(),
		}
	end

	local holder = roblox.Instance.new("ScreenGui")
	local buy = ButtonModule.create({ text = "КУПИТЬ", parent = holder, color = UIThemeModule.Colors.Coin })
	buy:setEnabled(false)
	buy.instance.MouseEnter:Fire()
	buy.instance.MouseLeave:Fire()
	check(
		buy.instance.BackgroundColor3 == UIThemeModule.Colors.Disabled,
		"a disabled button still looks disabled after the pointer passes over it"
	)
	buy:setColor(UIThemeModule.Colors.Accent)
	check(
		buy.instance.BackgroundColor3 == UIThemeModule.Colors.Disabled,
		"and recolouring it does not paint it enabled"
	)
	buy:setEnabled(true)
	check(buy.instance.BackgroundColor3 == UIThemeModule.Colors.Accent, "enabling it shows the colour it was given")
	buy:destroy()

	tweens.Create = inertCreate
end

--------------------------------------------------------------------------------
-- A slider can be grabbed with a thumb
--------------------------------------------------------------------------------

heading("Slider touch targets")

do
	local settingsGui = UIControllerModule.getScreen("SettingsMenu")
	local tracks = 0
	if settingsGui then
		for _, descendant in settingsGui:GetDescendants() do
			if descendant.Name == "Track" and descendant:IsA("GuiButton") then
				tracks += 1
				check(
					descendant.Size.Y.Offset >= 28,
					`a slider answers a touch across {descendant.Size.Y.Offset} px of height, at least 28`
				)
			end
		end
	end
	check(tracks > 0, "the settings panel has sliders to check")
end

--------------------------------------------------------------------------------
-- A slider inside a scrolling panel
--
-- Every slider sits in the vertical ScrollingFrame of the settings panel, and on
-- a phone a large share of that surface is slider track. Setting the value on
-- touch-down meant a drag started on the ГРОМКОСТЬ track to scroll the panel
-- set the volume where the thumb landed, and the release saved it to the
-- profile. A touch now only becomes a drag once it has moved sideways.
--------------------------------------------------------------------------------

heading("Slider and scrolling")

do
	local UserInputEvents = Env.service("UserInputService")
	local SliderModule = Env.load("src/client/UI/Components/Slider")
	local Config = Env.load("src/shared/Config/SettingsConfig")

	local changes: { number } = {}
	local commits: { number } = {}
	local holder = roblox.Instance.new("ScreenGui")
	local scrolled = SliderModule.create({
		settingId = "Volume",
		value = 0.5,
		parent = holder,
		onChanged = function(value: number)
			table.insert(changes, value)
		end,
		onCommitted = function(value: number)
			table.insert(commits, value)
		end,
	})
	-- A 400 px track from x = 100: a finger at x = 300 is 50%.
	Env.placeGui(scrolled._track, 100, 200, 400, 32)

	local function touch(x: number, y: number)
		return {
			UserInputType = roblox.Enum.UserInputType.Touch,
			UserInputState = roblox.Enum.UserInputState.Begin,
			Position = roblox.Vector3.new(x, y, 0),
		}
	end

	local function down(input: any)
		Env.instanceEvent(scrolled._track, "InputBegan"):Fire(input)
	end

	local function move(input: any, x: number, y: number)
		input.UserInputState = roblox.Enum.UserInputState.Change
		input.Position = roblox.Vector3.new(x, y, 0)
		UserInputEvents.InputChanged:Fire(input, false)
	end

	local function up(input: any)
		input.UserInputState = roblox.Enum.UserInputState.End
		UserInputEvents.InputEnded:Fire(input, false)
	end

	local function reset()
		table.clear(changes)
		table.clear(commits)
		scrolled:setValue(0.5)
	end

	-- A scroll: the finger lands on the track and goes up the screen.
	reset()
	local scroll = touch(420, 216)
	down(scroll)
	check(#changes == 0 and scrolled:getValue() == 0.5, "touching the track does not move the slider on touch-down")
	move(scroll, 421, 190)
	move(scroll, 423, 120)
	move(scroll, 480, 60)
	up(scroll)
	check(#changes == 0, `a vertical drag across a slider changes nothing (saw {#changes} changes)`)
	check(#commits == 0, `and saves nothing (saw {#commits} commits)`)
	check(scrolled:getValue() == 0.5, `the value is where it was (got {scrolled:getValue()})`)

	-- A drag: the finger moves along the track.
	reset()
	local drag = touch(300, 216)
	down(drag)
	move(drag, 304, 217)
	check(#changes == 0, "a few pixels of jitter do not start a drag")
	move(drag, 340, 218)
	check(#changes > 0, "moving sideways starts the drag")
	check(
		math.abs(scrolled:getValue() - Config.fromFraction("Volume", 0.6)) < 1e-6,
		`the value follows the finger to x = 340 (got {scrolled:getValue()})`
	)
	move(drag, 460, 260)
	check(
		math.abs(scrolled:getValue() - Config.fromFraction("Volume", 0.9)) < 1e-6,
		`and keeps following once the drag has begun, even off the track (got {scrolled:getValue()})`
	)
	check(#commits == 0, "nothing is saved while the finger is down")
	up(drag)
	check(#commits == 1, `lifting the finger saves once (saw {#commits})`)
	check(commits[1] == scrolled:getValue(), "and saves what the slider shows")

	-- A tap on the track still goes to that point, once, on release.
	reset()
	local tap = touch(200, 216)
	down(tap)
	check(#changes == 0, "a tap has not done anything while the finger is down")
	up(tap)
	check(
		math.abs(scrolled:getValue() - Config.fromFraction("Volume", 0.25)) < 1e-6,
		`a tap moves the slider to the finger (got {scrolled:getValue()})`
	)
	check(#commits == 1, `and saves it (saw {#commits})`)

	-- A tap that drifted a few pixels is still a tap.
	reset()
	local drifting = touch(400, 216)
	down(drifting)
	move(drifting, 403, 219)
	up(drifting)
	check(#commits == 1, "a finger that wobbled by a few pixels and lifted is a tap")

	-- A scroll gesture ends the round: the same finger moving sideways later
	-- (the panel is being flicked) does not turn into a drag.
	reset()
	local flick = touch(300, 216)
	down(flick)
	move(flick, 300, 150)
	move(flick, 480, 150)
	up(flick)
	check(#changes == 0 and #commits == 0, "a touch that went vertical first stays a scroll")

	-- Another finger elsewhere on the screen is not this slider's.
	reset()
	local mine = touch(300, 216)
	local other = touch(50, 50)
	down(mine)
	move(mine, 360, 216)
	local seen = scrolled:getValue()
	move(other, 480, 50)
	check(scrolled:getValue() == seen, "a second finger does not steer the slider")
	up(other)
	check(#commits == 0, "and lifting it does not save")
	up(mine)
	check(#commits == 1, "the finger that dragged is the one that saves")

	-- The mouse keeps jump-to-point: there is no scrolling by dragging with it.
	reset()
	local click = {
		UserInputType = roblox.Enum.UserInputType.MouseButton1,
		UserInputState = roblox.Enum.UserInputState.Begin,
		Position = roblox.Vector3.new(400, 216, 0),
	}
	down(click)
	check(
		math.abs(scrolled:getValue() - Config.fromFraction("Volume", 0.75)) < 1e-6,
		`a mouse press goes to the pointer at once (got {scrolled:getValue()})`
	)
	local hover = {
		UserInputType = roblox.Enum.UserInputType.MouseMovement,
		UserInputState = roblox.Enum.UserInputState.Change,
		Position = roblox.Vector3.new(500, 216, 0),
	}
	UserInputEvents.InputChanged:Fire(hover, false)
	check(scrolled:getValue() == Config.fromFraction("Volume", 1), "and follows the pointer while it is held")
	click.UserInputState = roblox.Enum.UserInputState.End
	UserInputEvents.InputEnded:Fire(click, false)
	check(#commits == 1, "and saves on release")

	scrolled:destroy()
end

--------------------------------------------------------------------------------
-- The spin button says what a spin costs
--
-- It read КРУТИТЬ in every state, so once the free spin was used the same tap
-- quietly took 600 coins, and with too few coins it stayed lit and failed.
--------------------------------------------------------------------------------

heading("Spin button")

do
	local SpinScreenModule = Env.load("src/client/UI/Screens/SpinScreen")
	local SpinConfigModule = Env.load("src/shared/Config/SpinConfig")
	local cost = SpinConfigModule.EXTRA_SPIN_COST
	UIControllerModule.openMenu("Spin")

	local function show(nextFreeAt: number, coinBalance: number): string?
		ClientStateModule.spin.nextFreeAt = nextFreeAt
		ClientStateModule.coins = coinBalance
		ClientStateModule.CoinsChanged:Fire(coinBalance, 0, "test")
		return SpinScreenModule.buttonText()
	end

	check(show(0, 0) == "КРУТИТЬ БЕСПЛАТНО", `a free spin says it is free (got {tostring(show(0, 0))})`)
	local later = os.clock() + 3600
	check(show(later, cost + 50) == `КРУТИТЬ ЗА {cost}`, "a paid spin names its price on the button")
	check(show(later, cost - 1) == `НУЖНО {cost} МОНЕТ`, "a spin the player cannot afford says so")

	-- The panel refreshes its clock and button every frame while open; a frame
	-- has to run cleanly, which is how a call to a function defined further
	-- down the file shows itself.
	local frameOk, frameErr = pcall(Env.stepHeartbeat)
	check(frameOk, `a frame with the wheel open runs cleanly{if frameOk then "" else ": " .. tostring(frameErr)}`)

	UIControllerModule.closeMenu("Spin")
end

--------------------------------------------------------------------------------
-- A player on a pad can see they are queued
--
-- The server sent the queue size and the countdown every second and nothing
-- drew it; the only feedback was a sign behind the player.
--------------------------------------------------------------------------------

heading("Queue chip")

local QueueScreenModule = Env.load("src/client/UI/Screens/QueueScreen")
check(QueueScreenModule.textFor("Dust", 1, 2, nil) == "DUST  ·  В ОЧЕРЕДИ 1/2", "one of two reads as a queue")
check(QueueScreenModule.textFor("Dust", 2, 2, 7) == "DUST  ·  СТАРТ ЧЕРЕЗ 7", "a countdown reads as a start")
check(QueueScreenModule.textFor("", 0, 2, nil) == nil, "no queue shows nothing")

local queueChip = QueueScreenModule.chip()
check(queueChip ~= nil, "the queue chip is built")
if queueChip then
	local queuePlayer = Env.service("Players").LocalPlayer
	queuePlayer:SetAttribute("InMatch", "")
	ClientStateModule.queue = { mapId = "Dust", count = 1, needed = 2 }
	ClientStateModule.QueueChanged:Fire("Dust", 1, 2, nil)
	check(queueChip.Visible, "stepping on a pad shows the chip")

	-- What QueueService now sends the player who steps off.
	ClientStateModule.queue = { mapId = "", count = 0, needed = 2 }
	ClientStateModule.QueueChanged:Fire("", 0, 2, nil)
	check(not queueChip.Visible, "stepping off hides it again")
end

--------------------------------------------------------------------------------
-- The match result says what the player earned
--
-- The server paid every player and the card said "Монет не начислено" to all
-- of them. The rewards table was keyed by numeric UserId, which a RemoteEvent
-- does not deliver as numbers, so the client's lookup found nothing. The
-- payload here is shaped the way it actually arrives: string keys.
--------------------------------------------------------------------------------

heading("Match result")

local ResultsScreenModule = Env.load("src/client/UI/Screens/ResultsScreen")
local resultsPlayer = Env.service("Players").LocalPlayer
local resultsGui = UIControllerModule.getScreen("Results")
check(resultsGui ~= nil, "the results screen exists")

ClientStateModule.match.mapId = "Dust"
ClientStateModule.match.phase = "Results"
ClientStateModule.match.data = {
	scores = { A = 12, B = 9 },
	winnerTeam = "A",
	rewards = { [tostring(resultsPlayer.UserId)] = 400 },
}
ClientStateModule.MatchChanged:Fire(ClientStateModule.match)

local rewardText = nil
if resultsGui then
	local label = resultsGui:FindFirstChild("Reward", true)
	rewardText = label and label.Text
end
check(rewardText == "+400 монет", `a paid player is told what they earned (card says "{tostring(rewardText)}")`)
local _ = ResultsScreenModule

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
-- Spawned work runs on its own thread now, so a thread that dies takes its
-- timer or its poll with it and says nothing. This is where it says something.
check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

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
