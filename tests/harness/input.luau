--!nonstrict
--[[
	tests/harness/input.luau
	What a player can do with the hardware they actually hold.

	Two things live here because both are about the gap between "the engine gave
	the player a default" and "the game works":

	  * a controller. Roblox's own controls give a pad player movement, jump and
	    camera, and nothing else: firing, reloading, switching weapons, the
	    scoreboard and every menu were keyboard- and mouse-only, so a pad player
	    could run around a match and not play it.

	  * the character's facing in third person. The engine turns a character to
	    its movement direction unless something tells it otherwise, so the body
	    pointed one way while the beam left the head toward the crosshair. Enemies
	    read a player's aim off their body; a body that lies about it is a
	    competitive problem, not a cosmetic one.

	Run:  lune run tests/harness/input
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
-- Boot the client as a console
--------------------------------------------------------------------------------

heading("Booting a controller-only client")

Env.setDevice("gamepad")
Env.enableClientRuntime()

local Enum = roblox.Enum
local Vector3 = roblox.Vector3
local CFrame = roblox.CFrame

local UserInputService = Env.service("UserInputService")
local player = Env.service("Players").LocalPlayer

local ClientState = Env.load("src/client/ClientState")
local InputController = Env.load("src/client/Controllers/InputController")
local PerspectiveController = Env.load("src/client/Controllers/PerspectiveController")
local SettingsController = Env.load("src/client/Controllers/SettingsController")
local UIController = Env.load("src/client/UI/UIController")
local MouseLockController = Env.load("src/client/Controllers/MouseLockController")
local WeaponClient = Env.load("src/client/Controllers/WeaponClient")
local CharacterAnimator = Env.load("src/client/Controllers/CharacterAnimator")

local CONTROLLERS = {
	{ name = "ClientState", module = ClientState },
	{ name = "InputController", module = InputController },
	{ name = "PerspectiveController", module = PerspectiveController },
	{ name = "SettingsController", module = SettingsController },
	{ name = "UIController", module = UIController },
	{ name = "MouseLockController", module = MouseLockController },
	{ name = "WeaponClient", module = WeaponClient },
	{ name = "CharacterAnimator", module = CharacterAnimator },
}

-- A living character in a running match, so the gun may be used at all.
local function newCharacter(): any
	local model = roblox.Instance.new("Model")
	model.Name = "Character"
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	-- Lune's Humanoid carries no default for these; a real one spawns standing
	-- and turning to its walk.
	humanoid.Sit = false
	humanoid.AutoRotate = true
	humanoid.Parent = model
	local root = roblox.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Position = Vector3.new(0, 5, 0)
	root.Parent = model
	model.PrimaryPart = root
	return model
end

local character = newCharacter()
player.Character = character

for _, entry in CONTROLLERS do
	if type(entry.module.init) == "function" then
		local ok, err = pcall(entry.module.init)
		check(ok, `{entry.name} initialises on a controller-only client: {tostring(err)}`)
	end
end
for _, entry in CONTROLLERS do
	if type(entry.module.start) == "function" then
		local ok, err = pcall(entry.module.start)
		check(ok, `{entry.name} starts on a controller-only client: {tostring(err)}`)
	end
end

player:SetAttribute("InMatch", "Dust")
player:SetAttribute("CurrentWeapon", "Rifle")
ClientState.match.phase = "InProgress"
ClientState.isDead = false
for _ = 1, 3 do
	UIController.closeAll()
end

--------------------------------------------------------------------------------
-- Controller input
--------------------------------------------------------------------------------

heading("Controller")

check(UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled, "the device is a pad and nothing else")

local function padDown(keyCode: string, gameProcessed: boolean?): any
	local input = {
		UserInputType = Enum.UserInputType.Gamepad1,
		KeyCode = (Enum.KeyCode :: any)[keyCode],
		UserInputState = Enum.UserInputState.Begin,
	}
	UserInputService.InputBegan:Fire(input, gameProcessed == true)
	return input
end

local function padUp(input: any)
	input.UserInputState = Enum.UserInputState.End
	UserInputService.InputEnded:Fire(input, false)
end

-- The right trigger is the trigger, and it is held: an automatic weapon that
-- only registered on release would pass a tap and be useless in a fight.
local trigger = padDown("ButtonR2")
check(InputController.isFireHeld(), "holding the right trigger holds the trigger")
padUp(trigger)
check(not InputController.isFireHeld(), "letting go of it releases the trigger")

-- gameProcessed is how the engine says a focused GUI (a selected button, a text
-- box) owns the press. Firing behind a menu the player is navigating is the bug.
local swallowed = padDown("ButtonR2", true)
check(not InputController.isFireHeld(), "a trigger pull the GUI already consumed does not fire")
padUp(swallowed)

-- A pad that is unplugged mid-burst never sends the release.
local held = padDown("ButtonR2")
check(InputController.isFireHeld(), "the trigger is held again")
UserInputService.GamepadDisconnected:Fire(Enum.UserInputType.Gamepad1)
check(not InputController.isFireHeld(), "unplugging the pad mid-burst lets go of the trigger")
padUp(held)

local reloads = 0
local reloadConn = InputController.ReloadPressed:Connect(function()
	reloads += 1
end)
padUp(padDown("ButtonX"))
check(reloads == 1, `X reloads (got {reloads})`)
padDown("ButtonX", true)
check(reloads == 1, "X pressed into a GUI does not reload")
reloadConn:Disconnect()

local slots: { number } = {}
local slotConn = InputController.SlotPressed:Connect(function(slot: number)
	table.insert(slots, slot)
end)

check(ClientState.ammo.weaponId == "Rifle", "the rifle is in hand to begin with")
padDown("ButtonR1")
check(slots[#slots] == 2, `the right bumper goes to the next slot (got {tostring(slots[#slots])})`)
-- Deliberately no server echo in between: the second press has to build on the
-- weapon the player is now SEEING, not on the one the server last confirmed.
padDown("ButtonR1")
check(
	slots[#slots] == 3,
	`pressing it again before the server answers reaches the third slot (got {tostring(slots[#slots])})`
)
check(WeaponClient.getWeaponId() == "Lance", `and the lance is really in hand (holding {WeaponClient.getWeaponId()})`)
padDown("ButtonR1")
check(slots[#slots] == 1, `the next slot wraps round to the first (got {tostring(slots[#slots])})`)
padDown("ButtonL1")
check(slots[#slots] == 3, `the left bumper goes back, wrapping to the last slot (got {tostring(slots[#slots])})`)
padDown("ButtonL1", true)
check(#slots == 4, "a bumper pressed into a GUI does not switch")
slotConn:Disconnect()

local menus: { string } = {}
local menuConn = InputController.MenuToggled:Connect(function(name: string)
	table.insert(menus, name)
end)
for keyCode, menu in
	{ ButtonY = "Equip", DPadUp = "Shop", DPadRight = "Friends", DPadDown = "Spin", DPadLeft = "Settings" }
do
	menus = {}
	padDown(keyCode)
	check(menus[1] == menu and #menus == 1, `{keyCode} toggles {menu} (got {tostring(menus[1])})`)
	menus = {}
	padDown(keyCode, true)
	check(#menus == 0, `{keyCode} is left alone when a GUI selection owns it`)
end
menuConn:Disconnect()

local board: { boolean } = {}
local boardConn = InputController.ScoreboardHeld:Connect(function(isHeld: boolean)
	table.insert(board, isHeld)
end)
local view = padDown("ButtonSelect")
check(board[#board] == true, "holding View shows the scoreboard")
padUp(view)
check(board[#board] == false, "letting go hides it again")
boardConn:Disconnect()

-- Nothing on the keyboard path may have leaked into the pad: ButtonA jumps and
-- ButtonB backs out of GUI selection, both Roblox's, neither ours.
local before = #slots + reloads + #menus
padUp(padDown("ButtonA"))
padUp(padDown("ButtonB"))
padUp(padDown("Thumbstick1"))
check(#slots + reloads + #menus == before, "A, B and the sticks stay Roblox's")

--------------------------------------------------------------------------------
-- A pad player is not stranded by the menus
--------------------------------------------------------------------------------

heading("Menus on a controller")

-- The invisible full-screen button that frees the cursor must never be a target
-- for GUI selection: with a pad, the first stick movement auto-selects the
-- first selectable thing on screen, and a selected full-screen button draws a
-- selection box round the whole view and swallows the pad's A press.
--[[
	The Select button is bound to the scoreboard hold, and GuiService's automatic
	selection makes that same button pick a GUI object (gameProcessed = true),
	which would swallow the hold whenever a Selectable HUD button exists. So
	automatic selection is off while nothing is open and comes back with a panel,
	where navigating is the point.
]]
local GuiService = Env.service("GuiService")
check(GuiService.AutoSelectGuiEnabled == false, "with no menu open, the Select button is left to the scoreboard")

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
check(MouseLockController.isUnlocked(), "opening a menu frees the cursor manager on a pad too")
check(GuiService.AutoSelectGuiEnabled == true, "a panel gets GUI selection back so the pad can navigate it")
GuiService.SelectedObject = roblox.Instance.new("TextButton")
check(not InputController.isFireHeld(), "and the trigger is not live behind it")
local modalScreen = UIController.getScreenRoot("CursorModal")
local modal = modalScreen and modalScreen:FindFirstChild("ModalCapture")
check(modal ~= nil, "the cursor-freeing button exists")
if modal then
	check(not modal.Selectable, "the cursor-freeing button cannot be picked by GUI selection")
end
padDown("ButtonR2")
check(not InputController.isFireHeld(), "the trigger does nothing while a menu is open")

-- With a panel open the D-pad is the panel's own navigation. Nothing is selected
-- until the first press, so that press reaches us unclaimed; it must not also
-- open some other menu on top of the one being navigated.
local openedWhileOpen: { string } = {}
local navConn = InputController.MenuToggled:Connect(function(name: string)
	table.insert(openedWhileOpen, name)
end)
padDown("ButtonR2")
padDown("DPadDown")
padDown("DPadLeft")
navConn:Disconnect()
check(#openedWhileOpen == 0, `the D-pad opens no menu while one is open (opened {table.concat(openedWhileOpen, ",")})`)

-- Y is the way out: a pad has no cursor to click the X with and B only backs
-- out of GUI selection.
padUp(padDown("ButtonY"))
check(not shopOpen, "Y closes the open menu")
check(not MouseLockController.isUnlocked(), "and the view is back")
check(GuiService.AutoSelectGuiEnabled == false, "and the Select button belongs to the scoreboard again")
check(GuiService.SelectedObject == nil, "and nothing stays selected behind the HUD")

--------------------------------------------------------------------------------
-- The invisible touch padding is not a stop for the pad
--------------------------------------------------------------------------------

heading("Button hit padding")

do
	local Button = Env.load("src/client/UI/Components/Button")
	local holder = roblox.Instance.new("ScreenGui")
	local padded = Button.create({ text = "X", parent = holder, hitPadding = roblox.Rect.new(8, 11, 14, 11) })
	check(padded.hit ~= nil, "a padded button has a hit area")
	if padded.hit then
		check(not padded.hit.Selectable, "the padding is not something GUI selection can land on")
	end
	check(padded.instance.Selectable, "the button itself can still be selected")
	padded:destroy()
end

--------------------------------------------------------------------------------
-- The controls list tells a pad player what their pad does
--------------------------------------------------------------------------------

heading("Controls list")

local SettingsScreen = Env.load("src/client/UI/Screens/SettingsScreen")
local settingsOk, settingsErr = pcall(SettingsScreen.init)
check(settingsOk, `the settings panel builds on a controller-only client: {tostring(settingsErr)}`)

local function findNamed(root: any, name: string): any
	for _, descendant in root:GetDescendants() do
		if descendant.Name == name then
			return descendant
		end
	end
	return nil
end

local settingsGui = UIController.getScreen("SettingsMenu")
if settingsGui then
	local padList = findNamed(settingsGui, "PadKeys")
	local keyList = findNamed(settingsGui, "Keys")
	check(padList ~= nil and padList.Visible, "a pad-only device is shown its pad controls")
	check(keyList ~= nil and not keyList.Visible, "and not a list of keys it does not have")

	if padList then
		local fire = findNamed(padList, "Огонь")
		local fireKey = fire and findNamed(fire, "Keys")
		check(fireKey ~= nil and fireKey.Text == "RT", "the list says fire is the right trigger")
		check(findNamed(padList, "Перезарядка") ~= nil, "and lists reload")
		check(findNamed(padList, "Магазин") ~= nil, "and the menus")

		-- Reached by a pad plugged in after the panel was built.
		UserInputService.GamepadEnabled = false
		UserInputService.GamepadDisconnected:Fire(Enum.UserInputType.Gamepad1)
		check(not padList.Visible, "unplugging the last pad takes its list away")
		UserInputService.GamepadEnabled = true
		UserInputService.GamepadConnected:Fire(Enum.UserInputType.Gamepad1)
		check(padList.Visible, "and plugging one in brings it back")
	end
else
	check(false, "the settings panel has a screen")
end

--------------------------------------------------------------------------------
-- Third person: the body faces where the player aims
--------------------------------------------------------------------------------

heading("Facing")

local humanoid = character:FindFirstChildOfClass("Humanoid")
local root = character:FindFirstChild("HumanoidRootPart")
local camera = Env.service("Workspace").CurrentCamera

local function aimAt(yawDegrees: number, pitchDegrees: number?)
	local yaw = math.rad(yawDegrees)
	local pitch = math.rad(pitchDegrees or 0)
	local look = Vector3.new(-math.sin(yaw) * math.cos(pitch), math.sin(pitch), -math.cos(yaw) * math.cos(pitch))
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 8, 0), Vector3.new(0, 8, 0) + look)
end

-- The flat direction two look vectors share, as a cosine: 1 is the same way.
local function flatDot(a: any, b: any): number
	local fa = Vector3.new(a.X, 0, a.Z)
	local fb = Vector3.new(b.X, 0, b.Z)
	if fa.Magnitude < 1e-6 or fb.Magnitude < 1e-6 then
		return 0
	end
	return fa.Unit:Dot(fb.Unit)
end

local function frames(count: number)
	for _ = 1, count do
		local errors = Env.stepRender()
		check(#errors == 0, `no render binding threw ({#errors > 0 and errors[1].err or ""})`)
	end
end

check(PerspectiveController.get() == PerspectiveController.THIRD, "the default view is third person")
check(ClientState.isInMatch(), "the client is in a match")
check(humanoid ~= nil and root ~= nil, "the test character has a humanoid and a root")

root.CFrame = CFrame.lookAt(Vector3.new(0, 5, 0), Vector3.new(5, 5, 0)) -- facing +X
aimAt(0) -- camera looks down -Z
frames(3)
check(
	flatDot(root.CFrame.LookVector, camera.CFrame.LookVector) > 0.999,
	"a still player's body turns to the crosshair, not to where it last walked"
)
check(not humanoid.AutoRotate, "the humanoid stops turning to face its own movement")
check(
	math.abs(root.CFrame.Position.Y - 5) < 1e-3 and math.abs(root.CFrame.LookVector.Y) < 1e-3,
	"the turn is a pure yaw: the body stays upright and where it was"
)

aimAt(90, 30)
frames(3)
check(
	flatDot(root.CFrame.LookVector, camera.CFrame.LookVector) > 0.999,
	"swinging the camera 90 degrees swings the body with it, whatever the pitch"
)
check(math.abs(root.CFrame.LookVector.Y) < 1e-3, "looking up does not tip the body back")

aimAt(90, 89.9)
local beforeStraightUp = root.CFrame.LookVector
frames(2)
check(
	flatDot(root.CFrame.LookVector, beforeStraightUp) > 0.999,
	"looking almost straight up does not spin the body on a degenerate direction"
)
aimAt(90, 90)
frames(2)
check(
	flatDot(root.CFrame.LookVector, beforeStraightUp) > 0.999 and root.CFrame.LookVector.Magnitude > 0.99,
	"looking exactly straight up leaves the facing alone"
)

-- The cursor is free while a menu is open: the player is reading, not aiming,
-- and a body that spun when they right-drag the view over a shop is a bug.
aimAt(0)
UIController.openMenu("Shop")
frames(3)
check(humanoid.AutoRotate, "with a menu open the humanoid goes back to its own turning")
check(
	flatDot(root.CFrame.LookVector, camera.CFrame.LookVector) < 0.5,
	"and the body is not dragged round by the camera behind the menu"
)
UIController.closeMenu("Shop")
frames(3)
check(
	flatDot(root.CFrame.LookVector, camera.CFrame.LookVector) > 0.999 and not humanoid.AutoRotate,
	"closing the menu picks the aim up again"
)

-- The Right Ctrl unlock is the same thing without a menu.
InputController.setMouseUnlocked(true)
aimAt(180)
frames(3)
check(humanoid.AutoRotate, "with the cursor toggled free the humanoid is left alone")
InputController.setMouseUnlocked(false)
frames(2)
check(not humanoid.AutoRotate, "and locking it again takes over")

-- First person: the engine already faces the camera, and two writers to one
-- CFrame is how a body jitters.
aimAt(0)
frames(2)
InputController.PerspectiveToggled:Fire()
check(PerspectiveController.isFirstPerson(), "the view is now first person")
frames(2)
check(humanoid.AutoRotate, "in first person the humanoid is handed back to the engine")
aimAt(120)
local firstPersonFacing = root.CFrame.LookVector
frames(2)
check(flatDot(root.CFrame.LookVector, firstPersonFacing) > 0.999, "and this module writes no yaw of its own there")
InputController.PerspectiveToggled:Fire()
frames(2)
check(not humanoid.AutoRotate, "back in third person it takes over again")

-- The hub is a place to wander, not a firefight.
player:SetAttribute("InMatch", "")
aimAt(45)
frames(2)
check(humanoid.AutoRotate, "in the hub the humanoid turns the way it walks")
player:SetAttribute("InMatch", "Dust")
frames(2)
check(not humanoid.AutoRotate, "and a match takes over the facing")

-- Sitting is the engine's: a seat owns the body.
humanoid.Sit = true
aimAt(200)
local seatedFacing = root.CFrame.LookVector
frames(2)
check(flatDot(root.CFrame.LookVector, seatedFacing) > 0.999, "a seated character is not turned")
humanoid.Sit = false
frames(1)

-- Death. The Died signal is inert in this sandbox, so the per-frame test is
-- what is exercised, which is also what makes it robust to a missed signal.
ClientState.isDead = true
aimAt(10)
frames(2)
check(humanoid.AutoRotate, "a dead player's humanoid is handed back")
ClientState.isDead = false

-- Respawn: a new character, and the old one's settings do not leak into it.
local respawned = newCharacter()
local respawnedHumanoid = respawned:FindFirstChildOfClass("Humanoid")
local respawnedRoot = respawned:FindFirstChild("HumanoidRootPart")
frames(1)
humanoid.Health = 0
player.Character = respawned
player.CharacterAdded:Fire(respawned)
check(respawnedHumanoid.AutoRotate, "a fresh character starts with its own turning")
aimAt(-70)
frames(3)
check(
	flatDot(respawnedRoot.CFrame.LookVector, camera.CFrame.LookVector) > 0.999,
	"the new character is aimed as soon as it lives"
)
check(not respawnedHumanoid.AutoRotate, "and taken over")

-- stop() must leave the humanoid as it found it.
CharacterAnimator.stop()
check(respawnedHumanoid.AutoRotate, "stopping the animator hands the humanoid back")

--------------------------------------------------------------------------------
-- The welcome card on a pad
--
-- It used to describe a keyboard to someone holding a controller.
--------------------------------------------------------------------------------

heading("The welcome card on a controller")

do
	local Welcome = Env.load("src/client/UI/Screens/WelcomeScreen")
	Welcome.init()

	local words = {}
	local welcomeRoot = UIController.getScreenRoot("WelcomeMenu")
	for _, descendant in (welcomeRoot and welcomeRoot:GetDescendants()) or {} do
		if descendant.ClassName == "TextLabel" then
			words[descendant.Text] = true
		end
	end

	check(next(words) ~= nil, "the welcome card is built")
	check(words["RT"] == true, "it says which trigger fires")
	check(words["X"] == true, "and which button reloads")
	check(words["LB  ·  RB"] == true, "and which bumpers change weapon")
	check(words["W A S D  ·  Space"] == nil, "and does not describe a keyboard")
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
	error(`{failed} input check(s) failed`, 0)
end
print("  All input checks passed.")
