--!nonstrict
--[[
	ListRow.luau
	One row of a vertical list: leaderboard entry, friend, owned skin, spin
	history. Designed to sit inside a ScrollingFrame with a UIListLayout, so it
	is full width with a fixed pixel height and honours LayoutOrder.

	props = {
		parent: Instance,              -- required
		title: string,                 -- primary line
		subtitle: string?,             -- dim second line
		value: string?,                -- right-hand figure (kills, price, "OWNED")
		icon: string?,                 -- leading glyph, drawn in a tinted square
		accentColor: Color3?,          -- left bar + icon tint; default UITheme.Colors.Accent
		valueColor: Color3?,           -- default UITheme.Colors.Text
		layoutOrder: number?,
		height: number?,               -- default 56 px
		selected: boolean?,
		name: string?,
		onActivated: (() -> ())?,      -- makes the whole row clickable
	}

	Returns an object:
		.instance      TextButton (root — inert unless onActivated is supplied)
		:update(props)            -- partial: only the keys present are applied
		:setSelected(selected)
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local ListRow = {}
ListRow.__index = ListRow

local DEFAULT_HEIGHT = 56
local ICON_SIZE = 34
local ACCENT_BAR_WIDTH = 3

function ListRow.create(props: { [string]: any })
	assert(type(props) == "table", "ListRow.create expects a props table")
	assert(typeof(props.parent) == "Instance", "ListRow.create requires props.parent")

	local accent = props.accentColor or UITheme.Colors.Accent
	local height = props.height or DEFAULT_HEIGHT
	local trove = Trove.new()

	local root = Instance.new("TextButton")
	root.Name = props.name or "ListRow"
	root.Size = UDim2.new(1, 0, 0, height)
	root.LayoutOrder = props.layoutOrder or 0
	root.BackgroundColor3 = UITheme.Colors.PanelLight
	root.BackgroundTransparency = 0.25
	root.BorderSizePixel = 0
	root.AutoButtonColor = false
	root.Text = ""
	-- A row with no callback must not eat clicks meant for the panel behind it.
	root.Active = props.onActivated ~= nil
	root.ClipsDescendants = true
	UITheme.corner(UITheme.Radius.Small).Parent = root

	local stroke = UITheme.stroke(UITheme.Colors.Stroke, 1)
	stroke.Transparency = 0.4
	stroke.Parent = root

	local accentBar = Instance.new("Frame")
	accentBar.Name = "Accent"
	accentBar.Size = UDim2.new(0, ACCENT_BAR_WIDTH, 1, 0)
	accentBar.BackgroundColor3 = accent
	accentBar.BorderSizePixel = 0
	accentBar.ZIndex = 2
	accentBar.Parent = root

	local iconHolder = Instance.new("Frame")
	iconHolder.Name = "Icon"
	iconHolder.AnchorPoint = Vector2.new(0, 0.5)
	iconHolder.Position = UDim2.new(0, ACCENT_BAR_WIDTH + 9, 0.5, 0)
	iconHolder.Size = UDim2.fromOffset(ICON_SIZE, ICON_SIZE)
	iconHolder.BackgroundColor3 = accent
	iconHolder.BackgroundTransparency = 0.82
	iconHolder.BorderSizePixel = 0
	iconHolder.ZIndex = 2
	iconHolder.Visible = props.icon ~= nil and props.icon ~= ""
	iconHolder.Parent = root
	UITheme.corner(UITheme.Radius.Small).Parent = iconHolder

	local iconLabel = UITheme.label(props.icon or "", UITheme.TextSizes.Subtitle, accent, UITheme.Fonts.Bold)
	iconLabel.Name = "Glyph"
	iconLabel.Size = UDim2.fromScale(1, 1)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center
	iconLabel.ZIndex = 3
	iconLabel.Parent = iconHolder

	local textLeft = ACCENT_BAR_WIDTH + 9 + (iconHolder.Visible and ICON_SIZE + 10 or 0)

	local text = Instance.new("Frame")
	text.Name = "Text"
	text.AnchorPoint = Vector2.new(0, 0.5)
	text.Position = UDim2.new(0, textLeft, 0.5, 0)
	text.Size = UDim2.new(1, -(textLeft + 96), 1, -12)
	text.BackgroundTransparency = 1
	text.ZIndex = 2
	text.Parent = root

	local hasSubtitle = props.subtitle ~= nil and props.subtitle ~= ""

	local titleLabel = UITheme.label(props.title or "", UITheme.TextSizes.Body, UITheme.Colors.Text, UITheme.Fonts.Bold)
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, 0, hasSubtitle and 0.55 or 1, 0)
	titleLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	titleLabel.ZIndex = 2
	titleLabel.Parent = text

	local subtitleLabel = UITheme.label(props.subtitle or "", UITheme.TextSizes.Small, UITheme.Colors.TextDim)
	subtitleLabel.Name = "Subtitle"
	subtitleLabel.AnchorPoint = Vector2.new(0, 1)
	subtitleLabel.Position = UDim2.fromScale(0, 1)
	subtitleLabel.Size = UDim2.new(1, 0, 0.45, 0)
	subtitleLabel.TextYAlignment = Enum.TextYAlignment.Top
	subtitleLabel.Visible = hasSubtitle
	subtitleLabel.ZIndex = 2
	subtitleLabel.Parent = text

	local valueLabel = UITheme.label(
		props.value or "",
		UITheme.TextSizes.Subtitle,
		props.valueColor or UITheme.Colors.Text,
		UITheme.Fonts.Number
	)
	valueLabel.Name = "Value"
	valueLabel.AnchorPoint = Vector2.new(1, 0.5)
	valueLabel.Position = UDim2.new(1, -14, 0.5, 0)
	valueLabel.Size = UDim2.new(0, 88, 1, 0)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.Visible = props.value ~= nil and props.value ~= ""
	valueLabel.ZIndex = 2
	valueLabel.Parent = root

	local self = setmetatable({
		instance = root,
		titleLabel = titleLabel,
		subtitleLabel = subtitleLabel,
		valueLabel = valueLabel,
		iconLabel = iconLabel,
		_trove = trove,
		_stroke = stroke,
		_accentBar = accentBar,
		_iconHolder = iconHolder,
		_text = text,
		_accent = accent,
		_selected = false,
		_onActivated = props.onActivated,
	}, ListRow)

	if props.onActivated then
		trove:Connect(root.MouseEnter, function()
			TweenService:Create(root, UITheme.Tween.Fast, { BackgroundTransparency = 0.05 }):Play()
		end)
		trove:Connect(root.MouseLeave, function()
			local target = self._selected and 0.05 or 0.25
			TweenService:Create(root, UITheme.Tween.Fast, { BackgroundTransparency = target }):Play()
		end)
		trove:Connect(root.Activated, function()
			if self._onActivated then
				self._onActivated()
			end
		end)
	end

	if props.selected then
		self:setSelected(true)
	end

	trove:Add(root)
	root.Parent = props.parent

	return self
end

--[[
	Partial update: pass only the props that changed. Recycling a row through
	this instead of rebuilding it is what keeps a long leaderboard cheap.
]]
function ListRow:update(props: { [string]: any })
	if type(props) ~= "table" then
		return
	end

	if props.title ~= nil then
		self.titleLabel.Text = props.title
	end

	if props.subtitle ~= nil then
		local hasSubtitle = props.subtitle ~= ""
		self.subtitleLabel.Text = props.subtitle
		self.subtitleLabel.Visible = hasSubtitle
		self.titleLabel.Size = UDim2.new(1, 0, hasSubtitle and 0.55 or 1, 0)
	end

	if props.value ~= nil then
		self.valueLabel.Text = props.value
		self.valueLabel.Visible = props.value ~= ""
	end

	if props.valueColor ~= nil then
		self.valueLabel.TextColor3 = props.valueColor
	end

	if props.icon ~= nil then
		local hasIcon = props.icon ~= ""
		self.iconLabel.Text = props.icon
		self._iconHolder.Visible = hasIcon

		local textLeft = ACCENT_BAR_WIDTH + 9 + (hasIcon and ICON_SIZE + 10 or 0)
		self._text.Position = UDim2.new(0, textLeft, 0.5, 0)
		self._text.Size = UDim2.new(1, -(textLeft + 96), 1, -12)
	end

	if props.accentColor ~= nil then
		self._accent = props.accentColor
		self._accentBar.BackgroundColor3 = props.accentColor
		self._iconHolder.BackgroundColor3 = props.accentColor
		self.iconLabel.TextColor3 = props.accentColor
		if self._selected then
			self._stroke.Color = props.accentColor
		end
	end

	if props.layoutOrder ~= nil then
		self.instance.LayoutOrder = props.layoutOrder
	end

	if props.onActivated ~= nil then
		self._onActivated = props.onActivated
	end

	if props.selected ~= nil then
		self:setSelected(props.selected)
	end
end

function ListRow:setSelected(selected: boolean)
	selected = selected == true
	self._selected = selected

	self._stroke.Color = selected and self._accent or UITheme.Colors.Stroke
	self._stroke.Transparency = selected and 0 or 0.4
	TweenService:Create(self.instance, UITheme.Tween.Fast, {
		BackgroundTransparency = selected and 0.05 or 0.25,
	}):Play()
end

function ListRow:isSelected(): boolean
	return self._selected
end

function ListRow:destroy()
	self._trove:Clean()
end

return ListRow
