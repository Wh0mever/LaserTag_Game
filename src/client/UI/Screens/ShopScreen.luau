--!nonstrict
--[[
	ShopScreen.luau
	The skin shop: a scrolling grid of cards, one per SkinCatalog.Order entry,
	with a laser-colour swatch, the price and a rarity-tinted border.

	The client decides nothing here. A card's BUY button invokes
	BuySkinRequest and then believes the ShopResult that comes back — the coin
	balance shown afterwards is the server's number, not a local subtraction.

	Exactly one purchase may be in flight at a time. Every buy button is disabled
	for the duration, because two clicks that both reach the server would be two
	deductions, and the second one's failure toast would arrive after the coins
	were already gone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local CurrencyLabel = require(script.Parent.Parent.Components.CurrencyLabel)
local Panel = require(script.Parent.Parent.Components.Panel)
local RemoteNames = require(Shared.RemoteNames)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local ShopScreen = {}
ShopScreen.Priority = 30

local CARD_HEIGHT = 178
local TOAST_SECONDS = 3

local trove = Trove.new()
local panel: any = nil
local coins: any = nil
local grid: UIGridLayout? = nil
local cards: { [string]: any } = {}
local toastFrame: Frame? = nil
local toastLabel: TextLabel? = nil
local toastToken = 0
local pending = false

--------------------------------------------------------------------------------
-- Toast
--------------------------------------------------------------------------------

--[[
	One reused chip at the top of the panel. `isError` only changes its colour —
	the text is whatever the server said, so a new refusal reason never needs a
	client-side translation table.
]]
local function toast(message: string, isError: boolean)
	if not toastFrame or not toastLabel then
		return
	end

	toastToken += 1
	local token = toastToken

	toastLabel.Text = message
	toastFrame.BackgroundColor3 = if isError then UITheme.Colors.Negative else UITheme.Colors.Positive
	toastFrame.Visible = true
	toastFrame.BackgroundTransparency = 1
	toastLabel.TextTransparency = 1
	TweenService:Create(toastFrame, UITheme.Tween.Fast, { BackgroundTransparency = 0.1 }):Play()
	TweenService:Create(toastLabel, UITheme.Tween.Fast, { TextTransparency = 0 }):Play()

	task.delay(TOAST_SECONDS, function()
		if token ~= toastToken or not toastFrame then
			return
		end
		TweenService:Create(toastFrame, UITheme.Tween.Exit, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(toastLabel, UITheme.Tween.Exit, { TextTransparency = 1 }):Play()
		task.delay(UITheme.Tween.Exit.Time, function()
			if token == toastToken and toastFrame then
				toastFrame.Visible = false
			end
		end)
	end)
end

--------------------------------------------------------------------------------
-- Cards
--------------------------------------------------------------------------------

local function isOwned(skinId: string): boolean
	local skin = SkinCatalog.get(skinId)
	return (skin ~= nil and skin.isDefault == true) or ClientState.ownedSkins[skinId] == true
end

local function refresh()
	for skinId, card in cards do
		local skin = SkinCatalog.get(skinId)
		local owned = isOwned(skinId)
		local affordable = skin ~= nil and ClientState.coins >= skin.price

		if not skin then
			continue
		elseif owned then
			card.button:setText("OWNED")
			card.button:setColor(UITheme.Colors.PanelLight)
			card.button:setEnabled(false)
		else
			card.button:setText(`BUY  {skin.price}`)
			card.button:setColor(UITheme.Colors.Coin)
			card.button:setEnabled(affordable and not pending)
		end
	end
end

local function buy(skinId: string)
	if pending or isOwned(skinId) then
		return
	end

	pending = true
	refresh()

	task.spawn(function()
		local remote = ClientState.getRemote(RemoteNames.BuySkinRequest)
		local result
		if remote then
			local ok, response = pcall(function()
				return (remote :: any):InvokeServer(skinId)
			end)
			result = ok and response or nil
		end

		pending = false

		if type(result) ~= "table" then
			toast("Purchase failed — try again", true)
		elseif result.ok then
			-- Adopting the server's reply, not computing our own balance.
			if type(result.coins) == "number" then
				ClientState.coins = result.coins
				coins:set(result.coins)
			end
			ClientState.ownedSkins[skinId] = true
			local skin = SkinCatalog.get(skinId)
			toast(`{skin and skin.displayName or skinId} unlocked`, false)
		else
			toast(result.err or "Purchase refused", true)
		end

		refresh()
	end)
end

local function buildCard(skinId: string, index: number, parent: Instance)
	local skin = SkinCatalog.get(skinId)
	if not skin then
		return
	end

	local rarity = UITheme.fromRGB(SkinCatalog.rarityColor(skinId))
	local beam = UITheme.fromRGB(skin.color)

	local card = Instance.new("Frame")
	card.Name = skinId
	card.LayoutOrder = index
	card.BackgroundColor3 = UITheme.Colors.PanelDark
	card.BorderSizePixel = 0
	card.ZIndex = 3
	card.Parent = parent
	UITheme.corner(UITheme.Radius.Medium).Parent = card
	UITheme.stroke(rarity, 2).Parent = card

	-- Laser preview: the beam colour as a glowing bar, which is exactly what the
	-- skin changes in the world.
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.AnchorPoint = Vector2.new(0.5, 0)
	swatch.Position = UDim2.new(0.5, 0, 0, 10)
	swatch.Size = UDim2.new(1, -20, 0, 44)
	swatch.BackgroundColor3 = UITheme.Colors.Background
	swatch.BorderSizePixel = 0
	swatch.ZIndex = 3
	swatch.Parent = card
	UITheme.corner(UITheme.Radius.Small).Parent = swatch

	local bolt = Instance.new("Frame")
	bolt.Name = "Beam"
	bolt.AnchorPoint = Vector2.new(0.5, 0.5)
	bolt.Position = UDim2.fromScale(0.5, 0.5)
	bolt.Size = UDim2.new(0.86, 0, 0, 8)
	bolt.BackgroundColor3 = beam
	bolt.BorderSizePixel = 0
	bolt.ZIndex = 4
	bolt.Parent = swatch
	UITheme.corner(UITheme.Radius.Pill).Parent = bolt
	UITheme.gradient(beam, UITheme.fromRGB(skin.accentColor), 0).Parent = bolt
	UITheme.stroke(beam, 2).Parent = bolt

	local name = UITheme.label(skin.displayName, UITheme.TextSizes.Body, UITheme.Colors.Text, UITheme.Fonts.Bold)
	name.Name = "Title"
	name.Position = UDim2.new(0, 12, 0, 60)
	name.Size = UDim2.new(1, -24, 0, 20)
	name.ZIndex = 3
	name.Parent = card

	local rarityLabel = UITheme.label(string.upper(skin.rarity), UITheme.TextSizes.Tiny, rarity, UITheme.Fonts.Bold)
	rarityLabel.Name = "Rarity"
	rarityLabel.Position = UDim2.new(0, 12, 0, 80)
	rarityLabel.Size = UDim2.new(1, -24, 0, 16)
	rarityLabel.ZIndex = 3
	rarityLabel.Parent = card

	local button = Button.create({
		name = "Buy",
		text = "OWNED",
		size = UDim2.new(1, -20, 0, 34),
		position = UDim2.new(0.5, 0, 1, -12),
		anchorPoint = Vector2.new(0.5, 1),
		color = UITheme.Colors.Coin,
		textColor = UITheme.Colors.PanelDark,
		parent = card,
		onActivated = function()
			buy(skinId)
		end,
	})
	button.instance.ZIndex = 4

	trove:Add(function()
		button:destroy()
	end)
	cards[skinId] = { instance = card, button = button }
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

local function applyColumns(columns: number)
	if not grid then
		return
	end
	grid.FillDirectionMaxCells = columns
	grid.CellSize = UDim2.new(1 / columns, -8, 0, CARD_HEIGHT)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ShopScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("ShopMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		title = "SHOP",
		subtitle = "Cosmetic only — a skin never changes damage or accuracy",
		size = UDim2.fromScale(0.66, 0.72),
		parent = gui,
		accentColor = UITheme.Colors.Coin,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	coins = CurrencyLabel.create({
		name = "Balance",
		parent = panel.body,
		position = UDim2.new(1, -56, 0, 12),
		anchorPoint = Vector2.new(1, 0),
		size = UDim2.fromOffset(130, 32),
		value = ClientState.coins,
	})
	coins.instance.ZIndex = 4
	trove:Add(function()
		coins:destroy()
	end)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Grid"
	scroll.Size = UDim2.fromScale(1, 1)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = UITheme.Colors.Stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 3
	scroll.Parent = panel.content

	local layout = Instance.new("UIGridLayout")
	layout.CellPadding = UDim2.fromOffset(8, 10)
	layout.CellSize = UDim2.new(1 / 3, -8, 0, CARD_HEIGHT)
	layout.FillDirectionMaxCells = 3
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Left
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll
	grid = layout

	for index, skinId in SkinCatalog.Order do
		buildCard(skinId, index, scroll)
	end

	local chip = Instance.new("Frame")
	chip.Name = "Toast"
	chip.AnchorPoint = Vector2.new(0.5, 0)
	chip.Position = UDim2.new(0.5, 0, 0, 18)
	chip.Size = UDim2.fromOffset(340, 34)
	chip.BackgroundColor3 = UITheme.Colors.Negative
	chip.BorderSizePixel = 0
	chip.Visible = false
	chip.ZIndex = 10
	chip.Parent = panel.instance
	UITheme.corner(UITheme.Radius.Pill).Parent = chip
	toastFrame = chip

	local message = UITheme.label("", UITheme.TextSizes.Body, UITheme.Colors.Text, UITheme.Fonts.Bold)
	message.Name = "Message"
	message.Size = UDim2.fromScale(1, 1)
	message.TextXAlignment = Enum.TextXAlignment.Center
	message.ZIndex = 11
	message.Parent = chip
	toastLabel = message

	UIController.registerMenu("Shop", panel:asMenuHandle())
	-- Panel closes itself from its X button and its backdrop, and those paths do
	-- not reach UIController — which is what tells MouseLockController to
	-- re-capture the cursor. Both are re-pointed at closeMenu so every way out of
	-- the shop ends up in the same place.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu("Shop")
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu("Shop")
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu("Shop")
	end)

	trove:Add(ClientState.CoinsChanged:Connect(function(newCoins: number)
		coins:set(newCoins)
		refresh()
	end))
	trove:Add(ClientState.ProfileChanged:Connect(function()
		coins:setInstant(ClientState.coins)
		refresh()
	end))
	trove:Add(UIController.ScaleChanged:Connect(function(scale: number)
		applyColumns(scale < 1 and 2 or 3)
	end))

	applyColumns(UIController.scale < 1 and 2 or 3)
	refresh()
end

function ShopScreen.stop()
	trove:Clean()
	table.clear(cards)
	panel = nil
	coins = nil
	grid = nil
	toastFrame = nil
	toastLabel = nil
end

return ShopScreen
