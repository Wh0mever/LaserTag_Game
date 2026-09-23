--!nonstrict
--[[
	EquipScreen.luau
	A tab per weapon; under the lit tab, the skins the player actually owns for
	it, with the one currently equipped marked.

	TABS, NOT COLUMNS. This was a column per weapon side by side, which on a
	monitor cut every skin name to "…" (three columns of a 820 px panel leave a
	row about 90 px for the name) and on a phone could not work at all: its
	"stacked" fallback gave each weapon a third of a 290 px panel, room for the
	header and nothing else, so a phone player could not see a single skin to
	tap. One weapon at a time gets the whole panel on every screen.

	Every catalog skin gets a row per weapon at build time and unowned rows are
	hidden rather than destroyed — UIListLayout skips invisible children, so a
	skin unlocked mid-session appears by flipping one boolean instead of
	rebuilding the list.

	Equipping is a server call. The row does not change state until
	EquipSkinRequest answers ok; a refusal leaves the old skin selected and
	writes the server's reason into the status line.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local ListRow = require(script.Parent.Parent.Components.ListRow)
local Panel = require(script.Parent.Parent.Components.Panel)
local RemoteNames = require(Shared.RemoteNames)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local EquipScreen = {}
EquipScreen.Priority = 30

local ROW_HEIGHT = 46
local TAB_HEIGHT = 32
local TAB_GAP = 8
local HEADER_HEIGHT = 26
local PREVIEW_HEIGHT = 16
local STATUS_HEIGHT = 22

local trove = Trove.new()
local panel: any = nil
local columns: { [string]: any } = {}
local tabs: { [string]: any } = {}
local selectedWeapon: string? = nil
local statusLabel: TextLabel? = nil
local pending = false

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local function equippedSkin(weaponId: string): string
	local skinId = ClientState.equippedSkins[weaponId]
	if SkinCatalog.exists(skinId) then
		return skinId
	end
	return SkinCatalog.DEFAULT_SKIN_ID
end

local function isOwned(skinId: string): boolean
	local skin = SkinCatalog.get(skinId)
	return (skin ~= nil and skin.isDefault == true) or ClientState.ownedSkins[skinId] == true
end

local function setStatus(message: string, isError: boolean)
	if not statusLabel then
		return
	end
	statusLabel.Text = message
	statusLabel.TextColor3 = if isError then UITheme.Colors.Negative else UITheme.Colors.Positive
end

local function refreshTabs()
	for weaponId, tab in tabs do
		local active = weaponId == selectedWeapon
		tab:setColor(if active then UITheme.Colors.Accent else UITheme.Colors.PanelLight)
		tab.label.TextColor3 = if active then UITheme.Colors.PanelDark else UITheme.Colors.Text
	end
	for weaponId, column in columns do
		column.instance.Visible = weaponId == selectedWeapon
	end
end

local function selectWeapon(weaponId: string)
	if not columns[weaponId] then
		return
	end
	selectedWeapon = weaponId
	refreshTabs()
end

local function refresh()
	for weaponId, column in columns do
		local current = equippedSkin(weaponId)
		local skin = SkinCatalog.get(current)
		column.preview.BackgroundColor3 = UITheme.fromRGB(skin and skin.color)
		column.header.Text = `{column.displayName}  —  {skin and skin.displayName or current}`

		for skinId, row in column.rows do
			local owned = isOwned(skinId)
			row.instance.Visible = owned
			row:update({
				value = if skinId == current then "НАДЕТО" else "",
				valueColor = UITheme.Colors.Accent,
				selected = skinId == current,
			})
		end
	end
end

local function equip(weaponId: string, skinId: string)
	if pending or not isOwned(skinId) or equippedSkin(weaponId) == skinId then
		return
	end

	pending = true
	setStatus("Экипируем…", false)

	task.spawn(function()
		local remote = ClientState.getRemote(RemoteNames.EquipSkinRequest)
		local result
		if remote then
			local ok, response = pcall(function()
				return (remote :: any):InvokeServer(weaponId, skinId)
			end)
			result = ok and response or nil
		end

		pending = false

		if type(result) ~= "table" then
			setStatus("Сервер не ответил — попробуйте ещё раз", true)
		elseif result.ok then
			-- The server's answer, adopted; the client never picks the skin id.
			ClientState.equippedSkins[weaponId] = result.skinId or skinId
			local skin = SkinCatalog.get(ClientState.equippedSkins[weaponId])
			local column = columns[weaponId]
			setStatus(`{column and column.displayName or weaponId}: {skin and skin.displayName or skinId}`, false)
		else
			setStatus(result.err or "Сервер отклонил смену скина", true)
		end

		refresh()
	end)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildColumn(weaponId: string, index: number, parent: Instance)
	local weapon = WeaponConfig.get(weaponId)
	local root = Instance.new("Frame")
	root.Name = weaponId
	root.LayoutOrder = index
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.ZIndex = 3
	root.Parent = parent

	local header = UITheme.label("", UITheme.TextSizes.Subtitle, UITheme.Colors.Text, UITheme.Fonts.Heading)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	header.ZIndex = 3
	header.Parent = root

	-- The bar under the header is the equipped beam colour: the same thing the
	-- skin changes on the gun, so "which one is on" is readable at a glance.
	local preview = Instance.new("Frame")
	preview.Name = "Preview"
	preview.Position = UDim2.new(0, 0, 0, HEADER_HEIGHT + 2)
	preview.Size = UDim2.new(1, 0, 0, 6)
	preview.BackgroundColor3 = UITheme.Colors.Accent
	preview.BorderSizePixel = 0
	preview.ZIndex = 3
	preview.Parent = root
	UITheme.corner(UITheme.Radius.Pill).Parent = preview

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Skins"
	scroll.Position = UDim2.new(0, 0, 0, HEADER_HEIGHT + PREVIEW_HEIGHT)
	scroll.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + PREVIEW_HEIGHT))
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = UITheme.Colors.Stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 3
	scroll.Parent = root

	-- Two skins per row. A phone panel is short, and a single column of 46 px
	-- rows showed one and a half skins before the player had to scroll.
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.new(0.5, -4, 0, ROW_HEIGHT)
	layout.CellPadding = UDim2.fromOffset(8, 6)
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	local column = {
		instance = root,
		header = header,
		preview = preview,
		displayName = weapon and weapon.displayName or weaponId,
		rows = {},
	}

	for order, skinId in SkinCatalog.Order do
		local skin = SkinCatalog.get(skinId)
		local row = ListRow.create({
			name = skinId,
			parent = scroll,
			title = skin.displayName,
			subtitle = SkinCatalog.rarityLabel(skinId),
			icon = "■",
			accentColor = UITheme.fromRGB(skin.color),
			height = ROW_HEIGHT,
			layoutOrder = order,
			onActivated = function()
				equip(weaponId, skinId)
			end,
		})
		row.instance.ZIndex = 3
		trove:Add(function()
			row:destroy()
		end)
		column.rows[skinId] = row
	end

	columns[weaponId] = column
end

--[[
	One tab per weapon, sharing the width evenly. Short names: three full names
	side by side do not fit a phone-width panel.
]]
local function buildTabs(parent: Instance)
	local row = Instance.new("Frame")
	row.Name = "Tabs"
	row.Size = UDim2.new(1, 0, 0, TAB_HEIGHT)
	row.BackgroundTransparency = 1
	row.ZIndex = 3
	row.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, TAB_GAP)
	layout.Parent = row

	local count = math.max(1, #WeaponConfig.Order)
	-- The gaps come out of the tabs' width, or the last tab is pushed past the
	-- edge by the accumulated padding.
	local gap = TAB_GAP * (count - 1) / count
	for index, weaponId in WeaponConfig.Order do
		local weapon = WeaponConfig.get(weaponId)
		local tab = Button.create({
			name = weaponId,
			parent = row,
			text = weapon and (weapon.shortName or weapon.displayName) or weaponId,
			size = UDim2.new(1 / count, -gap, 1, 0),
			layoutOrder = index,
			onActivated = function()
				selectWeapon(weaponId)
			end,
		})
		tab.label.TextSize = UITheme.TextSizes.Small
		trove:Add(function()
			tab:destroy()
		end)
		tabs[weaponId] = tab
	end
end

-- The tab buttons, for tests.
function EquipScreen.tabs(): { [string]: any }
	return tabs
end

-- Which weapon's skins are on show, for tests.
function EquipScreen.selectedWeapon(): string?
	return selectedWeapon
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function EquipScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("EquipMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		-- The panel's own X button and the tap-behind close it without going
		-- through UIController, so it would never learn. This is how it learns.
		onClose = function()
			UIController.notifyClosed("Equip")
		end,
		title = "СКИНЫ",
		subtitle = "Цвет лазера для каждого оружия",
		size = UDim2.fromScale(0.82, 0.72),
		parent = gui,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	buildTabs(panel.content)

	-- Every weapon's list lives here at full size; only the selected one shows.
	local holder = Instance.new("Frame")
	holder.Name = "Columns"
	holder.Position = UDim2.new(0, 0, 0, TAB_HEIGHT + TAB_GAP)
	holder.Size = UDim2.new(1, 0, 1, -(TAB_HEIGHT + TAB_GAP + STATUS_HEIGHT))
	holder.BackgroundTransparency = 1
	holder.ZIndex = 3
	holder.Parent = panel.content

	for index, weaponId in WeaponConfig.Order do
		buildColumn(weaponId, index, holder)
	end

	local status = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0, 1)
	status.Position = UDim2.fromScale(0, 1)
	status.Size = UDim2.new(1, 0, 0, STATUS_HEIGHT)
	status.ZIndex = 3
	status.Parent = panel.content
	statusLabel = status

	UIController.registerMenu("Equip", panel:asMenuHandle())
	-- Panel's X button and backdrop close the window without telling
	-- UIController, which owns the cursor lock; both are re-pointed here.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu("Equip")
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu("Equip")
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu("Equip")
	end)

	trove:Add(ClientState.ProfileChanged:Connect(refresh))

	-- Open on the weapon in hand: that is the gun whose look the player just
	-- noticed and wants to change.
	trove:Add(UIController.MenuVisibilityChanged:Connect(function(name: string, visible: boolean)
		if name == "Equip" and visible then
			local current = ClientState.ammo and ClientState.ammo.weaponId
			selectWeapon(if columns[current] then current else WeaponConfig.Order[1])
		end
	end))

	selectWeapon(WeaponConfig.Order[1])
	refresh()
end

function EquipScreen.stop()
	trove:Clean()
	table.clear(columns)
	table.clear(tabs)
	selectedWeapon = nil
	panel = nil
	statusLabel = nil
end

return EquipScreen
