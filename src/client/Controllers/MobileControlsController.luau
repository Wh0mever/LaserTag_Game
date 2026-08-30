--!nonstrict
--[[
	MobileControlsController.luau
	Touch buttons for fire, reload, weapon switch and view.

	Nothing downstream knows these exist. Each button publishes the exact same
	InputController signal the keyboard and mouse publish — pressFire /
	releaseFire, ReloadPressed, SlotPressed — so WeaponClient contains no mobile
	branch at all, and a change to how firing works can never fix desktop while
	quietly breaking phones.

	The buttons are created by ContextActionService (createTouchButton = true)
	rather than by hand: the engine then owns their layout inside the touch GUI,
	which is what keeps them clear of the movement thumbstick and the jump button
	on every screen size and aspect ratio.

	They are bound only while the player is in a match with no menu open. In the
	hub they would sit on top of the shop and the spin wheel for no reason.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.InputController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local MobileControlsController = {}
-- After WeaponClient (9), whose signals these buttons feed.
MobileControlsController.Priority = 11

local FIRE_ACTION = "LaserTagFire"
local RELOAD_ACTION = "LaserTagReload"
local SWITCH_ACTION = "LaserTagSwitch"
local VIEW_ACTION = "LaserTagView"

-- Positions are relative to the ContextActionService touch frame, which the
-- engine anchors in the bottom-right of the screen. The default jump button owns
-- that frame's bottom-right corner and the movement thumbstick owns the screen's
-- opposite corner, so these three sit up and to the left of the jump button and
-- nowhere near the stick.
local FIRE_POSITION = UDim2.new(0.04, 0, 0.30, 0)
local RELOAD_POSITION = UDim2.new(0.54, 0, 0.02, 0)
local SWITCH_POSITION = UDim2.new(0.02, 0, 0.74, 0)
-- Above reload, in the column furthest from the thumb that holds fire: changing
-- view is deliberate rather than reflexive, so it does not want to be the button
-- a panicking thumb lands on.
local VIEW_POSITION = UDim2.new(0.54, 0, 0.46, 0)

local trove = Trove.new()
local enabled = false
local bound = false

--------------------------------------------------------------------------------
-- Action handlers
--------------------------------------------------------------------------------

local function onFire(_actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		InputController.pressFire()
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		-- Cancel fires when the finger slides off the button; without it the
		-- trigger would stay held for the rest of the life.
		InputController.releaseFire()
	end
	return Enum.ContextActionResult.Sink
end

local function onReload(_actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		InputController.ReloadPressed:Fire()
	end
	return Enum.ContextActionResult.Sink
end

local function onView(_actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		InputController.PerspectiveToggled:Fire()
	end
	return Enum.ContextActionResult.Sink
end

local function onSwitch(_actionName: string, state: Enum.UserInputState): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		-- Cycles rather than toggling so a third slot would need no change here.
		local slots = #Constants.SLOTS
		local nextSlot = slots > 0 and (ClientState.currentSlot % slots) + 1 or Constants.DEFAULT_SLOT
		InputController.SlotPressed:Fire(nextSlot)
	end
	return Enum.ContextActionResult.Sink
end

--------------------------------------------------------------------------------
-- Binding
--------------------------------------------------------------------------------

local function titleForOtherSlot(): string
	local slots = #Constants.SLOTS
	local nextSlot = slots > 0 and (ClientState.currentSlot % slots) + 1 or Constants.DEFAULT_SLOT
	local weaponId = Constants.SLOTS[nextSlot]
	local weapon = WeaponConfig.get(weaponId)
	-- The first word of the display name ("PULSE", "ION") is all a touch button
	-- has room for.
	return weapon and string.match(weapon.displayName, "^%S+") or tostring(weaponId)
end

local function bindAll()
	if bound then
		return
	end
	bound = true

	-- No key codes: on a touch device the button IS the input, and binding a key
	-- as well would double-handle it on a phone with a keyboard attached.
	ContextActionService:BindAction(FIRE_ACTION, onFire, true)
	ContextActionService:SetTitle(FIRE_ACTION, "ОГОНЬ")
	ContextActionService:SetPosition(FIRE_ACTION, FIRE_POSITION)

	ContextActionService:BindAction(RELOAD_ACTION, onReload, true)
	ContextActionService:SetTitle(RELOAD_ACTION, "ПЕРЕЗАР.")
	ContextActionService:SetPosition(RELOAD_ACTION, RELOAD_POSITION)

	ContextActionService:BindAction(SWITCH_ACTION, onSwitch, true)
	ContextActionService:SetTitle(SWITCH_ACTION, titleForOtherSlot())
	ContextActionService:SetPosition(SWITCH_ACTION, SWITCH_POSITION)

	ContextActionService:BindAction(VIEW_ACTION, onView, true)
	ContextActionService:SetTitle(VIEW_ACTION, "ВИД")
	ContextActionService:SetPosition(VIEW_ACTION, VIEW_POSITION)
end

local function unbindAll()
	if not bound then
		return
	end
	bound = false

	-- The button disappears mid-press when a menu opens, so its End never
	-- arrives; releasing here is what stops the gun firing behind the menu.
	InputController.releaseFire()

	ContextActionService:UnbindAction(FIRE_ACTION)
	ContextActionService:UnbindAction(RELOAD_ACTION)
	ContextActionService:UnbindAction(SWITCH_ACTION)
	ContextActionService:UnbindAction(VIEW_ACTION)
end

local function refresh()
	if not enabled then
		return
	end

	if ClientState.isInMatch() and not UIController.isAnyMenuOpen() then
		bindAll()
	else
		unbindAll()
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Whether this device gets touch controls at all. False on desktop, where the
	controller binds nothing.
]]
function MobileControlsController.isActive(): boolean
	return enabled
end

function MobileControlsController.areButtonsBound(): boolean
	return bound
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function MobileControlsController.init()
	ClientState.init()

	enabled = UserInputService.TouchEnabled
	if not enabled then
		return
	end

	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name == "InMatch" then
			refresh()
		end
	end))

	trove:Add(ClientState.SlotChanged:Connect(function()
		if bound then
			ContextActionService:SetTitle(SWITCH_ACTION, titleForOtherSlot())
		end
	end))

	trove:Add(UIController.MenuVisibilityChanged:Connect(refresh))
	trove:Add(function()
		unbindAll()
	end)

	refresh()
end

function MobileControlsController.stop()
	trove:Clean()
	enabled = false
end

return MobileControlsController
