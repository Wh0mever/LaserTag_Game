--!nonstrict
--[[
	SpinWheel.luau
	The wheel widget for SpinScreen: the wedges, the pointer and the landing
	animation. Split out so SpinScreen keeps only the request/odds/pity logic.

	Helper module for SpinScreen: no init/start, so the Loader requires it and
	leaves it alone.

	A wedge is approximated by a run of thin radial bars, because this project
	ships no image assets and Roblox has no primitive that fills an arc. Each
	segment therefore covers its true share of the circle. The odds table beside
	the wheel is still the authoritative reading of the chances — the wheel is
	the part that has to look like one.

	:landOn(index) replays a result. It never chooses one: the index comes from
	the server's SpinResult, and this module has no random source at all.

	Usage:
		local wheel = SpinWheel.create(parentFrame)
		wheel:landOn(result.segmentIndex, function() ... end)
		wheel:destroy()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local SkinCatalog = require(Shared.Config.SkinCatalog)
local SpinConfig = require(Shared.Config.SpinConfig)
local Trove = require(Shared.Util.Trove)
local UITheme = require(script.Parent.Parent.UITheme)

local SpinWheel = {}
SpinWheel.__index = SpinWheel

local SPIN_SECONDS = 3.2
-- Whole turns before the wedge is presented, so the result never looks like it
-- was nudged into place.
local SPIN_TURNS = 4

-- Rim radius, as a fraction of the (square) wheel's height.
local WHEEL_RADIUS = 0.46
-- Degrees per bar. Smaller is smoother and costs one Frame each; 3 puts the
-- whole wheel at ~120 Frames, which is a menu that opens rarely rather than
-- anything a match renders.
local SLICE_STEP = 3
-- A bar is a rectangle, so at the rim it spans a chord rather than an arc.
-- Widening past that chord makes neighbours overlap, which is what turns a row
-- of bars into a solid wedge instead of a comb.
local SLICE_WIDTH = 2 * WHEEL_RADIUS * math.sin(math.rad(SLICE_STEP) * 0.5) * 1.35
-- Boundary lines. Four coin segments in a row are all Coin gold, so without
-- these the wheel shows one 80-degree gold arc and the player cannot see that
-- it is four different prizes.
local DIVIDER_WIDTH = 0.007
local LABEL_HEIGHT = 14
-- Text sits out near the rim, clear of the hub disc.
local LABEL_INSET = 0.1

--------------------------------------------------------------------------------
-- Segment maths
--------------------------------------------------------------------------------

--[[
	Coin segments are gold; a skin segment takes its rarity colour, so the wheel
	and the shop grade the same skin identically.
]]
function SpinWheel.segmentColor(segment): Color3
	if segment.kind == "skin" then
		return UITheme.fromRGB(SkinCatalog.rarityColor(segment.skinId))
	end
	return UITheme.Colors.Coin
end

--[[
	A segment's real chance, derived from the same weights the server rolls
	against. Published verbatim by SpinScreen's odds table.
]]
function SpinWheel.percentOf(segment): number
	local total = SpinConfig.totalWeight()
	return total > 0 and segment.weight / total * 100 or 0
end

--[[
	Mid-angle of every segment, clockwise from the top.
]]
local function computeAngles(): { number }
	local total = SpinConfig.totalWeight()
	local accumulated = 0
	local angles = {}

	for index, segment in SpinConfig.Segments do
		local sweep = total > 0 and segment.weight / total * 360 or 0
		angles[index] = accumulated + sweep * 0.5
		accumulated += sweep
	end

	return angles
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

--[[
	One radial bar from the wheel's centre out to `height`, rotated to `angle`.
	Rotation pivots on the AnchorPoint, so anchoring the bottom edge at the
	centre makes the bar sweep like a clock hand.
]]
local function radial(parent: Frame, name: string, angle: number, width: number, height: number, zIndex: number): Frame
	local bar = Instance.new("Frame")
	bar.Name = name
	bar.AnchorPoint = Vector2.new(0.5, 1)
	bar.Position = UDim2.fromScale(0.5, 0.5)
	bar.Size = UDim2.fromScale(width, height)
	bar.Rotation = angle
	bar.BorderSizePixel = 0
	bar.ZIndex = zIndex
	bar.Parent = parent
	return bar
end

--[[
	Dark text on a bright wedge, light text on a dark one. Rarity colours span
	both — a Legendary gold and an Epic purple cannot share one text colour and
	stay readable on either.
]]
local function readableOn(color: Color3): Color3
	local luminance = 0.2126 * color.R + 0.7152 * color.G + 0.0722 * color.B
	return if luminance > 0.55 then UITheme.Colors.PanelDark else UITheme.Colors.Text
end

--[[
	Draws every segment as a run of thin bars covering its whole sweep, a
	boundary line at its leading edge, and a label at its mid-angle.

	Roblox ships no primitive that fills an arc and this project ships no image
	assets, so a wedge has to be approximated. Bars are that approximation: they
	cost one Frame per SLICE_STEP degrees and read as a solid sector, where the
	single wide rectangle this replaced read as a playing card.
]]
local function buildSlices(rotor: Frame)
	local total = SpinConfig.totalWeight()
	local accumulated = 0

	for _, segment in SpinConfig.Segments do
		local sweep = total > 0 and segment.weight / total * 360 or 0
		local color = SpinWheel.segmentColor(segment)

		local wedge = Instance.new("Frame")
		wedge.Name = segment.id
		wedge.Size = UDim2.fromScale(1, 1)
		wedge.BackgroundTransparency = 1
		wedge.ZIndex = 4
		wedge.Parent = rotor

		-- At least one bar even for a sliver: the rarest segment is the one a
		-- player most wants to find on the wheel, so it must never vanish.
		local bars = math.max(1, math.ceil(sweep / SLICE_STEP))
		for step = 0, bars - 1 do
			local bar =
				radial(wedge, "Slice", accumulated + (step + 0.5) * (sweep / bars), SLICE_WIDTH, WHEEL_RADIUS, 4)
			bar.BackgroundColor3 = color
		end

		local divider = radial(wedge, "Divider", accumulated, DIVIDER_WIDTH, WHEEL_RADIUS, 5)
		divider.BackgroundColor3 = UITheme.Colors.PanelDark

		-- The label rides its own radial frame, so it points outward from the
		-- centre and turns with the wheel exactly like a real prize wheel's does.
		local holder = radial(wedge, "Tag", accumulated + sweep * 0.5, 0.28, WHEEL_RADIUS, 6)
		holder.BackgroundTransparency = 1

		local tag = UITheme.label(
			if segment.kind == "skin" then "СКИН" else tostring(segment.coins),
			UITheme.TextSizes.Tiny,
			readableOn(color),
			UITheme.Fonts.Bold
		)
		tag.Name = "Text"
		tag.AnchorPoint = Vector2.new(0.5, 0)
		tag.Position = UDim2.fromScale(0.5, LABEL_INSET)
		tag.Size = UDim2.new(1, 0, 0, LABEL_HEIGHT)
		tag.TextXAlignment = Enum.TextXAlignment.Center
		tag.ZIndex = 6
		tag.Parent = holder

		accumulated += sweep
	end
end

--[[
	Builds the wheel inside `parent`, filling it while staying square.
]]
function SpinWheel.create(parent: Instance)
	assert(typeof(parent) == "Instance", "SpinWheel.create requires a parent Instance")

	local trove = Trove.new()
	local angles = computeAngles()

	local wheel = Instance.new("Frame")
	wheel.Name = "Wheel"
	wheel.AnchorPoint = Vector2.new(0.5, 0.5)
	wheel.Position = UDim2.fromScale(0.5, 0.5)
	wheel.Size = UDim2.fromScale(1, 1)
	wheel.BackgroundColor3 = UITheme.Colors.PanelDark
	wheel.BorderSizePixel = 0
	wheel.ZIndex = 3
	UITheme.corner(UITheme.Radius.Pill).Parent = wheel
	UITheme.stroke(UITheme.Colors.Accent, 3).Parent = wheel

	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.DominantAxis = Enum.DominantAxis.Height
	aspect.Parent = wheel

	local rotor = Instance.new("Frame")
	rotor.Name = "Rotor"
	rotor.Size = UDim2.fromScale(1, 1)
	rotor.BackgroundTransparency = 1
	rotor.ZIndex = 3
	rotor.Parent = wheel
	buildSlices(rotor)

	local hub = Instance.new("Frame")
	hub.Name = "Hub"
	hub.AnchorPoint = Vector2.new(0.5, 0.5)
	hub.Position = UDim2.fromScale(0.5, 0.5)
	hub.Size = UDim2.fromScale(0.18, 0.18)
	hub.BackgroundColor3 = UITheme.Colors.Panel
	hub.BorderSizePixel = 0
	hub.ZIndex = 6
	hub.Parent = wheel
	UITheme.corner(UITheme.Radius.Pill).Parent = hub
	UITheme.stroke(UITheme.Colors.Accent, 2).Parent = hub

	-- A square turned 45 degrees is the only way to get a triangle without an
	-- image asset; only its lower half reads against the rim.
	local pointer = Instance.new("Frame")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Position = UDim2.fromScale(0.5, 0.02)
	pointer.Size = UDim2.fromOffset(16, 16)
	pointer.Rotation = 45
	pointer.BackgroundColor3 = UITheme.Colors.Accent
	pointer.BorderSizePixel = 0
	pointer.ZIndex = 7
	pointer.Parent = wheel

	trove:Add(wheel)
	wheel.Parent = parent

	return setmetatable({
		instance = wheel,
		rotor = rotor,
		angles = angles,
		_trove = trove,
		_tween = nil,
	}, SpinWheel)
end

--------------------------------------------------------------------------------
-- Animation
--------------------------------------------------------------------------------

--[[
	Spins to `index` and calls `onComplete` when it stops. `index` is the
	server's segmentIndex — an out-of-range value lands on the first segment
	rather than picking one, because guessing here would be inventing a result.
]]
function SpinWheel:landOn(index: number, onComplete: (() -> ())?)
	local mid = self.angles[index] or self.angles[1] or 0

	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end

	-- Normalised first so repeated spins do not walk Rotation off to thousands.
	self.rotor.Rotation = self.rotor.Rotation % 360
	local base = self.rotor.Rotation + 360 * SPIN_TURNS
	-- The pointer sits at the top (world angle 0), so the rotor has to finish at
	-- minus the segment's own angle for that wedge to be under it.
	local target = base + (-mid - base) % 360

	local tween = TweenService:Create(
		self.rotor,
		TweenInfo.new(SPIN_SECONDS, Enum.EasingStyle.Quint, Enum.EasingDirection.Out),
		{ Rotation = target }
	)
	self._tween = tween

	tween.Completed:Once(function(state: Enum.PlaybackState)
		if self._tween == tween then
			self._tween = nil
		end
		-- A cancelled spin was superseded or torn down; only a finished one has a
		-- reward to announce.
		if state == Enum.PlaybackState.Completed and onComplete then
			onComplete()
		end
	end)
	tween:Play()
end

function SpinWheel:destroy()
	if self._tween then
		self._tween:Cancel()
		self._tween = nil
	end
	self._trove:Clean()
end

return SpinWheel
