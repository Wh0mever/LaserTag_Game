--!nonstrict
--[[
	Button.luau
	Rounded action button with hover/press feedback and an optional key-hint
	badge (the E / Q / F / P chips on the hub side buttons).

	props = {
		text: string,                  -- label; "" for an icon-only button
		parent: Instance,              -- required
		size: UDim2?,                  -- default UDim2.new(0, 180, 0, 44)
		position: UDim2?,
		anchorPoint: Vector2?,
		color: Color3?,                -- fill; default UITheme.Colors.PanelLight
		textColor: Color3?,            -- default UITheme.Colors.Text
		icon: string?,                 -- leading glyph/emoji (no asset ids exist in this project)
		keyHint: string?,              -- e.g. "E" — drawn as a badge in the top-right corner
		layoutOrder: number?,
		name: string?,                 -- Instance name; defaults to the text
		onActivated: (() -> ())?,      -- fired by .Activated (mouse, touch and gamepad)
	}

	Returns an object:
		.instance      TextButton (the root)
		.label         TextLabel  (nil when text is "" and no icon is used)
		:setText(text)
		:setIcon(glyph)
		:setKeyHint(key)          -- nil hides the badge
		:setColor(color)
		:setEnabled(enabled)      -- greys out and stops firing onActivated
		:isEnabled()
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local Button = {}
Button.__index = Button

local DEFAULT_SIZE = UDim2.new(0, 180, 0, 44)
local HOVER_LIGHTEN = 0.08
local PRESS_SCALE = 0.95

local function lighten(color: Color3, amount: number): Color3
	return Color3.new(math.min(color.R + amount, 1), math.min(color.G + amount, 1), math.min(color.B + amount, 1))
end

local function buildKeyHint(parent: Instance, key: string): Frame
	local badge = Instance.new("Frame")
	badge.Name = "KeyHint"
	badge.AnchorPoint = Vector2.new(1, 0)
	badge.Position = UDim2.new(1, -6, 0, 6)
	badge.Size = UDim2.fromOffset(20, 20)
	badge.BackgroundColor3 = UITheme.Colors.PanelDark
	badge.BackgroundTransparency = 0.15
	badge.BorderSizePixel = 0
	badge.ZIndex = 3
	UITheme.corner(UITheme.Radius.Small).Parent = badge
	UITheme.stroke(UITheme.Colors.Accent, 1).Parent = badge

	local label = UITheme.label(key, UITheme.TextSizes.Tiny, UITheme.Colors.Accent, UITheme.Fonts.Bold)
	label.Name = "Key"
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.ZIndex = 4
	label.Parent = badge

	badge.Parent = parent
	return badge
end

--[[
	Builds the button. `props.parent` is required; everything else has a default.
]]
function Button.create(props: { [string]: any })
	assert(type(props) == "table", "Button.create expects a props table")
	assert(typeof(props.parent) == "Instance", "Button.create requires props.parent")

	local baseColor = props.color or UITheme.Colors.PanelLight
	local trove = Trove.new()

	local root = Instance.new("TextButton")
	root.Name = props.name or (props.text ~= "" and props.text) or "Button"
	root.Size = props.size or DEFAULT_SIZE
	root.Position = props.position or UDim2.fromScale(0, 0)
	root.AnchorPoint = props.anchorPoint or Vector2.new(0, 0)
	root.LayoutOrder = props.layoutOrder or 0
	root.BackgroundColor3 = baseColor
	root.BorderSizePixel = 0
	-- Hover and press are tweened by hand, so the engine's instant colour flash
	-- would fight them.
	root.AutoButtonColor = false
	root.Text = ""
	root.ClipsDescendants = false
	UITheme.corner(UITheme.Radius.Medium).Parent = root

	local stroke = UITheme.stroke(UITheme.Colors.Stroke, 1)
	stroke.Parent = root

	local scale = Instance.new("UIScale")
	scale.Name = "PressScale"
	scale.Parent = root

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = 2
	content.Parent = root
	UITheme.padding(12, 0).Parent = content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = content

	local iconLabel = UITheme.label(props.icon or "", UITheme.TextSizes.Subtitle, props.textColor)
	iconLabel.Name = "Icon"
	iconLabel.LayoutOrder = 1
	iconLabel.Size = UDim2.fromOffset(20, 20)
	iconLabel.TextXAlignment = Enum.TextXAlignment.Center
	iconLabel.Visible = props.icon ~= nil and props.icon ~= ""
	iconLabel.ZIndex = 2
	iconLabel.Parent = content

	local textLabel = UITheme.label(props.text or "", UITheme.TextSizes.Body, props.textColor, UITheme.Fonts.Bold)
	textLabel.Name = "Label"
	textLabel.LayoutOrder = 2
	textLabel.AutomaticSize = Enum.AutomaticSize.X
	textLabel.Size = UDim2.new(0, 0, 1, 0)
	textLabel.TextXAlignment = Enum.TextXAlignment.Center
	textLabel.ZIndex = 2
	textLabel.Parent = content

	local self = setmetatable({
		instance = root,
		label = textLabel,
		icon = iconLabel,
		_trove = trove,
		_stroke = stroke,
		_scale = scale,
		_baseColor = baseColor,
		_enabled = true,
		_keyHint = nil,
		_onActivated = props.onActivated,
	}, Button)

	if props.keyHint then
		self._keyHint = trove:Add(buildKeyHint(root, props.keyHint))
	end

	trove:Connect(root.MouseEnter, function()
		if not self._enabled then
			return
		end
		TweenService:Create(root, UITheme.Tween.Fast, {
			BackgroundColor3 = lighten(self._baseColor, HOVER_LIGHTEN),
		}):Play()
		TweenService:Create(stroke, UITheme.Tween.Fast, { Color = UITheme.Colors.Accent }):Play()
	end)

	trove:Connect(root.MouseLeave, function()
		TweenService:Create(root, UITheme.Tween.Fast, { BackgroundColor3 = self._baseColor }):Play()
		TweenService:Create(stroke, UITheme.Tween.Fast, { Color = UITheme.Colors.Stroke }):Play()
		TweenService:Create(scale, UITheme.Tween.Fast, { Scale = 1 }):Play()
	end)

	trove:Connect(root.MouseButton1Down, function()
		if not self._enabled then
			return
		end
		TweenService:Create(scale, UITheme.Tween.Fast, { Scale = PRESS_SCALE }):Play()
	end)

	trove:Connect(root.MouseButton1Up, function()
		TweenService:Create(scale, UITheme.Tween.Pop, { Scale = 1 }):Play()
	end)

	-- Activated (not MouseButton1Click) so touch taps and gamepad A both work.
	trove:Connect(root.Activated, function()
		if not self._enabled then
			return
		end
		TweenService:Create(scale, UITheme.Tween.Pop, { Scale = 1 }):Play()
		if self._onActivated then
			self._onActivated()
		end
	end)

	trove:Add(root)
	root.Parent = props.parent

	return self
end

function Button:setText(text: string)
	self.label.Text = text or ""
end

function Button:setIcon(glyph: string?)
	self.icon.Text = glyph or ""
	self.icon.Visible = glyph ~= nil and glyph ~= ""
end

function Button:setKeyHint(key: string?)
	if self._keyHint then
		self._trove:Remove(self._keyHint)
		self._keyHint:Destroy()
		self._keyHint = nil
	end
	if key then
		self._keyHint = self._trove:Add(buildKeyHint(self.instance, key))
	end
end

function Button:setColor(color: Color3)
	self._baseColor = color
	self.instance.BackgroundColor3 = color
end

function Button:setOnActivated(callback: (() -> ())?)
	self._onActivated = callback
end

function Button:setEnabled(enabled: boolean)
	enabled = enabled ~= false
	self._enabled = enabled
	self.instance.Active = enabled
	self.instance.AutoButtonColor = false
	self.instance.BackgroundColor3 = enabled and self._baseColor or UITheme.Colors.Disabled
	self.label.TextTransparency = enabled and 0 or 0.4
	self.icon.TextTransparency = enabled and 0 or 0.4
end

function Button:isEnabled(): boolean
	return self._enabled
end

function Button:destroy()
	self._trove:Clean()
end

return Button
