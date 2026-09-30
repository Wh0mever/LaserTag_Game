--!nonstrict
--[[
	Slider.luau
	A labelled value slider: title, hint, live value readout and a draggable
	track. Roblox ships no slider, so this is built from a TextButton track, a
	fill frame and a knob.

	props = {
		settingId: string,             -- key into SettingsConfig; supplies bounds,
		                               -- step, formatting and the label text
		value: number,                 -- initial value
		parent: Instance,              -- required
		layoutOrder: number?,
		accentColor: Color3?,          -- fill and knob; default UITheme.Colors.Accent
		onChanged: ((value: number) -> ())?,   -- every step while dragging
		onCommitted: ((value: number) -> ())?, -- once, on release
	}

	Returns an object:
		.instance      Frame (the root)
		:setValue(v)   -- moves the knob without firing onChanged
		:getValue()
		:destroy()

	INPUT MODEL
	The track is a TextButton so it takes mouse, touch and gamepad focus for
	free, and dragging is tracked through UserInputService rather than the
	button's own events: a drag that leaves the track vertically must keep
	working, and InputChanged on the button stops firing the moment the pointer
	is outside it. The drag ends on the global InputEnded so releasing the mouse
	anywhere on screen finishes cleanly rather than leaving the knob stuck to the
	cursor.

	`onChanged` fires on every step so a sensitivity change can be felt while
	dragging; `onCommitted` fires once on release, which is what the caller should
	use for anything that costs something — a network save, for instance.

	A MOUSE press jumps to the pointer at once. A TOUCH does not: the sliders sit
	in a vertical ScrollingFrame, on a phone a large share of which is slider
	track, and a finger that lands on one to scroll the panel used to set the
	value where it touched down and save it on release. So a touch waits to see
	what it is. Sideways past DRAG_SLOP pixels it is a drag and follows the
	finger; upwards or downwards it is a scroll and this slider never hears of
	it; lifted without going anywhere it is a tap and goes to that point.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local SettingsConfig = require(Shared.Config.SettingsConfig)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local Slider = {}
Slider.__index = Slider

local ROW_HEIGHT = 62
local TRACK_HEIGHT = 6
-- The part of the row that answers a touch: the knob's height and then some,
-- which is what a thumb can actually hit.
local HIT_HEIGHT = 32
local KNOB_SIZE = 18
-- How far a finger may wander before it has decided what it is doing. Real
-- pixels: a thumb resting on glass moves a few without meaning to.
local DRAG_SLOP = 8

--[[
	Where a screen-space X sits along `track`, as 0..1.
	AbsolutePosition/AbsoluteSize are already in the same space as an InputObject
	position, so no GuiInset correction is needed for the X axis.
]]
local function fractionFor(track: GuiObject, screenX: number): number
	local width = track.AbsoluteSize.X
	if width <= 0 then
		return 0
	end
	return math.clamp((screenX - track.AbsolutePosition.X) / width, 0, 1)
end

function Slider.create(props: { [string]: any })
	assert(type(props) == "table", "Slider.create expects a props table")
	assert(typeof(props.parent) == "Instance", "Slider.create requires props.parent")

	local definition = SettingsConfig.get(props.settingId)
	assert(definition, `Slider.create: unknown setting "{tostring(props.settingId)}"`)

	local self = setmetatable({}, Slider)
	local trove = Trove.new()
	self._trove = trove
	self._settingId = definition.id
	self._onChanged = props.onChanged
	self._onCommitted = props.onCommitted
	self._value = SettingsConfig.clamp(definition.id, props.value)
	self._dragging = false
	-- The touch that has landed on the track and not yet decided: its
	-- InputObject and where it began.
	self._pending = nil
	-- The InputObject of the touch that is dragging, so a second finger
	-- elsewhere on the screen cannot steer the knob or end the drag.
	self._dragInput = nil

	local accent = props.accentColor or UITheme.Colors.Accent

	local root = Instance.new("Frame")
	root.Name = `Setting_{definition.id}`
	root.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	root.BackgroundTransparency = 1
	root.LayoutOrder = props.layoutOrder or 0
	root.ZIndex = 3
	root.Parent = props.parent
	self.instance = root
	trove:Add(root)

	local title = UITheme.label(definition.label, UITheme.TextSizes.Small, UITheme.Colors.Text, UITheme.Fonts.Bold)
	title.Name = "Title"
	title.Size = UDim2.new(1, -80, 0, 16)
	title.ZIndex = 3
	title.Parent = root

	local readout = UITheme.label(
		SettingsConfig.display(definition.id, self._value),
		UITheme.TextSizes.Small,
		accent,
		UITheme.Fonts.Number
	)
	readout.Name = "Value"
	readout.AnchorPoint = Vector2.new(1, 0)
	readout.Position = UDim2.fromScale(1, 0)
	readout.Size = UDim2.fromOffset(76, 16)
	readout.TextXAlignment = Enum.TextXAlignment.Right
	readout.ZIndex = 3
	readout.Parent = root
	self._readout = readout

	local hint = UITheme.label(definition.hint, UITheme.TextSizes.Tiny, UITheme.Colors.TextMuted)
	hint.Name = "Hint"
	hint.Position = UDim2.new(0, 0, 0, 18)
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.ZIndex = 3
	hint.Parent = root

	--[[
		The track is an invisible button HIT_HEIGHT tall, with the visible bar
		centred inside it. The bar itself used to be the button, and it is 6 px
		tall: a thumb had to land on a strip about a millimetre and a half high,
		and a touch on the knob's upper or lower half, or anywhere else in the
		row, did nothing. Same width as the bar, so the value under a finger is
		computed exactly as before.
	]]
	local track = Instance.new("TextButton")
	track.Name = "Track"
	track.Text = ""
	track.AutoButtonColor = false
	track.AnchorPoint = Vector2.new(0, 0.5)
	track.Position = UDim2.new(0, 0, 0, 48)
	track.Size = UDim2.new(1, 0, 0, HIT_HEIGHT)
	track.BackgroundTransparency = 1
	track.BorderSizePixel = 0
	track.ZIndex = 3
	track.Parent = root
	self._track = track

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.AnchorPoint = Vector2.new(0, 0.5)
	bar.Position = UDim2.fromScale(0, 0.5)
	bar.Size = UDim2.new(1, 0, 0, TRACK_HEIGHT)
	bar.BackgroundColor3 = UITheme.Colors.PanelDark
	bar.BorderSizePixel = 0
	bar.ZIndex = 3
	bar.Parent = track
	UITheme.corner(UITheme.Radius.Pill).Parent = bar

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(SettingsConfig.toFraction(definition.id, self._value), 1)
	fill.BackgroundColor3 = accent
	fill.BorderSizePixel = 0
	fill.ZIndex = 4
	fill.Parent = bar
	UITheme.corner(UITheme.Radius.Pill).Parent = fill
	self._fill = fill

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(SettingsConfig.toFraction(definition.id, self._value), 0.5)
	knob.Size = UDim2.fromOffset(KNOB_SIZE, KNOB_SIZE)
	knob.BackgroundColor3 = UITheme.Colors.Text
	knob.BorderSizePixel = 0
	knob.ZIndex = 5
	knob.Parent = bar
	UITheme.corner(UITheme.Radius.Pill).Parent = knob
	UITheme.stroke(accent, 2).Parent = knob
	self._knob = knob

	--[[
		Move to `fraction` and report it. `notify` is false when the caller is
		setting the value programmatically, so loading a profile cannot look like
		the player dragging.
	]]
	local function applyFraction(fraction: number, notify: boolean)
		local value = SettingsConfig.fromFraction(definition.id, fraction)
		if value == nil then
			return
		end

		local changed = value ~= self._value
		self._value = value

		local settled = SettingsConfig.toFraction(definition.id, value)
		fill.Size = UDim2.fromScale(settled, 1)
		knob.Position = UDim2.fromScale(settled, 0.5)
		readout.Text = SettingsConfig.display(definition.id, value)

		if notify and changed and self._onChanged then
			self._onChanged(value)
		end
	end
	self._applyFraction = applyFraction

	trove:Connect(track.InputBegan, function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self._pending = nil
			self._dragging = true
			-- Jump to where the track was pressed: clicking a point on a slider
			-- should go there, not nudge from wherever the knob happened to be.
			applyFraction(fractionFor(track, input.Position.X), true)
		elseif input.UserInputType == Enum.UserInputType.Touch and not self._dragging then
			-- Replaces whatever was pending: a touch that never reported its
			-- end (the app lost focus mid-gesture) must not leave the slider
			-- waiting for it forever.
			self._pending = { input = input, x = input.Position.X, y = input.Position.Y }
		end
	end)

	trove:Connect(UserInputService.InputChanged, function(input: InputObject)
		local pending = self._pending
		if pending then
			if input ~= pending.input then
				return
			end

			local dx = math.abs(input.Position.X - pending.x)
			local dy = math.abs(input.Position.Y - pending.y)
			if math.max(dx, dy) < DRAG_SLOP then
				return
			end

			self._pending = nil
			if dy > dx then
				-- Vertical: the panel is being scrolled, not the slider dragged.
				return
			end
			self._dragging = true
			self._dragInput = input
			applyFraction(fractionFor(track, input.Position.X), true)
			return
		end

		if not self._dragging then
			return
		end
		if self._dragInput then
			if input ~= self._dragInput then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end

		applyFraction(fractionFor(track, input.Position.X), true)
	end)

	trove:Connect(UserInputService.InputEnded, function(input: InputObject)
		local pending = self._pending
		if pending and input == pending.input then
			-- Never went anywhere: a tap. It goes to the point touched, and is
			-- saved if that moved the slider.
			self._pending = nil
			local before = self._value
			applyFraction(fractionFor(track, input.Position.X), true)
			if self._value ~= before and self._onCommitted then
				self._onCommitted(self._value)
			end
			return
		end

		if not self._dragging then
			return
		end
		if self._dragInput then
			if input ~= self._dragInput then
				return
			end
		elseif input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end

		self._dragging = false
		self._dragInput = nil
		if self._onCommitted then
			self._onCommitted(self._value)
		end
	end)

	return self
end

--[[
	Set the value without firing onChanged. Used when a profile arrives or the
	panel resets to defaults — neither is the player dragging.
]]
function Slider:setValue(value: number)
	self._applyFraction(SettingsConfig.toFraction(self._settingId, value), false)
end

function Slider:getValue(): number
	return self._value
end

function Slider:destroy()
	self._trove:Clean()
	self.instance = nil
end

return Slider
