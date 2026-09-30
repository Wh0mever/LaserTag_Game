--!nonstrict
--[[
	InputController.luau
	The only module in the client that binds raw keys. Everything else subscribes
	to the Signals below, so a rebind is a Constants.KEYBINDS edit rather than a
	search across every screen.

	Signals:
	  FirePressed        ()
	  FireReleased       ()
	  ReloadPressed      ()
	  SlotPressed        (slot: number)
	  MenuToggled        (name: "Equip" | "Shop" | "Friends" | "Spin" | "Settings")
	  MouseUnlockToggled (unlocked: boolean)
	  PerspectiveToggled ()
	  ScoreboardHeld     (isHeld: boolean)
	  MenuCloseRequested ()   pad only: Y while a menu is open

	Mobile buttons are deliberately not bound here — the touch HUD publishes the
	same Signals through the fire/reload helpers below.

	A controller is bound here too, through those same actions. Roblox's default
	controls give a pad movement, jump and camera and nothing else, so without
	this a pad player could run round a match and not play it. What is NOT bound
	is deliberate: ButtonA (jump), ButtonB (backs out of GUI selection) and the
	sticks belong to Roblox, and the D-pad only reaches us while no GUI selection
	owns it (gameProcessed), so it opens menus without ever stealing navigation
	from one that is open.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local InputController = {}
InputController.Priority = 2

local KEYBINDS = Constants.KEYBINDS
local MENU_BINDS = { Equip = "Equip", Shop = "Shop", Friends = "Friends", Spin = "Spin", Settings = "Settings" }

local trove = Trove.new()
local fireHeld = false
local fireSuppressed = false
local mouseUnlocked = false
local scoreboardHeld = false

-- KeyCode -> zero-argument action, built once in init() from Constants.KEYBINDS.
local keyDownActions: { [Enum.KeyCode]: () -> () } = {}
local keyUpActions: { [Enum.KeyCode]: () -> () } = {}

-- Pad KeyCode.Value -> zero-argument action, built once in init(). Kept apart
-- from the keyboard tables: a pad has no rebinding. Keyed by the enum's number
-- rather than the item, which is the same thing in Roblox and the only form that
-- also looks up correctly in the test sandbox, whose EnumItems are not interned.
local padDownActions: { [number]: () -> () } = {}
local padUpActions: { [number]: () -> () } = {}

InputController.FirePressed = Signal.new()
InputController.FireReleased = Signal.new()
InputController.ReloadPressed = Signal.new()
InputController.SlotPressed = Signal.new()
InputController.MenuToggled = Signal.new()
InputController.MouseUnlockToggled = Signal.new()
InputController.PerspectiveToggled = Signal.new()
InputController.ScoreboardHeld = Signal.new()
InputController.MenuCloseRequested = Signal.new()

--[[
	Constants.KEYBINDS stores KeyCode *names*; an unknown name would otherwise
	throw from a module body and take the whole controller boot down with it.
]]
local function keyCodeFor(bindName: string): Enum.KeyCode?
	local name = KEYBINDS[bindName]
	if type(name) ~= "string" then
		warn(`[InputController] keybind "{bindName}" is missing from Constants.KEYBINDS`)
		return nil
	end

	local ok, keyCode = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if not ok or typeof(keyCode) ~= "EnumItem" then
		warn(`[InputController] "{name}" is not a valid Enum.KeyCode`)
		return nil
	end

	return keyCode
end

local function bind(bindName: string, onDown: (() -> ())?, onUp: (() -> ())?)
	local keyCode = keyCodeFor(bindName)
	if not keyCode then
		return
	end

	if onDown then
		keyDownActions[keyCode] = onDown
	end
	if onUp then
		keyUpActions[keyCode] = onUp
	end
end

--------------------------------------------------------------------------------
-- Fire
--------------------------------------------------------------------------------

function InputController.isFireHeld(): boolean
	return fireHeld and not fireSuppressed
end

--[[
	Publish a fire press. Also used by the touch HUD so mobile and desktop go
	through exactly one code path.
]]
function InputController.pressFire()
	if fireHeld or fireSuppressed then
		return
	end
	fireHeld = true
	InputController.FirePressed:Fire()
end

function InputController.releaseFire()
	if not fireHeld then
		return
	end
	fireHeld = false
	InputController.FireReleased:Fire()
end

--[[
	Blocks fire input without unbinding it. MouseLockController calls this while
	the cursor is free (menu open or the player toggled unlock) so a click on the
	shop never also empties a magazine.
]]
function InputController.setFireSuppressed(suppressed: boolean)
	suppressed = suppressed == true
	if suppressed == fireSuppressed then
		return
	end

	fireSuppressed = suppressed
	if suppressed then
		InputController.releaseFire()
	end
end

--------------------------------------------------------------------------------
-- Slot cycling
--------------------------------------------------------------------------------

--[[
	The slot of the weapon the player is looking at. ClientState.currentSlot is
	NOT that: it follows the server's CurrentWeapon attribute, so for one round
	trip after a switch it still names the old weapon. ClientState.ammo is
	republished by WeaponClient the instant it adopts a weapon locally (and again
	after every server sync, which it reconciles synchronously), so it names the
	weapon in hand.
]]
local function shownSlot(): number
	local weaponId = ClientState.ammo and ClientState.ammo.weaponId
	if WeaponConfig.exists(weaponId) then
		return WeaponConfig.get(weaponId).slot
	end
	return ClientState.currentSlot
end

--[[
	Publishes SlotPressed for the slot `step` places from the one on screen,
	wrapping at both ends. Built on the shown weapon so two quick presses reach
	the third slot instead of asking for the second one twice, which the weapon
	client would drop as "already holding it".
]]
function InputController.cycleSlot(step: number)
	local count = #Constants.SLOTS
	if count == 0 then
		return
	end

	local slot = ((shownSlot() - 1 + step) % count) + 1
	InputController.SlotPressed:Fire(slot)
end

--------------------------------------------------------------------------------
-- Mouse unlock toggle
--------------------------------------------------------------------------------

function InputController.isMouseUnlocked(): boolean
	return mouseUnlocked
end

--[[
	The toggle state only — MouseLockController owns the effective state, because
	an open menu forces the cursor free regardless of this value.
]]
function InputController.setMouseUnlocked(unlocked: boolean)
	unlocked = unlocked == true
	if unlocked == mouseUnlocked then
		return
	end

	mouseUnlocked = unlocked
	InputController.MouseUnlockToggled:Fire(unlocked)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function scoreboardDown()
	if scoreboardHeld then
		return
	end
	scoreboardHeld = true
	InputController.ScoreboardHeld:Fire(true)
end

local function scoreboardUp()
	if not scoreboardHeld then
		return
	end
	scoreboardHeld = false
	InputController.ScoreboardHeld:Fire(false)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	-- gameProcessed is true while the chat bar or any focused TextBox owns the
	-- keystroke; ignoring it is what keeps typing "reload" from reloading.
	if gameProcessed then
		return
	end

	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		InputController.pressFire()
		return
	end

	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		local padAction = padDownActions[input.KeyCode.Value]
		if padAction then
			padAction()
		end
		return
	end

	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local action = keyDownActions[input.KeyCode]
	if action then
		action()
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	-- Releases are always honoured. A release swallowed by gameProcessed (the
	-- cursor moved over a button mid-burst) would leave the gun held down.
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		InputController.releaseFire()
		return
	end

	if input.UserInputType == Enum.UserInputType.Gamepad1 then
		local padAction = padUpActions[input.KeyCode.Value]
		if padAction then
			padAction()
		end
		return
	end

	if input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end

	local action = keyUpActions[input.KeyCode]
	if action then
		action()
	end
end

function InputController.init()
	ClientState.init()

	bind("Reload", function()
		InputController.ReloadPressed:Fire()
	end)

	-- Bound from Constants.SLOTS rather than one call per slot: adding a weapon
	-- should not need an edit here, and a slot with no keybind would otherwise
	-- be silently unreachable on a keyboard.
	for slot in Constants.SLOTS do
		local bindName = `Slot{slot}`
		if Constants.KEYBINDS[bindName] then
			bind(bindName, function()
				InputController.SlotPressed:Fire(slot)
			end)
		else
			warn(`[InputController] slot {slot} has no {bindName} keybind; it can only be reached by clicking`)
		end
	end

	for bindName, menuName in MENU_BINDS do
		bind(bindName, function()
			InputController.MenuToggled:Fire(menuName)
		end)
	end

	bind("Perspective", function()
		InputController.PerspectiveToggled:Fire()
	end)

	bind("MouseUnlock", function()
		InputController.setMouseUnlocked(not mouseUnlocked)
	end)

	bind("Scoreboard", scoreboardDown, scoreboardUp)

	--[[
		The controller, on the very same actions as the keyboard. The trigger is
		held (press and release), the bumpers walk the slots, View holds the
		scoreboard like Tab, Y and the D-pad open the menus the letter keys open.
		A press that arrives with gameProcessed set — a GUI selection owns it — never
		gets this far, which is what keeps a pad player who is navigating the shop
		from also opening the spin wheel.
	]]
	padDownActions[Enum.KeyCode.ButtonR2.Value] = InputController.pressFire
	padUpActions[Enum.KeyCode.ButtonR2.Value] = InputController.releaseFire
	padDownActions[Enum.KeyCode.ButtonX.Value] = function()
		InputController.ReloadPressed:Fire()
	end
	padDownActions[Enum.KeyCode.ButtonR1.Value] = function()
		InputController.cycleSlot(1)
	end
	padDownActions[Enum.KeyCode.ButtonL1.Value] = function()
		InputController.cycleSlot(-1)
	end
	padDownActions[Enum.KeyCode.ButtonSelect.Value] = scoreboardDown
	padUpActions[Enum.KeyCode.ButtonSelect.Value] = scoreboardUp
	--[[
		Menus. `fireSuppressed` is true exactly while the cursor is free, that is
		while a menu is open (MouseLockController drives it). Then the D-pad is the
		panel's own navigation: a press that the engine's GUI selection has not
		claimed yet (nothing is selected until the first press) must not also open
		a different menu underneath it. Y is the way out instead — with a menu
		open it closes it, and otherwise it opens the skins.
	]]
	padDownActions[Enum.KeyCode.ButtonY.Value] = function()
		if fireSuppressed then
			InputController.MenuCloseRequested:Fire()
		else
			InputController.MenuToggled:Fire(MENU_BINDS.Equip)
		end
	end
	for keyCode, menuName in
		{
			[Enum.KeyCode.DPadUp] = MENU_BINDS.Shop,
			[Enum.KeyCode.DPadRight] = MENU_BINDS.Friends,
			[Enum.KeyCode.DPadDown] = MENU_BINDS.Spin,
			[Enum.KeyCode.DPadLeft] = MENU_BINDS.Settings,
		}
	do
		padDownActions[keyCode.Value] = function()
			if not fireSuppressed then
				InputController.MenuToggled:Fire(menuName)
			end
		end
	end

	trove:Connect(UserInputService.InputBegan, onInputBegan)
	trove:Connect(UserInputService.InputEnded, onInputEnded)

	-- Losing window focus mid-burst must not leave the trigger held: InputEnded
	-- does not fire for inputs that end outside the Roblox window.
	trove:Connect(UserInputService.WindowFocusReleased, function()
		InputController.releaseFire()
		scoreboardUp()
	end)

	-- A pad pulled out mid-burst never sends the release either.
	trove:Connect(UserInputService.GamepadDisconnected, function()
		InputController.releaseFire()
		scoreboardUp()
	end)

	local localPlayer = Players.LocalPlayer
	trove:Connect(localPlayer.CharacterRemoving, function()
		InputController.releaseFire()
	end)
end

function InputController.stop()
	trove:Clean()
end

return InputController
