--!nonstrict
--[[
	CurrencyLabel.luau
	The gold coin chip in the HUD and in every shop header. `:set` counts up (or
	down) to the new balance instead of snapping, so an award reads as an award.

	props = {
		parent: Instance,              -- required
		position: UDim2?,              -- default UDim2.new(1, -16, 0, 16)
		size: UDim2?,                  -- default UDim2.fromOffset(140, 36)
		anchorPoint: Vector2?,         -- default Vector2.new(1, 0)
		value: number?,                -- initial balance, shown without animation
		layoutOrder: number?,
		name: string?,
	}

	Returns an object:
		.instance      Frame (the root chip)
		.valueLabel    TextLabel
		:set(value)               -- animated count
		:setInstant(value)        -- no animation (initial fill, screen reopen)
		:get(): number            -- the value last requested, not the mid-tween number
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local MathUtil = require(Shared.Util.MathUtil)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local CurrencyLabel = {}
CurrencyLabel.__index = CurrencyLabel

local DEFAULT_SIZE = UDim2.fromOffset(140, 36)
local COIN_DIAMETER = 18
local POP_SCALE = 1.12

--[[
	Groups a balance with thousands separators. Roblox has no locale formatter, so
	this is done by hand; the value is always a whole number of coins.
]]
local function formatCoins(value: number): string
	local text = tostring(math.max(MathUtil.round(value), 0))
	local grouped = text
	local count

	repeat
		grouped, count = string.gsub(grouped, "^(%d+)(%d%d%d)", "%1,%2")
	until count == 0

	return grouped
end

function CurrencyLabel.create(props: { [string]: any })
	assert(type(props) == "table", "CurrencyLabel.create expects a props table")
	assert(typeof(props.parent) == "Instance", "CurrencyLabel.create requires props.parent")

	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = props.name or "CurrencyLabel"
	root.Size = props.size or DEFAULT_SIZE
	root.Position = props.position or UDim2.new(1, -16, 0, 16)
	root.AnchorPoint = props.anchorPoint or Vector2.new(1, 0)
	root.LayoutOrder = props.layoutOrder or 0
	root.BackgroundColor3 = UITheme.Colors.PanelDark
	root.BackgroundTransparency = 0.1
	root.BorderSizePixel = 0
	UITheme.corner(UITheme.Radius.Pill).Parent = root
	UITheme.stroke(UITheme.Colors.Coin, 1.5).Parent = root

	local scale = Instance.new("UIScale")
	scale.Name = "PopScale"
	scale.Parent = root

	local padding = UITheme.padding(10, 0)
	padding.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = root

	-- The coin is a gold disc drawn with a pill corner: there are no image
	-- assets in this project.
	local coin = Instance.new("Frame")
	coin.Name = "Coin"
	coin.LayoutOrder = 1
	coin.Size = UDim2.fromOffset(COIN_DIAMETER, COIN_DIAMETER)
	coin.BackgroundColor3 = UITheme.Colors.Coin
	coin.BorderSizePixel = 0
	coin.Parent = root
	UITheme.corner(UITheme.Radius.Pill).Parent = coin
	UITheme.gradient(UITheme.Colors.Coin, Color3.fromRGB(196, 138, 12), 90).Parent = coin

	local valueLabel = UITheme.label("0", UITheme.TextSizes.Subtitle, UITheme.Colors.Coin, UITheme.Fonts.Number)
	valueLabel.Name = "Value"
	valueLabel.LayoutOrder = 2
	valueLabel.AutomaticSize = Enum.AutomaticSize.X
	valueLabel.Size = UDim2.new(0, 0, 1, 0)
	valueLabel.TextXAlignment = Enum.TextXAlignment.Left
	valueLabel.Parent = root

	-- TweenService only animates Instances, so the counter rides on a NumberValue
	-- parented to the chip (destroyed with it).
	local counter = Instance.new("NumberValue")
	counter.Name = "Counter"
	counter.Value = props.value or 0
	counter.Parent = root

	local self = setmetatable({
		instance = root,
		valueLabel = valueLabel,
		coin = coin,
		_trove = trove,
		_counter = counter,
		_scale = scale,
		_tween = nil,
		_value = props.value or 0,
	}, CurrencyLabel)

	trove:Connect(counter.Changed, function(value: number)
		valueLabel.Text = formatCoins(value)
	end)

	valueLabel.Text = formatCoins(self._value)

	trove:Add(root)
	root.Parent = props.parent

	return self
end

function CurrencyLabel:get(): number
	return self._value
end

function CurrencyLabel:setInstant(value: number)
	if type(value) ~= "number" or not MathUtil.isFinite(value) then
		return
	end

	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end

	self._value = value
	self._counter.Value = value
	self.valueLabel.Text = formatCoins(value)
end

--[[
	Animates to `value`. A gain flashes the chip green-gold and pops it; a loss
	just counts down, so spending never looks like a reward.
]]
function CurrencyLabel:set(value: number)
	if type(value) ~= "number" or not MathUtil.isFinite(value) then
		return
	end

	local previous = self._value
	if value == previous then
		return
	end
	self._value = value

	if self._tween then
		self._tween:Cancel()
	end

	local tween = TweenService:Create(self._counter, UITheme.Tween.Count, { Value = value })
	self._tween = tween
	tween:Play()

	if value > previous then
		self._scale.Scale = 1
		TweenService:Create(self._scale, UITheme.Tween.Fast, { Scale = POP_SCALE }):Play()
		task.delay(UITheme.Tween.Fast.Time, function()
			if self._scale.Parent then
				TweenService:Create(self._scale, UITheme.Tween.Pop, { Scale = 1 }):Play()
			end
		end)
	end
end

function CurrencyLabel:destroy()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end
	self._trove:Clean()
end

return CurrencyLabel
