--!nonstrict
--[[
	SideButtonsScreen.luau
	The persistent chrome around the game: the coin balance top-left, the
	EQUIP / SHOP / FRIENDS / SPIN stack down the left edge with their E/Q/F/P key
	badges, the mouse-unlock hint and the version stamp.

	The buttons do not open anything themselves — they call
	UIController.toggleMenu, exactly as the hotkeys do, so a menu opened by a
	click and a menu opened by a keypress go through the same exclusivity rules.

	On a small screen the labels are dropped and the buttons collapse to their
	icons. The trigger is UIController.ScaleChanged, which already fires on the
	Constants.SMALL_SCREEN_WIDTH crossing — a second viewport watcher here could
	only disagree with it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local CurrencyLabel = require(script.Parent.Parent.Components.CurrencyLabel)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local SideButtonsScreen = {}
SideButtonsScreen.Priority = 22

local BUTTON_HEIGHT = 46
local BUTTON_WIDTH = 150
local COMPACT_WIDTH = 52
local BUTTON_GAP = 10

-- Geometric glyphs only: this project ships no image assets, and these render
-- in the Gotham family on every platform.
local MENUS = {
	{ name = "Equip", label = "EQUIP", icon = "◆", key = Constants.KEYBINDS.Equip },
	{ name = "Shop", label = "SHOP", icon = "★", key = Constants.KEYBINDS.Shop },
	{ name = "Friends", label = "FRIENDS", icon = "●", key = Constants.KEYBINDS.Friends },
	{ name = "Spin", label = "SPIN", icon = "◎", key = Constants.KEYBINDS.Spin },
	{ name = "Settings", label = "SETTINGS", icon = "⚙", key = Constants.KEYBINDS.Settings },
}

local trove = Trove.new()
local stack: Frame? = nil
local buttons: { any } = {}
local coins: any = nil
local mouseHint: TextLabel? = nil
-- nil until the first pass so the initial call always applies, including the
-- touch-only key-badge removal that has nothing to do with the width.
local compact: boolean? = nil

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function applyCompact(isCompact: boolean)
	if isCompact == compact then
		return
	end
	compact = isCompact
	local width = isCompact and COMPACT_WIDTH or BUTTON_WIDTH

	if stack then
		stack.Size = UDim2.fromOffset(width, #MENUS * BUTTON_HEIGHT + (#MENUS - 1) * BUTTON_GAP)
	end

	for index, entry in MENUS do
		local button = buttons[index]
		if button then
			button.instance.Size = UDim2.fromOffset(width, BUTTON_HEIGHT)
			button:setText(isCompact and "" or entry.label)
			-- A touch device has no key to hint at, and the badge would only
			-- crowd an icon-sized button.
			button:setKeyHint(if isCompact or ClientState.isTouch then nil else entry.key)
		end
	end
end

--------------------------------------------------------------------------------
-- Mouse hint
--------------------------------------------------------------------------------

local function refreshMouseHint(unlocked: boolean)
	if not mouseHint then
		return
	end

	local key = Constants.KEYBINDS.MouseUnlock == "RightControl" and "Right Ctrl" or Constants.KEYBINDS.MouseUnlock
	mouseHint.Text = if unlocked then `MOUSE FREE — {key} to lock` else `UNLOCK MOUSE — {key}`
	mouseHint.TextColor3 = if unlocked then UITheme.Colors.Accent else UITheme.Colors.TextDim
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildStack(parent: Instance)
	local holder = Instance.new("Frame")
	holder.Name = "Buttons"
	holder.AnchorPoint = Vector2.new(0, 0.5)
	holder.Position = UDim2.new(0, 16, 0.5, 0)
	holder.Size = UDim2.fromOffset(BUTTON_WIDTH, #MENUS * BUTTON_HEIGHT + (#MENUS - 1) * BUTTON_GAP)
	holder.BackgroundTransparency = 1
	holder.Parent = parent
	stack = holder

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, BUTTON_GAP)
	layout.Parent = holder

	for index, entry in MENUS do
		local button = Button.create({
			name = entry.name,
			text = entry.label,
			icon = entry.icon,
			keyHint = entry.key,
			size = UDim2.fromOffset(BUTTON_WIDTH, BUTTON_HEIGHT),
			layoutOrder = index,
			parent = holder,
			onActivated = function()
				UIController.toggleMenu(entry.name)
			end,
		})
		-- Components expose :destroy(), which Trove does not recognise on its
		-- own, so the teardown goes in as a function.
		trove:Add(function()
			button:destroy()
		end)
		buttons[index] = button
	end
end

local function buildFooter(parent: Instance)
	local hint = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	hint.Name = "MouseHint"
	hint.AnchorPoint = Vector2.new(1, 1)
	-- Clear of the HUD ammo counter, which owns the bottom-right corner.
	hint.Position = UDim2.new(1, -24, 1, -92)
	hint.Size = UDim2.fromOffset(240, 18)
	hint.TextXAlignment = Enum.TextXAlignment.Right
	hint.Visible = not ClientState.isTouch
	hint.Parent = parent
	mouseHint = hint

	local version = UITheme.label(Constants.VERSION, UITheme.TextSizes.Tiny, UITheme.Colors.TextMuted)
	version.Name = "Version"
	version.AnchorPoint = Vector2.new(1, 1)
	version.Position = UDim2.new(1, -8, 1, -4)
	version.Size = UDim2.fromOffset(60, 14)
	version.TextXAlignment = Enum.TextXAlignment.Right
	version.Parent = parent
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SideButtonsScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("SideButtons", Constants.DISPLAY_ORDER.SideButtons)
	if not gui then
		return
	end

	local root = Instance.new("Frame")
	root.Name = "Root"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Parent = gui
	trove:Add(root)

	coins = CurrencyLabel.create({
		name = "Coins",
		parent = root,
		position = UDim2.new(0, 16, 0, 16),
		anchorPoint = Vector2.new(0, 0),
		value = ClientState.coins,
	})
	trove:Add(function()
		coins:destroy()
	end)

	buildStack(root)
	buildFooter(root)

	trove:Add(ClientState.CoinsChanged:Connect(function(newCoins: number)
		coins:set(newCoins)
	end))

	trove:Add(ClientState.ProfileChanged:Connect(function()
		-- The profile snapshot is a full reload, not a reward: no count-up.
		coins:setInstant(ClientState.coins)
	end))

	trove:Add(InputController.MouseUnlockToggled:Connect(refreshMouseHint))
	trove:Add(UIController.ScaleChanged:Connect(function(scale: number)
		applyCompact(scale < 1)
	end))

	refreshMouseHint(InputController.isMouseUnlocked())
	applyCompact(UIController.scale < 1)
end

function SideButtonsScreen.stop()
	trove:Clean()
	table.clear(buttons)
	stack = nil
	coins = nil
	mouseHint = nil
end

return SideButtonsScreen
