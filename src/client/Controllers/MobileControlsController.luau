--!nonstrict
--[[
	MobileControlsController.luau
	The touch controls: fire, reload, weapon switch and view.

	Nothing downstream knows these exist. Each control publishes the exact same
	InputController signal the keyboard and mouse publish — pressFire /
	releaseFire, ReloadPressed, SlotPressed — so WeaponClient contains no mobile
	branch at all, and a change to how firing works can never fix desktop while
	quietly breaking phones.

	They are shown only while the player is in a match with no menu open. In the
	hub they would sit on top of the shop and the spin wheel for no reason.

	WHY THE FIRE CONTROL IS NOT A BUTTON
	====================================
	This is the whole reason this file does not use ContextActionService's
	generated touch buttons any more.

	On a phone you aim by dragging. Roblox's camera only receives a drag that no
	GUI element has consumed — `gameProcessedEvent` false. A GuiButton, which is
	what ContextActionService creates, consumes the touch that lands on it. So
	the moment the thumb is on the fire button, the camera stops turning: you can
	shoot, or you can aim, never both. In a shooter that is not an inconvenience,
	it is the game not working.

	So the fire control is drawn as an ordinary Frame with Active = false. It
	consumes nothing. The press is detected by hit-testing the touch position
	against the frame's own rectangle, and the very same touch continues on to
	Roblox's camera module, which turns the view. One thumb, both jobs, which is
	how every mobile shooter does it.

	Two consequences worth stating, because they are features and look like bugs:

	  * the trigger is NOT released when the finger slides off the frame. It is
	    released when the finger leaves the glass. Sliding off is what aiming
	    looks like — releasing there would mean you could only shoot while
	    holding perfectly still.
	  * the other three controls ARE real buttons and do consume their touch.
	    They are taps, nothing is being aimed while you press them, and a tap
	    that also nudged the camera would be worse.

	Hit-testing reads AbsolutePosition rather than recomputing the layout, so the
	rectangle is whatever was actually drawn, UIScale included. Every screen here
	sets IgnoreGuiInset = true, which puts AbsolutePosition in the same
	coordinate space as InputObject.Position — both measured from the top-left of
	the display.
]]

local Players = game:GetService("Players")
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
-- After WeaponClient (9), whose signals these controls feed.
MobileControlsController.Priority = 11

--[[
	The cluster, as offsets from the bottom-right corner.

	Roblox draws its own jump button in that corner — roughly 95 pixels across,
	centred about 180 from the right edge and 80 from the bottom — and it is not
	ours to move. Everything here therefore sits further left and higher, and
	tests/harness/mobile.luau asserts the rectangles neither overlap each other
	nor leave the screen on a phone-sized viewport.

	Fire is much the largest. It is held down through a whole firefight by a
	thumb that is also dragging to aim, so it has to stay under the thumb while
	the hand moves; the other three must not be hittable by accident.
]]
local FIRE_SIZE = 128
local ACTION_SIZE = 76

local LAYOUT = {
	{ id = "Fire", size = FIRE_SIZE, x = -276, y = -40, label = "ОГОНЬ" },
	{ id = "Reload", size = ACTION_SIZE, x = -292, y = -192, label = "ПЕРЕЗАР." },
	{ id = "Switch", size = ACTION_SIZE, x = -430, y = -78, label = "" },
	{ id = "View", size = ACTION_SIZE, x = -430, y = -198, label = "ВИД" },
}

local BACKGROUND = Color3.fromRGB(18, 22, 32)
local FIRE_TINT = Color3.fromRGB(236, 92, 116)
local TEXT = Color3.fromRGB(232, 238, 248)

local player = Players.LocalPlayer
local trove = Trove.new()
local enabled = false
local shown = false
local root: Frame? = nil
local controls: { [string]: GuiObject } = {}
local switchLabel: TextLabel? = nil

-- The touch currently holding the trigger. Held as the InputObject rather than
-- a boolean so a second finger elsewhere on the screen cannot release it.
local fireTouch: InputObject? = nil

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function nextSlot(): number
	local slots = #Constants.SLOTS
	return slots > 0 and (ClientState.currentSlot % slots) + 1 or Constants.DEFAULT_SLOT
end

local function titleForOtherSlot(): string
	local weaponId = Constants.SLOTS[nextSlot()]
	local weapon = WeaponConfig.get(weaponId)
	-- The first word of the display name is all a round button has room for.
	return weapon and string.match(weapon.displayName, "^%S+") or tostring(weaponId)
end

--[[
	Whether a screen position falls inside a control.

	Returns false rather than erroring when the layout has not happened yet:
	AbsoluteSize is zero until the GUI has been drawn once, and a touch in that
	window should do nothing rather than match everything.
]]
local function within(gui: GuiObject, position: Vector3): boolean
	local origin = gui.AbsolutePosition
	local size = gui.AbsoluteSize
	if size.X <= 0 or size.Y <= 0 then
		return false
	end

	return position.X >= origin.X
		and position.X <= origin.X + size.X
		and position.Y >= origin.Y
		and position.Y <= origin.Y + size.Y
end

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function circle(parent: Instance, entry, interactive: boolean): GuiObject
	-- A TextButton for the taps, a plain Frame for fire. The class IS the
	-- decision: a button consumes the touch, a Frame lets it reach the camera.
	local node: any = if interactive then Instance.new("TextButton") else Instance.new("Frame")
	node.Name = entry.id
	node.AnchorPoint = Vector2.new(1, 1)
	node.Position = UDim2.new(1, entry.x, 1, entry.y)
	node.Size = UDim2.fromOffset(entry.size, entry.size)
	node.BackgroundColor3 = if interactive then BACKGROUND else FIRE_TINT
	node.BackgroundTransparency = if interactive then 0.28 else 0.18
	node.BorderSizePixel = 0
	node.Active = interactive

	if interactive then
		node.Text = ""
		node.AutoButtonColor = true
	end

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = node

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(120, 200, 255)
	stroke.Thickness = 2
	stroke.Transparency = 0.45
	stroke.Parent = node

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.GothamBold
	label.Text = entry.label
	label.TextColor3 = TEXT
	label.TextSize = if entry.size >= FIRE_SIZE then 20 else 13
	label.TextWrapped = true
	label.Parent = node

	node.Parent = parent
	return node
end

local function build()
	if root then
		return
	end

	local gui = UIController.getScreenGui("TouchControls", Constants.DISPLAY_ORDER.TouchControls)
	if not gui then
		return
	end

	local holder = Instance.new("Frame")
	holder.Name = "Root"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	-- Active false on the container too: a full-screen frame that consumed
	-- touches would take the whole camera away, which is the bug this file
	-- exists to avoid.
	holder.Active = false
	holder.Visible = false
	holder.Parent = gui
	trove:Add(holder)
	root = holder

	for _, entry in LAYOUT do
		local interactive = entry.id ~= "Fire"
		local node = circle(holder, entry, interactive)
		controls[entry.id] = node

		if entry.id == "Switch" then
			switchLabel = node:FindFirstChild("Label") :: TextLabel
		end
	end

	local reload = controls.Reload :: TextButton
	trove:Connect(reload.Activated, function()
		InputController.ReloadPressed:Fire()
	end)

	local switch = controls.Switch :: TextButton
	trove:Connect(switch.Activated, function()
		InputController.SlotPressed:Fire(nextSlot())
	end)

	local view = controls.View :: TextButton
	trove:Connect(view.Activated, function()
		InputController.PerspectiveToggled:Fire()
	end)

	if switchLabel then
		switchLabel.Text = titleForOtherSlot()
	end
end

--------------------------------------------------------------------------------
-- Showing
--------------------------------------------------------------------------------

local function releaseTrigger()
	fireTouch = nil
	InputController.releaseFire()
end

local function setShown(value: boolean)
	if value == shown then
		return
	end
	shown = value

	if value then
		build()
	end

	if root then
		root.Visible = value
	end

	if not value then
		-- The control disappears mid-press when a menu opens, so no touch-ended
		-- ever arrives for it; releasing here is what stops the gun firing
		-- behind the shop.
		releaseTrigger()
	end
end

local function refresh()
	if not enabled then
		return
	end
	setShown(ClientState.isInMatch() and not UIController.isAnyMenuOpen())
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Whether this device gets touch controls at all. False on desktop, where the
	controller builds nothing.
]]
function MobileControlsController.isActive(): boolean
	return enabled
end

function MobileControlsController.areButtonsBound(): boolean
	return shown
end

--[[
	The control rectangles, for tests and for anything that needs to keep clear
	of them. Keyed by id.
]]
function MobileControlsController.controls(): { [string]: GuiObject }
	return controls
end

function MobileControlsController.isTriggerHeld(): boolean
	return fireTouch ~= nil
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

	build()

	--[[
		The fire control. `gameProcessed` is the whole mechanism: it is false
		here precisely because the frame does not consume the touch, which is
		also why the camera still gets it. A touch that a real button already
		took arrives with it true and is ignored.
	]]
	trove:Connect(UserInputService.InputBegan, function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not shown or fireTouch then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local fire = controls.Fire
		if fire and within(fire, input.Position) then
			fireTouch = input
			InputController.pressFire()
		end
	end)

	-- Deliberately not testing the position: the finger is expected to have
	-- travelled far away from the control by now, because that is what aiming
	-- while firing looks like.
	trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		if fireTouch == input then
			releaseTrigger()
		end
	end)

	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name == "InMatch" then
			refresh()
		end
	end))

	trove:Add(ClientState.SlotChanged:Connect(function()
		if switchLabel then
			switchLabel.Text = titleForOtherSlot()
		end
	end))

	trove:Add(UIController.MenuVisibilityChanged:Connect(refresh))

	-- A respawn does not rebuild the GUI, but it does end the life during which
	-- the trigger was held.
	trove:Connect(player.CharacterAdded, releaseTrigger)

	trove:Add(releaseTrigger)

	refresh()
end

function MobileControlsController.stop()
	trove:Clean()
	enabled = false
	shown = false
	root = nil
	controls = {}
	switchLabel = nil
	fireTouch = nil
end

return MobileControlsController
