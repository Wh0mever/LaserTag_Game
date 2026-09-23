--!nonstrict
--[[
	HUDWidgets.luau
	Builds the in-match HUD furniture — timer, team score chips, health bar, ammo
	counter, crosshair and hotbar — and hands the labels back to HUDScreen, which
	owns all the updating.

	Split from HUDScreen so that file reads as "what the HUD does when state
	changes" rather than three hundred lines of Instance.new. Nothing in here
	subscribes to anything.

	Helper module for HUDScreen: no init/start, so the Loader requires it and
	leaves it alone.

	Returns a `widgets` table:
		.root            Frame        -- toggle this to show/hide the whole HUD
		.timer           TextLabel
		.scores          {[teamId]: TextLabel}
		.scoreChips      {[teamId]: Frame}  -- the chip itself, to mark the player's own side
		.scoreTarget     TextLabel    -- "FIRST TO 144"; hidden when there is no target
		.healthFill      Frame        -- width is the health fraction
		.healthLabel     TextLabel
		.ammoWeapon      TextLabel
		.ammoMag         TextLabel
		.ammoSize        TextLabel
		.crosshair       Frame
		.crosshairBars   {{bar: Frame, dx: number, dy: number}}
		.slots           {[slot]: Button}
		:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local Constants = require(Shared.Constants)
local TextUtil = require(Shared.Util.TextUtil)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local HUDWidgets = {}

local CHIP_HEIGHT = 32
local SCORE_CHIP_WIDTH = 128
local CROSSHAIR_THICKNESS = 2
local CROSSHAIR_LENGTH = 7
local HOTBAR_SLOT_WIDTH = 128
local HOTBAR_HEIGHT = 44

--[[
	THE PHONE LAYOUT. On a touchscreen the bottom corners belong to Roblox: the
	thumbstick sits bottom-left and the jump button bottom-right, with our fire
	cluster arced around it. The desktop HUD put the health bar in the first
	corner and the ammo counter in the second, so on a phone the player's own
	thumbs covered both — "17/30" was drawn exactly under the jump button.

	So on touch, health, ammo and the weapon slots are one compact block in the
	bottom centre, the one stretch of the bottom edge no thumb rests on: slots
	along the bottom, health and ammo on a row above them. Sizes are chosen for
	the ~780x358 canvas a phone gets after UIScale.
]]
local TOUCH_SLOT_WIDTH = 78
local TOUCH_SLOT_HEIGHT = 32
local TOUCH_SLOT_GAP = 6
local TOUCH_STATUS_HEIGHT = 24
local TOUCH_BOTTOM = 8
local TOUCH_BLOCK_WIDTH = TOUCH_SLOT_WIDTH * 3 + TOUCH_SLOT_GAP * 2

--------------------------------------------------------------------------------
-- Small helpers
--------------------------------------------------------------------------------

local function chip(name: string, size: UDim2, position: UDim2, anchor: Vector2, parent: Instance): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.Size = size
	frame.Position = position
	frame.AnchorPoint = anchor
	frame.BackgroundColor3 = UITheme.Colors.PanelDark
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 0
	frame.Parent = parent
	UITheme.corner(UITheme.Radius.Medium).Parent = frame
	return frame
end

local function centered(label: TextLabel): TextLabel
	label.TextXAlignment = Enum.TextXAlignment.Center
	return label
end

--------------------------------------------------------------------------------
-- Pieces
--------------------------------------------------------------------------------

local function buildTimer(parent: Instance): TextLabel
	local holder = chip("Timer", UDim2.fromOffset(128, 44), UDim2.new(0.5, 0, 0, 10), Vector2.new(0.5, 0), parent)
	UITheme.stroke(UITheme.Colors.Stroke, 1).Parent = holder

	local label = centered(UITheme.label("10:00", UITheme.TextSizes.Title, UITheme.Colors.Text, UITheme.Fonts.Number))
	label.Name = "Value"
	label.Size = UDim2.fromScale(1, 1)
	label.Parent = holder
	return label
end

--[[
	The kill target, under the score chips.

	A deathmatch needs a number to race to or the score chips are just a tally.
	The target scales with team size and rises as the lobby fills, so it is drawn
	from the match payload rather than baked in, and hidden entirely until a
	match is running.
]]
local function buildScoreTarget(parent: Instance): TextLabel
	local label = centered(UITheme.label("", UITheme.TextSizes.Tiny, UITheme.Colors.TextDim, UITheme.Fonts.Bold))
	label.Name = "ScoreTarget"
	label.Size = UDim2.fromOffset(220, 16)
	label.Position = UDim2.new(0.5, 0, 0, 60 + CHIP_HEIGHT + 4)
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Visible = false
	label.Parent = parent
	return label
end

--[[
	One team's score chip. `alignRight` puts it on the left of the centre line
	(its right edge against the gap), which is where team A sits.
]]
--[[
	A team's name and score. Half and half: the score had 38% of a 112 px chip,
	about 35 px, and a three-digit score needs 36 — full lobbies play to 144, so
	the number that decides the match read "1…".
]]
local function buildScoreChip(teamId: string, alignRight: boolean, parent: Instance): (TextLabel, Frame)
	local team = Constants.TEAMS[teamId]
	local color = UITheme.teamColor(teamId)
	local position = if alignRight then UDim2.new(0.5, -5, 0, 60) else UDim2.new(0.5, 5, 0, 60)

	local holder = chip(
		`Score{teamId}`,
		UDim2.fromOffset(SCORE_CHIP_WIDTH, CHIP_HEIGHT),
		position,
		Vector2.new(alignRight and 1 or 0, 0),
		parent
	)
	holder.BackgroundColor3 = color
	holder.BackgroundTransparency = 0.78
	UITheme.stroke(color, 1.5).Parent = holder
	UITheme.padding(10, 0).Parent = holder

	local name = UITheme.label(TextUtil.upper(team.name), UITheme.TextSizes.Small, color, UITheme.Fonts.Bold)
	name.Name = "Team"
	name.Size = UDim2.new(0.5, 0, 1, 0)
	name.Parent = holder

	local score = UITheme.label("0", UITheme.TextSizes.Heading, UITheme.Colors.Text, UITheme.Fonts.Number)
	score.Name = "Value"
	score.AnchorPoint = Vector2.new(1, 0)
	score.Position = UDim2.fromScale(1, 0)
	score.Size = UDim2.new(0.5, 0, 1, 0)
	score.TextXAlignment = Enum.TextXAlignment.Right
	score.Parent = holder
	return score, holder
end

local function buildHealth(parent: Instance, touch: boolean): (Frame, TextLabel)
	local holder = if touch
		then chip(
			"Health",
			UDim2.fromOffset(math.floor(TOUCH_BLOCK_WIDTH * 0.6), TOUCH_STATUS_HEIGHT - 4),
			UDim2.new(0.5, -TOUCH_BLOCK_WIDTH / 2, 1, -(TOUCH_BOTTOM + TOUCH_SLOT_HEIGHT + TOUCH_SLOT_GAP + 2)),
			Vector2.new(0, 1),
			parent
		)
		else chip("Health", UDim2.new(0.2, 0, 0, 26), UDim2.new(0, 22, 1, -22), Vector2.new(0, 1), parent)
	holder.BackgroundTransparency = 0.15
	holder.ClipsDescendants = true
	UITheme.stroke(UITheme.Colors.Stroke, 1).Parent = holder

	-- Scale width with a pixel clamp: readable on a phone, not a metre wide on an
	-- ultrawide monitor.
	if not touch then
		local constraint = Instance.new("UISizeConstraint")
		constraint.MinSize = Vector2.new(150, 22)
		constraint.MaxSize = Vector2.new(340, 30)
		constraint.Parent = holder
	end

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UITheme.Colors.Positive
	fill.BorderSizePixel = 0
	fill.Parent = holder
	UITheme.corner(UITheme.Radius.Medium).Parent = fill
	UITheme.gradient(Color3.new(1, 1, 1), Color3.fromRGB(200, 200, 200), 90).Parent = fill

	local label = centered(UITheme.label("100", UITheme.TextSizes.Small, UITheme.Colors.Text, UITheme.Fonts.Bold))
	label.Name = "Value"
	label.Size = UDim2.fromScale(1, 1)
	label.TextStrokeTransparency = 0.4
	label.ZIndex = 2
	label.Parent = holder

	return fill, label
end

local function buildTouchAmmo(parent: Instance): (TextLabel, TextLabel, TextLabel)
	local holder = Instance.new("Frame")
	holder.Name = "Ammo"
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(0.5, TOUCH_BLOCK_WIDTH / 2, 1, -(TOUCH_BOTTOM + TOUCH_SLOT_HEIGHT + TOUCH_SLOT_GAP))
	holder.Size = UDim2.fromOffset(math.floor(TOUCH_BLOCK_WIDTH * 0.38), TOUCH_STATUS_HEIGHT + 4)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	-- The lit slot underneath already says which weapon this is; a name here
	-- would only be a second, smaller copy of it. Kept (hidden) so the widget
	-- table has the same shape on every device.
	local weapon = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	weapon.Name = "Weapon"
	weapon.Visible = false
	weapon.Parent = holder

	local mag = UITheme.label("0", UITheme.TextSizes.Title, UITheme.Colors.Text, UITheme.Fonts.Number)
	mag.Name = "Mag"
	mag.AnchorPoint = Vector2.new(1, 1)
	mag.Position = UDim2.new(1, -38, 1, 0)
	mag.Size = UDim2.new(1, -38, 1, 0)
	mag.TextXAlignment = Enum.TextXAlignment.Right
	mag.TextStrokeTransparency = 0.5
	mag.Parent = holder

	local size = UITheme.label("/0", UITheme.TextSizes.Body, UITheme.Colors.TextDim, UITheme.Fonts.Number)
	size.Name = "MagSize"
	size.AnchorPoint = Vector2.new(1, 1)
	size.Position = UDim2.new(1, 0, 1, -2)
	size.Size = UDim2.fromOffset(36, 20)
	size.TextXAlignment = Enum.TextXAlignment.Right
	size.TextStrokeTransparency = 0.5
	size.Parent = holder

	return weapon, mag, size
end

local function buildAmmo(parent: Instance): (TextLabel, TextLabel, TextLabel)
	local holder = Instance.new("Frame")
	holder.Name = "Ammo"
	holder.AnchorPoint = Vector2.new(1, 1)
	holder.Position = UDim2.new(1, -24, 1, -20)
	-- Wide enough for the longest full weapon name at this size; at 180 the
	-- rifle's was cut to "ИМПУЛЬСНАЯ ВИНТОВ…".
	holder.Size = UDim2.fromOffset(230, 62)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local weapon = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	weapon.Name = "Weapon"
	weapon.Size = UDim2.new(1, 0, 0, 16)
	weapon.TextXAlignment = Enum.TextXAlignment.Right
	weapon.Parent = holder

	local mag = UITheme.label("0", UITheme.TextSizes.Display, UITheme.Colors.Text, UITheme.Fonts.Number)
	mag.Name = "Mag"
	mag.AnchorPoint = Vector2.new(1, 1)
	mag.Position = UDim2.new(1, -46, 1, 0)
	mag.Size = UDim2.new(1, -46, 0, 40)
	mag.TextXAlignment = Enum.TextXAlignment.Right
	mag.Parent = holder

	local size = UITheme.label("/0", UITheme.TextSizes.Heading, UITheme.Colors.TextDim, UITheme.Fonts.Number)
	size.Name = "MagSize"
	size.AnchorPoint = Vector2.new(1, 1)
	size.Position = UDim2.new(1, 0, 1, -4)
	size.Size = UDim2.fromOffset(46, 26)
	size.TextXAlignment = Enum.TextXAlignment.Right
	size.Parent = holder

	return weapon, mag, size
end

local function buildCrosshair(parent: Instance): (Frame, { { bar: Frame, dx: number, dy: number } })
	local holder = Instance.new("Frame")
	holder.Name = "Crosshair"
	holder.Size = UDim2.fromScale(1, 1)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(CROSSHAIR_THICKNESS, CROSSHAIR_THICKNESS)
	dot.BackgroundColor3 = UITheme.Colors.Text
	dot.BorderSizePixel = 0
	dot.Parent = holder

	-- dx/dy are the unit direction each bar is pushed in as the bloom grows.
	local directions = {
		{ name = "Up", anchor = Vector2.new(0.5, 1), dx = 0, dy = -1, vertical = true },
		{ name = "Down", anchor = Vector2.new(0.5, 0), dx = 0, dy = 1, vertical = true },
		{ name = "Left", anchor = Vector2.new(1, 0.5), dx = -1, dy = 0, vertical = false },
		{ name = "Right", anchor = Vector2.new(0, 0.5), dx = 1, dy = 0, vertical = false },
	}

	local bars = {}
	for _, direction in directions do
		local bar = Instance.new("Frame")
		bar.Name = direction.name
		bar.AnchorPoint = direction.anchor
		bar.Position = UDim2.fromScale(0.5, 0.5)
		bar.Size = if direction.vertical
			then UDim2.fromOffset(CROSSHAIR_THICKNESS, CROSSHAIR_LENGTH)
			else UDim2.fromOffset(CROSSHAIR_LENGTH, CROSSHAIR_THICKNESS)
		bar.BackgroundColor3 = UITheme.Colors.Text
		bar.BorderSizePixel = 0
		bar.Parent = holder
		table.insert(bars, { bar = bar, dx = direction.dx, dy = direction.dy })
	end

	return holder, bars
end

--[[
	One slot per weapon, labelled with the SHORT name. The full names are 12-19
	letters of bold capitals and each ran across the neighbouring slots, so the
	bar read "ИМПУЛЬСНАЯ ВИ[1]ОННЫЙ ПИСТОЛЕТ". On touch the slots shrink and lose
	their key badges — there are no number keys to press on a phone.
]]
local function buildHotbar(parent: Instance, onSlot: (slot: number) -> (), trove, touch: boolean): { [number]: any }
	local slotWidth = if touch then TOUCH_SLOT_WIDTH else HOTBAR_SLOT_WIDTH
	local slotHeight = if touch then TOUCH_SLOT_HEIGHT else HOTBAR_HEIGHT
	local gap = if touch then TOUCH_SLOT_GAP else 8

	local holder = Instance.new("Frame")
	holder.Name = "Hotbar"
	holder.AnchorPoint = Vector2.new(0.5, 1)
	holder.Position = UDim2.new(0.5, 0, 1, if touch then -TOUCH_BOTTOM else -18)
	holder.Size = UDim2.fromOffset(slotWidth * #Constants.SLOTS + gap * (#Constants.SLOTS - 1), slotHeight)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, gap)
	layout.Parent = holder

	local slots = {}
	for slot, weaponId in Constants.SLOTS do
		local weapon = WeaponConfig.get(weaponId)
		local button = Button.create({
			name = `Slot{slot}`,
			text = weapon and (weapon.shortName or weapon.displayName) or weaponId,
			keyHint = if touch then nil else tostring(slot),
			size = UDim2.fromOffset(slotWidth, slotHeight),
			layoutOrder = slot,
			parent = holder,
			onActivated = function()
				onSlot(slot)
			end,
		})
		button.label.TextSize = if touch then UITheme.TextSizes.Tiny else UITheme.TextSizes.Small
		-- Components expose :destroy(), which Trove does not recognise on its own.
		trove:Add(function()
			button:destroy()
		end)
		slots[slot] = button
	end

	return slots
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

--[[
	Builds the whole HUD under `parent` (a ScreenGui) and returns the widget
	table. `onSlot(slot)` fires when a hotbar slot is clicked or tapped.
	`options.touch` builds the phone layout: see TOUCH_* above.
]]
function HUDWidgets.build(parent: Instance, onSlot: (slot: number) -> (), options: { touch: boolean? }?)
	assert(typeof(parent) == "Instance", "HUDWidgets.build requires a parent Instance")
	local touch = options ~= nil and options.touch == true

	local trove = Trove.new()

	local root = Instance.new("Frame")
	root.Name = "Match"
	root.Size = UDim2.fromScale(1, 1)
	root.BackgroundTransparency = 1
	-- Hidden until the player is actually in a match; the hub shows none of this.
	root.Visible = false
	root.Parent = parent
	trove:Add(root)

	local scoreA, chipA = buildScoreChip("A", true, root)
	local scoreB, chipB = buildScoreChip("B", false, root)
	local healthFill, healthLabel = buildHealth(root, touch)
	local ammoWeapon, ammoMag, ammoSize
	if touch then
		ammoWeapon, ammoMag, ammoSize = buildTouchAmmo(root)
	else
		ammoWeapon, ammoMag, ammoSize = buildAmmo(root)
	end
	local crosshair, crosshairBars = buildCrosshair(root)

	local widgets = {
		root = root,
		timer = buildTimer(root),
		scores = { A = scoreA, B = scoreB },
		scoreChips = { A = chipA, B = chipB },
		scoreTarget = buildScoreTarget(root),
		healthFill = healthFill,
		healthLabel = healthLabel,
		ammoWeapon = ammoWeapon,
		ammoMag = ammoMag,
		ammoSize = ammoSize,
		crosshair = crosshair,
		crosshairBars = crosshairBars,
		slots = buildHotbar(root, onSlot, trove, touch),
	}

	function widgets.destroy()
		trove:Clean()
	end

	return widgets
end

return HUDWidgets
