--!nonstrict
--[[
	EquipScreen.luau
	One column per weapon (Rifle, Pistol), each listing the skins the player
	actually owns and marking the one currently equipped.

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
local HEADER_HEIGHT = 26
local PREVIEW_HEIGHT = 16
local STATUS_HEIGHT = 22
-- Gap between weapon columns, in pixels.
local COLUMN_GAP = 12

local trove = Trove.new()
local panel: any = nil
local columnsHolder: Frame? = nil
local columnsLayout: UIListLayout? = nil
local columns: { [string]: any } = {}
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
	root.BackgroundTransparency = 1
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

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
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
			subtitle = skin.rarity,
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

local function applyStacked(stacked: boolean)
	if not columnsHolder or not columnsLayout then
		return
	end

	-- Columns share the panel evenly. The fraction is computed from how many
	-- weapons there are rather than written down: it was 0.5 from when there
	-- were two, and adding the third left it running off the right edge with no
	-- way to reach it. The padding between columns has to come out of their
	-- width too, or the last one is pushed past the edge by the accumulated gap.
	local count = math.max(1, #WeaponConfig.Order)
	local share = 1 / count
	local gap = COLUMN_GAP * (count - 1) / count

	columnsLayout.FillDirection = if stacked then Enum.FillDirection.Vertical else Enum.FillDirection.Horizontal
	for _, column in columns do
		column.instance.Size = if stacked then UDim2.new(1, 0, share, -gap) else UDim2.new(share, -gap, 1, 0)
	end
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
		title = "СКИНЫ",
		subtitle = "Цвет лазера для каждого оружия",
		size = UDim2.fromScale(0.82, 0.72),
		parent = gui,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	local holder = Instance.new("Frame")
	holder.Name = "Columns"
	holder.Size = UDim2.new(1, 0, 1, -STATUS_HEIGHT)
	holder.BackgroundTransparency = 1
	holder.ZIndex = 3
	holder.Parent = panel.content
	columnsHolder = holder

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, COLUMN_GAP)
	layout.Parent = holder
	columnsLayout = layout

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
	trove:Add(UIController.ScaleChanged:Connect(function(scale: number)
		applyStacked(scale < 1)
	end))

	applyStacked(UIController.scale < 1)
	refresh()
end

function EquipScreen.stop()
	trove:Clean()
	table.clear(columns)
	panel = nil
	columnsHolder = nil
	columnsLayout = nil
	statusLabel = nil
end

return EquipScreen
