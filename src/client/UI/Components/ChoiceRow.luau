--!nonstrict
--[[
	ChoiceRow.luau
	The settings row for a `kind = "choice"` setting: title, hint, and one button
	per option with the current one lit.

	Deliberately not a slider with two stops. A slider says "more of this" and
	invites dragging to find a middle; first and third person have no middle, and
	a control that implies one is a control that lies about the thing it sets.
	Two labelled buttons say what they do before they are touched, which matters
	most for the setting a player reaches for when the game does not look the way
	they expected.

	props = {
		settingId: string,             -- key into SettingsConfig; supplies the
		                               -- label, hint and options
		value: string,                 -- initially selected option id
		parent: Instance,              -- required
		layoutOrder: number?,
		accentColor: Color3?,
		onChanged: ((value: string) -> ())?,  -- fires once, on a real change
	}

	Returns an object:
		.instance      Frame (the root)
		:setValue(id)  -- selects without firing onChanged
		:getValue()
		:destroy()

	Selecting the option that is already selected does nothing at all: no
	callback, so the panel's save path is not spent on a player tapping the
	button that is already lit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local SettingsConfig = require(Shared.Config.SettingsConfig)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local ChoiceRow = {}
ChoiceRow.__index = ChoiceRow

-- Matches Slider's row height so the two kinds line up in one list.
local ROW_HEIGHT = 62
local BUTTON_HEIGHT = 26
local BUTTON_GAP = 8

--[[
	Builds the row. Returns nil for a setting that is not a choice rather than
	rendering an empty row: the caller picks the control from the definition, so
	reaching here with a slider is a bug worth failing visibly at the call site.
]]
function ChoiceRow.create(props: any)
	assert(type(props) == "table", "ChoiceRow.create expects a props table")
	assert(typeof(props.parent) == "Instance", "ChoiceRow.create requires props.parent")

	local definition = SettingsConfig.get(props.settingId)
	if not definition or definition.kind ~= "choice" then
		return nil
	end

	local self = setmetatable({}, ChoiceRow)
	local trove = Trove.new()
	self._trove = trove
	self._settingId = definition.id
	self._onChanged = props.onChanged
	self._buttons = {}
	self._value = SettingsConfig.clamp(definition.id, props.value)

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
	title.Size = UDim2.new(1, 0, 0, 16)
	title.ZIndex = 3
	title.Parent = root

	local hint = UITheme.label(definition.hint, UITheme.TextSizes.Tiny, UITheme.Colors.TextMuted)
	hint.Name = "Hint"
	hint.Position = UDim2.new(0, 0, 0, 18)
	hint.Size = UDim2.new(1, 0, 0, 14)
	hint.ZIndex = 3
	hint.Parent = root

	local row = Instance.new("Frame")
	row.Name = "Options"
	row.Position = UDim2.new(0, 0, 1, -BUTTON_HEIGHT)
	row.Size = UDim2.new(1, 0, 0, BUTTON_HEIGHT)
	row.BackgroundTransparency = 1
	row.ZIndex = 3
	row.Parent = root

	-- The options share the width evenly, and the gaps come out of that width
	-- rather than being added to it, so the last button lands on the right edge
	-- instead of past it however many options there are.
	local count = #definition.options
	local share = 1 / count
	local gap = BUTTON_GAP * (count - 1) / count

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, BUTTON_GAP)
	layout.Parent = row

	for index, option in definition.options do
		local button = Instance.new("TextButton")
		button.Name = option.id
		button.LayoutOrder = index
		button.Size = UDim2.new(share, -gap, 1, 0)
		button.AutoButtonColor = false
		button.Text = option.label
		button.TextSize = UITheme.TextSizes.Tiny
		button.Font = UITheme.Fonts.Bold
		button.BorderSizePixel = 0
		button.ZIndex = 3
		button.Parent = row
		UITheme.corner(UITheme.Radius.Small).Parent = button

		local stroke = UITheme.stroke(UITheme.Colors.Stroke, 1)
		stroke.Parent = button

		self._buttons[option.id] = { instance = button, stroke = stroke }

		trove:Connect(button.Activated, function()
			self:_select(option.id, true)
		end)
	end

	self._accent = accent
	self:_paint()

	return self
end

--[[
	Lights the selected option and dims the rest.
]]
function ChoiceRow:_paint()
	for id, entry in self._buttons do
		local selected = id == self._value
		entry.instance.BackgroundColor3 = if selected then self._accent else UITheme.Colors.PanelLight
		entry.instance.TextColor3 = if selected then UITheme.Colors.PanelDark else UITheme.Colors.TextDim
		entry.stroke.Color = if selected then self._accent else UITheme.Colors.Stroke
		entry.stroke.Transparency = if selected then 0 else 0.4
	end
end

function ChoiceRow:_select(id: string, notify: boolean)
	local resolved = SettingsConfig.clamp(self._settingId, id)
	if resolved == self._value then
		return
	end

	self._value = resolved
	self:_paint()

	if notify and self._onChanged then
		self._onChanged(resolved)
	end
end

--[[
	Select without firing onChanged. Used when a profile arrives or the panel
	resets to defaults — neither is the player pressing the button.
]]
function ChoiceRow:setValue(value: string)
	self:_select(value, false)
end

function ChoiceRow:getValue(): string
	return self._value
end

function ChoiceRow:destroy()
	self._trove:Clean()
	self._buttons = {}
	self.instance = nil
end

return ChoiceRow
