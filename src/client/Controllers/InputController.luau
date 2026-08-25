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
	  MenuToggled        (name: "Equip" | "Shop" | "Friends" | "Spin")
	  MouseUnlockToggled (unlocked: boolean)
	  ScoreboardHeld     (isHeld: boolean)

	Mobile buttons are deliberately not bound here — the touch HUD publishes the
	same Signals through the fire/reload helpers below.
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

local InputController = {}
InputController.Priority = 2

local KEYBINDS = Constants.KEYBINDS
local MENU_BINDS = { Equip = "Equip", Shop = "Shop", Friends = "Friends", Spin = "Spin" }

local trove = Trove.new()
local fireHeld = false
local fireSuppressed = false
local mouseUnlocked = false
local scoreboardHeld = false

-- KeyCode -> zero-argument action, built once in init() from Constants.KEYBINDS.
local keyDownActions: { [Enum.KeyCode]: () -> () } = {}
local keyUpActions: { [Enum.KeyCode]: () -> () } = {}

InputController.FirePressed = Signal.new()
InputController.FireReleased = Signal.new()
InputController.ReloadPressed = Signal.new()
InputController.SlotPressed = Signal.new()
InputController.MenuToggled = Signal.new()
InputController.MouseUnlockToggled = Signal.new()
InputController.ScoreboardHeld = Signal.new()

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

	bind("Slot1", function()
		InputController.SlotPressed:Fire(1)
	end)

	bind("Slot2", function()
		InputController.SlotPressed:Fire(2)
	end)

	for bindName, menuName in MENU_BINDS do
		bind(bindName, function()
			InputController.MenuToggled:Fire(menuName)
		end)
	end

	bind("MouseUnlock", function()
		InputController.setMouseUnlocked(not mouseUnlocked)
	end)

	bind("Scoreboard", function()
		if scoreboardHeld then
			return
		end
		scoreboardHeld = true
		InputController.ScoreboardHeld:Fire(true)
	end, function()
		if not scoreboardHeld then
			return
		end
		scoreboardHeld = false
		InputController.ScoreboardHeld:Fire(false)
	end)

	trove:Connect(UserInputService.InputBegan, onInputBegan)
	trove:Connect(UserInputService.InputEnded, onInputEnded)

	-- Losing window focus mid-burst must not leave the trigger held: InputEnded
	-- does not fire for inputs that end outside the Roblox window.
	trove:Connect(UserInputService.WindowFocusReleased, function()
		InputController.releaseFire()
		if scoreboardHeld then
			scoreboardHeld = false
			InputController.ScoreboardHeld:Fire(false)
		end
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
