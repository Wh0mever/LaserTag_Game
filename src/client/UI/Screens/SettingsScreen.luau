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
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ChoiceRow = require(script.Parent.Parent.Components.ChoiceRow)
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
-- The row of panel actions at the foot of the list.
local ACTION_HEIGHT = 36
local ACTION_GAP = 10

local KEY_ROWS = {
	{ action = "Движение", keys = "W A S D" },
	{ action = "Прыжок", keys = "Пробел" },
	{ action = "Огонь", keys = "Левая кнопка мыши" },
	{ action = "Перезарядка", keys = Constants.KEYBINDS.Reload },
	{ action = "Слоты оружия", keys = "1 2 3" },
	{ action = "Скины", keys = Constants.KEYBINDS.Equip },
	{ action = "Магазин", keys = Constants.KEYBINDS.Shop },
	{ action = "Друзья", keys = Constants.KEYBINDS.Friends },
	{ action = "Колесо", keys = Constants.KEYBINDS.Spin },
	{ action = "Настройки", keys = Constants.KEYBINDS.Settings },
	{ action = "Сменить вид", keys = Constants.KEYBINDS.Perspective },
	{ action = "Таблица счёта", keys = "Tab" },
	{ action = "Освободить курсор", keys = "Правый Ctrl" },
}

-- The same actions on a controller (InputController binds them). A, B and the
-- sticks are Roblox's own, so they are listed as what they do there.
local PAD_ROWS = {
	{ action = "Движение", keys = "Левый стик" },
	{ action = "Камера", keys = "Правый стик" },
	{ action = "Прыжок", keys = "A" },
	{ action = "Огонь", keys = "RT" },
	{ action = "Перезарядка", keys = "X" },
	{ action = "Оружие", keys = "LB / RB" },
	{ action = "Таблица счёта", keys = "View" },
	{ action = "Скины (закрыть окно)", keys = "Y" },
	{ action = "Магазин", keys = "D-pad вверх" },
	{ action = "Друзья", keys = "D-pad вправо" },
	{ action = "Колесо", keys = "D-pad вниз" },
	{ action = "Настройки", keys = "D-pad влево" },
}

local trove = Trove.new()
local panel: any = nil
local sliders: { [string]: any } = {}

--[[
	Put every control back in step with the stored value. Both kinds of control
	expose setValue, and neither fires its change callback from it, so this is
	safe to call after a profile arrives or a reset.
]]
local function pushControlValues()
	for id, control in sliders do
		control:setValue(ClientState.settings[id])
	end
end

local function buildKeyList(parent: Instance, order: number, name: string, title: string, rows, visible: boolean)
	local root = Instance.new("Frame")
	root.Name = name
	root.LayoutOrder = order
	root.Size = UDim2.new(1, 0, 0, 18 + #rows * 18)
	root.BackgroundTransparency = 1
	root.Visible = visible
	root.ZIndex = 3
	root.Parent = parent

	local header = UITheme.label(title, UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 16)
	header.ZIndex = 3
	header.Parent = root

	for index, entry in rows do
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

	return root
end

function SettingsScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("SettingsMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		-- The panel's own X button and the tap-behind close it without going
		-- through UIController, so it would never learn. This is how it learns.
		onClose = function()
			UIController.notifyClosed("Settings")
		end,
		title = "НАСТРОЙКИ",
		subtitle = "Применяется сразу и запоминается",
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

	-- The control follows from the setting's kind, so adding a setting to
	-- SettingsConfig is the whole of adding it to this panel.
	for index, definition in SettingsConfig.Definitions do
		-- A setting for hardware this device does not have is a control that
		-- does nothing, so it is not offered.
		if definition.requires == "mouse" and not UserInputService.MouseEnabled then
			continue
		end
		local control
		if definition.kind == "choice" then
			control = ChoiceRow.create({
				settingId = definition.id,
				value = ClientState.settings[definition.id],
				parent = body,
				layoutOrder = index,
				-- A press is both the change and the commit: there is no drag to
				-- coalesce, and the value is one of two, so the save is cheap.
				onChanged = function(value: string)
					ClientState.applySetting(definition.id, value)
					ClientState.saveSettings()
				end,
			})
		else
			control = Slider.create({
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
		end

		if control then
			sliders[definition.id] = control
			trove:Add(function()
				control:destroy()
			end)
		end
	end

	-- A list of keys on a device with no keys is a list of things the player
	-- cannot do. A touchscreen laptop has a keyboard and keeps it; a console has
	-- only the pad, so each list follows its own hardware. A pad plugged in
	-- after the panel was built is picked up by the events below.
	local count = #SettingsConfig.Definitions
	buildKeyList(body, count + 1, "Keys", "УПРАВЛЕНИЕ", KEY_ROWS, UserInputService.KeyboardEnabled)
	local padList =
		buildKeyList(body, count + 2, "PadKeys", "ГЕЙМПАД", PAD_ROWS, UserInputService.GamepadEnabled)
	local function syncPadList()
		padList.Visible = UserInputService.GamepadEnabled
	end
	trove:Connect(UserInputService.GamepadConnected, syncPadList)
	trove:Connect(UserInputService.GamepadDisconnected, syncPadList)

	--[[
		The panel's two actions, at the end of the list rather than in the title
		bar. They used to sit beside the close button, which on a phone put
		"КАК ИГРАТЬ" across the panel's own title and pushed it past the left
		edge — a title bar has room for a title and a close button, not three
		buttons. Down here there is a full row for them on every screen.
	]]
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.LayoutOrder = count + 3
	actions.Size = UDim2.new(1, 0, 0, ACTION_HEIGHT)
	actions.BackgroundTransparency = 1
	actions.ZIndex = 3
	actions.Parent = body

	local actionsLayout = Instance.new("UIListLayout")
	actionsLayout.FillDirection = Enum.FillDirection.Horizontal
	actionsLayout.SortOrder = Enum.SortOrder.LayoutOrder
	actionsLayout.Padding = UDim.new(0, ACTION_GAP)
	actionsLayout.Parent = actions

	-- The only way back to the welcome card, which otherwise shows once on a
	-- first join and is gone. Required lazily to keep the two screens from
	-- forming a require cycle through their module bodies.
	local howTo = Button.create({
		name = "HowToPlay",
		text = "КАК ИГРАТЬ",
		size = UDim2.new(0.5, -ACTION_GAP / 2, 1, 0),
		layoutOrder = 1,
		parent = actions,
		color = UITheme.Colors.PanelLight,
		onActivated = function()
			local ok, WelcomeScreen = pcall(require, script.Parent.WelcomeScreen)
			if ok and type(WelcomeScreen) == "table" and type(WelcomeScreen.open) == "function" then
				WelcomeScreen.open()
			end
		end,
	})
	howTo.label.TextSize = UITheme.TextSizes.Small
	trove:Add(function()
		howTo:destroy()
	end)

	local reset = Button.create({
		name = "Reset",
		text = "СБРОСИТЬ ВСЁ",
		size = UDim2.new(0.5, -ACTION_GAP / 2, 1, 0),
		layoutOrder = 2,
		parent = actions,
		onActivated = function()
			for id, value in SettingsConfig.defaults() do
				ClientState.applySetting(id, value)
			end
			ClientState.saveSettings()
			pushControlValues()
		end,
	})
	reset.label.TextSize = UITheme.TextSizes.Small
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
	trove:Add(ClientState.SettingsChanged:Connect(pushControlValues))
end

function SettingsScreen.stop()
	trove:Clean()
	table.clear(sliders)
	panel = nil
end

return SettingsScreen
