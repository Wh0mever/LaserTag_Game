--!nonstrict
--[[
	tests/harness/mobile.luau
	Boots the whole client as a phone and asks what the player can actually do.

	Every other scenario runs on a simulated desktop, and until this existed that
	was the only machine this game had ever been executed on. Mobile shipped
	unobserved, and it showed: a phone kept StarterPlayer's LockFirstPerson and
	its 0.5 zoom for the entire session, because MouseLockController took a touch
	early return before it applied the perspective or subscribed to changes in
	it. Third person — the view the game defaults to — did not exist on mobile at
	all, and the touch VIEW button flipped the stored preference and saved it to
	the profile while the camera never moved.

	None of that was catchable before, for a duller reason than it sounds: the
	sandbox's local player had stub attributes. GetAttribute always returned nil
	and SetAttribute did nothing, so the client could never be put into a match,
	and the touch buttons only exist during one. tests/harness/env.luau now keeps
	attributes for real and fires their changed signals.

	So the checks here are deliberately written as capability — press this, does
	the game do the thing — rather than as "was the right function called". The
	mobile bugs all passed a "was it called" reading.

	Run:  lune run tests/harness/mobile
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

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
-- Boot the client as a phone
--------------------------------------------------------------------------------

heading("Booting a phone")

Env.setDevice("phone")
Env.enableClientRuntime()

local ClientState = Env.load("src/client/ClientState")
local InputController = Env.load("src/client/Controllers/InputController")
local PerspectiveController = Env.load("src/client/Controllers/PerspectiveController")
local SettingsController = Env.load("src/client/Controllers/SettingsController")
local MouseLockController = Env.load("src/client/Controllers/MouseLockController")
local MobileControls = Env.load("src/client/Controllers/MobileControlsController")
local UIController = Env.load("src/client/UI/UIController")

local player = Env.service("Players").LocalPlayer

-- Priority order, as the real Loader would run them.
local CONTROLLERS = {
	{ name = "ClientState", module = ClientState },
	{ name = "InputController", module = InputController },
	{ name = "PerspectiveController", module = PerspectiveController },
	{ name = "SettingsController", module = SettingsController },
	{ name = "MouseLockController", module = MouseLockController },
	{ name = "MobileControlsController", module = MobileControls },
}

for _, entry in CONTROLLERS do
	if type(entry.module.init) == "function" then
		local ok, err = pcall(entry.module.init)
		check(ok, `{entry.name} initialises on a phone: {tostring(err)}`)
	end
end
print(`  {#CONTROLLERS} controllers initialised`)

--------------------------------------------------------------------------------
-- The device is what we think it is
--------------------------------------------------------------------------------

heading("Device")

check(ClientState.isTouch, "the client knows it is a touch device")
check(not MouseLockController.isEnabled(), "no cursor is managed on a phone")
check(MobileControls.isActive(), "the touch controls are active")

--------------------------------------------------------------------------------
-- The camera
--
-- StarterPlayer ships CameraMode LockFirstPerson with both zoom distances at
-- 0.5. Anything that fails to overwrite all three leaves the player welded into
-- first person, so these read the properties rather than asking a controller
-- what it believes it did.
--------------------------------------------------------------------------------

heading("Camera")

local function cameraState(): string
	return `mode={tostring(player.CameraMode)} zoom={tostring(player.CameraMinZoomDistance)}`
		.. `..{tostring(player.CameraMaxZoomDistance)}`
end

check(
	PerspectiveController.get() == PerspectiveController.THIRD,
	`a phone starts in the configured default perspective (got {PerspectiveController.get()})`
)
check(
	player.CameraMaxZoomDistance == PerspectiveController.THIRD_ZOOM,
	`the camera is actually pulled back on boot, not just intended to be ({cameraState()})`
)
check(
	player.CameraMode == roblox.Enum.CameraMode.Classic,
	`third person means CameraMode Classic, not LockFirstPerson ({cameraState()})`
)

--------------------------------------------------------------------------------
-- In a match
--------------------------------------------------------------------------------

heading("Entering a match")

player:SetAttribute("InMatch", "Dust")
check(ClientState.isInMatch(), "setting the InMatch attribute puts the client in a match")
check(MobileControls.areButtonsBound(), "the touch buttons appear when the match starts")

local EXPECTED_BUTTONS = {
	LaserTagFire = "fire",
	LaserTagReload = "reload",
	LaserTagSwitch = "switch weapon",
	LaserTagView = "change view",
}

for action, what in EXPECTED_BUTTONS do
	local bound = Env.boundActions[action]
	check(bound ~= nil, `a phone gets a {what} button`)
	if bound then
		check(bound.touchButton, `the {what} binding actually draws a touch button`)
		check(
			type(bound.title) == "string" and #bound.title > 0,
			`the {what} button is labelled (got {tostring(bound.title)})`
		)
		check(bound.position ~= nil, `the {what} button is positioned`)
	end
end

-- Two buttons in the same place means one of them cannot be pressed.
local seen = {}
for action, bound in Env.boundActions do
	if bound.position then
		local key = `{bound.position.X.Scale},{bound.position.Y.Scale}`
		check(seen[key] == nil, `{action} does not sit exactly on top of {tostring(seen[key])}`)
		seen[key] = action

		check(
			bound.position.X.Scale >= 0
				and bound.position.X.Scale <= 1
				and bound.position.Y.Scale >= 0
				and bound.position.Y.Scale <= 1,
			`{action} is positioned on screen ({bound.position.X.Scale}, {bound.position.Y.Scale})`
		)
	end
end

-- The trigger is held down for whole firefights by a thumb that also has to
-- shift around; the engine's uniform ~70px default is too small for that, and
-- too big for actions you must not hit by accident.
local ContextActionService = Env.service("ContextActionService")
local fireButton = ContextActionService:GetButton("LaserTagFire")
local viewButton = ContextActionService:GetButton("LaserTagView")

check(fireButton ~= nil, "the fire action has a real touch button")
if fireButton and viewButton then
	check(
		fireButton.Size.X.Offset > viewButton.Size.X.Offset,
		`the fire button is bigger than the deliberate ones `
			.. `(fire {fireButton.Size.X.Offset}, view {viewButton.Size.X.Offset})`
	)
	check(
		fireButton.Size.X.Offset >= 90,
		`the fire button is big enough for a child's thumb (got {fireButton.Size.X.Offset}px)`
	)
end

--------------------------------------------------------------------------------
-- The buttons do what they are labelled
--------------------------------------------------------------------------------

heading("Pressing things")

-- Held, not tapped: an automatic weapon whose trigger only registers on release
-- would pass a press-and-let-go check and be useless in a fight.
Env.pressAction("LaserTagFire", true)
check(InputController.isFireHeld(), "holding the fire button holds the trigger")
Env.releaseAction("LaserTagFire")
check(not InputController.isFireHeld(), "letting go of the fire button releases the trigger")

local reloadSeen = false
local reloadConn = InputController.ReloadPressed:Connect(function()
	reloadSeen = true
end)
Env.pressAction("LaserTagReload")
check(reloadSeen, "the reload button asks for a reload")
reloadConn:Disconnect()

local slotSeen: number? = nil
local slotConn = InputController.SlotPressed:Connect(function(slot: number)
	slotSeen = slot
end)
Env.pressAction("LaserTagSwitch")
check(
	slotSeen ~= nil and slotSeen ~= ClientState.currentSlot,
	`the switch button picks another slot (got {tostring(slotSeen)})`
)
slotConn:Disconnect()

-- The one that was cosmetic. It flipped the saved preference and moved nothing,
-- so the stored setting disagreed with the screen and followed the player to
-- their desktop. Assert the camera, not the preference.
local beforeMode = player.CameraMode
local beforeZoom = player.CameraMaxZoomDistance

Env.pressAction("LaserTagView")
check(
	PerspectiveController.get() == PerspectiveController.FIRST,
	`the view button switches the perspective (got {PerspectiveController.get()})`
)
check(
	player.CameraMaxZoomDistance ~= beforeZoom,
	`the view button MOVES THE CAMERA, not just the setting ({cameraState()})`
)
check(
	player.CameraMode == roblox.Enum.CameraMode.LockFirstPerson,
	`first person on a phone means LockFirstPerson ({cameraState()})`
)

Env.pressAction("LaserTagView")
check(PerspectiveController.get() == PerspectiveController.THIRD, "the view button switches back")
check(
	player.CameraMode == beforeMode and player.CameraMaxZoomDistance == beforeZoom,
	`switching back restores the camera exactly ({cameraState()})`
)

--------------------------------------------------------------------------------
-- Controls get out of the way
--------------------------------------------------------------------------------

heading("Menus and match end")

Env.pressAction("LaserTagFire", true)
check(InputController.isFireHeld(), "trigger held before the menu opens")

-- A stand-in for a real screen: UIController only ever asks a handle whether it
-- is open, so this exercises the same path the shop does.
local shopOpen = false
UIController.registerMenu("Shop", {
	open = function()
		shopOpen = true
	end,
	close = function()
		shopOpen = false
	end,
	isOpen = function()
		return shopOpen
	end,
})

UIController.openMenu("Shop")
check(UIController.isAnyMenuOpen(), "the stand-in menu counts as open")
check(not MobileControls.areButtonsBound(), "the touch buttons go away while a menu is open")
check(
	not InputController.isFireHeld(),
	"the trigger is released when the buttons vanish, so the gun does not fire behind the shop"
)

UIController.closeMenu("Shop")
check(MobileControls.areButtonsBound(), "the touch buttons come back when the menu closes")

player:SetAttribute("InMatch", "")
check(not ClientState.isInMatch(), "clearing the attribute leaves the match")
check(not MobileControls.areButtonsBound(), "no fire button in the hub")

--------------------------------------------------------------------------------
-- A touchscreen laptop is not a phone
--
-- The device test is "touch AND no mouse", not "touch". Someone on a Surface or
-- a touchscreen MacBook has a cursor and expects to keep it; treating them as a
-- phone would take the mouse away from a player who is holding one. This is the
-- regression the phone work is most likely to cause, so it gets its own boot.
--------------------------------------------------------------------------------

heading("Touchscreen laptop")

Env.setDevice("touchLaptop")
Env.reset()

local laptopOk, laptopErr = pcall(function()
	Env.enableClientRuntime()
	local State = Env.load("src/client/ClientState")
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Settings = Env.load("src/client/Controllers/SettingsController")
	local MouseLock = Env.load("src/client/Controllers/MouseLockController")

	State.init()
	Perspective.init()
	Settings.init()
	MouseLock.init()

	check(State.isTouch, "a touchscreen laptop still reports touch")
	check(MouseLock.isEnabled(), "a touchscreen laptop keeps its cursor manager")
end)
check(laptopOk, `the touchscreen laptop boots: {tostring(laptopErr)}`)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} mobile check(s) failed`, 0)
end
print("  All mobile checks passed.")
