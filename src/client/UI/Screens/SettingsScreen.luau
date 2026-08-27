--!nonstrict
--[[
	SettingsScreen.luau
	One slider per entry in SettingsConfig, a reset, and the current key bindings
	listed for reference.

	Applying happens through ClientState.setSetting, which updates the local
	value, fires SettingsChanged (SettingsController listens and applies it to
	the camera, the sound group and the input service) and tells the server to
	remember it. So a drag is felt immediately and stored in the background.

	The network save is deliberately on `onCommitted` rather than `onChanged`: a
	single drag across a slider produces dozens of steps, and firing the remote
	on each would burn the rate limit for no benefit. The value is applied on
	every step regardless — that is what makes a sensitivity slider usable.

	The key bindings are shown, not edited. Remapping means storing a keymap per
	player and defending against a player binding movement onto the same key as
	fire; listing them is most of the value for none of that, and it is the only
	place in the game the full set is written down for a player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local Panel = require(script.Parent.Parent.Components.Panel)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Slider = require(script.Parent.Parent.Components.Slider)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local SettingsScreen = {}
SettingsScreen.Priority = 34

-- Reading order for the key list, so it does not come out in whatever order
-- pairs() happens to walk the table.
local KEY_ROWS = {
	{ action = "Move", keys = "W A S D" },
	{ action = "Jump", keys = "Space" },
	{ action = "Fire", keys = "Left mouse" },
	{ action = "Reload", keys = Constants.KEYBINDS.Reload },
	{ action = "Weapon slots", keys = "1 2 3" },
	{ action = "Equip", keys = Constants.KEYBINDS.Equip },
	{ action = "Shop", keys = Constants.KEYBINDS.Shop },
	{ action = "Friends", keys = Constants.KEYBINDS.Friends },
	{ action = "Spin", keys = Constants.KEYBINDS.Spin },
	{ action = "Settings", keys = Constants.KEYBINDS.Settings },
	{ action = "Scoreboard", keys = "Tab" },
	{ action = "Free the cursor", keys = "Right Ctrl" },
}

local trove = Trove.new()
local panel: any = nil
local sliders: { [string]: any } = {}

local function pushSliderValues()
	for id, slider in sliders do
		slider:setValue(ClientState.settings[id])
	end
end

local function buildKeyList(parent: Instance, order: number)
	local root = Instance.new("Frame")
	root.Name = "Keys"
	root.LayoutOrder = order
	root.Size = UDim2.new(1, 0, 0, 18 + #KEY_ROWS * 18)
	root.BackgroundTransparency = 1
	root.ZIndex = 3
	root.Parent = parent

	local header = UITheme.label("CONTROLS", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 16)
	header.ZIndex = 3
	header.Parent = root

	for index, entry in KEY_ROWS do
		local row = Instance.new("Frame")
		row.Name = entry.action
		row.Position = UDim2.new(0, 0, 0, 18 + (index - 1) * 18)
		row.Size = UDim2.new(1, 0, 0, 16)
		row.BackgroundTransparency = 1
		row.ZIndex = 3
		row.Parent = root

		local action = UITheme.label(entry.action, UITheme.TextSizes.Tiny, UITheme.Colors.TextMuted)
		action.Name = "Action"
		action.Size = UDim2.new(0.6, 0, 1, 0)
		action.ZIndex = 3
		action.Parent = row

		local keys = UITheme.label(entry.keys, UITheme.TextSizes.Tiny, UITheme.Colors.TextDim, UITheme.Fonts.Number)
		keys.Name = "Keys"
		keys.AnchorPoint = Vector2.new(1, 0)
		keys.Position = UDim2.fromScale(1, 0)
		keys.Size = UDim2.new(0.4, 0, 1, 0)
		keys.TextXAlignment = Enum.TextXAlignment.Right
		keys.ZIndex = 3
		keys.Parent = row
	end
end

function SettingsScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("SettingsMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		title = "SETTINGS",
		subtitle = "Applied as you drag, and remembered for next time",
		size = UDim2.fromScale(0.48, 0.72),
		parent = gui,
		accentColor = UITheme.Colors.Accent,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	local body = Instance.new("ScrollingFrame")
	body.Name = "Settings"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.ScrollBarImageColor3 = UITheme.Colors.Stroke
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ZIndex = 3
	body.Parent = panel.content

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = body

	for index, definition in SettingsConfig.Definitions do
		local slider = Slider.create({
			settingId = definition.id,
			value = ClientState.settings[definition.id],
			parent = body,
			layoutOrder = index,
			-- Applied on every step, so the change is felt under the hand...
			onChanged = function(value: number)
				ClientState.applySetting(definition.id, value)
			end,
			-- ...and written once on release. A drag produces dozens of steps;
			-- saving each would spend the remote's rate budget on one gesture.
			onCommitted = function(value: number)
				ClientState.applySetting(definition.id, value)
				ClientState.saveSettings()
			end,
		})
		sliders[definition.id] = slider
		trove:Add(function()
			slider:destroy()
		end)
	end

	buildKeyList(body, #SettingsConfig.Definitions + 1)

	local reset = Button.create({
		name = "Reset",
		text = "RESET TO DEFAULTS",
		size = UDim2.fromOffset(168, 30),
		position = UDim2.new(1, -56, 0, 13),
		anchorPoint = Vector2.new(1, 0),
		parent = panel.body,
		onActivated = function()
			for id, value in SettingsConfig.defaults() do
				ClientState.applySetting(id, value)
			end
			ClientState.saveSettings()
			pushSliderValues()
		end,
	})
	reset.instance.ZIndex = 4
	trove:Add(function()
		reset:destroy()
	end)

	UIController.registerMenu("Settings", panel:asMenuHandle())
	-- Panel's own close paths bypass UIController, which owns the cursor lock.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu("Settings")
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu("Settings")
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu("Settings")
	end)

	-- The profile lands after this screen is built, so the sliders start on
	-- defaults and are corrected when the real values arrive.
	trove:Add(ClientState.SettingsChanged:Connect(pushSliderValues))
end

function SettingsScreen.stop()
	trove:Clean()
	table.clear(sliders)
	panel = nil
end

return SettingsScreen
