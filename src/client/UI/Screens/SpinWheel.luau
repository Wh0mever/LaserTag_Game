--!nonstrict
--[[
	SpinWheel.luau
	The wheel widget for SpinScreen: the spokes, the pointer and the landing
	animation. Split out so SpinScreen keeps only the request/odds/pity logic.

	Helper module for SpinScreen: no init/start, so the Loader requires it and
	leaves it alone.

	The wheel is drawn as coloured spokes rather than true pie wedges — this
	project ships no image assets and there is no primitive that fills an arc. A
	spoke's width is proportional to its segment's share, but the odds table
	beside the wheel is what the player should read.

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

local MathUtil = require(Shared.Util.MathUtil)
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
local SPOKE_MIN_WIDTH = 0.06
local SPOKE_MAX_WIDTH = 0.34
-- Circumference (in wheel-scale units) at the spokes' mid radius; the share of
-- it a segment covers is how wide its spoke is drawn.
local SPOKE_ARC = 2 * math.pi * 0.23

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

local function buildSpokes(rotor: Frame, angles: { number })
	local total = SpinConfig.totalWeight()

	for index, segment in SpinConfig.Segments do
		local share = total > 0 and segment.weight / total or 0

		local spoke = Instance.new("Frame")
		spoke.Name = segment.id
		-- Rotation pivots on the AnchorPoint, so anchoring the bottom edge at the
		-- wheel centre makes the spoke sweep like a clock hand.
		spoke.AnchorPoint = Vector2.new(0.5, 1)
		spoke.Position = UDim2.fromScale(0.5, 0.5)
		spoke.Size = UDim2.new(MathUtil.clamp(SPOKE_ARC * share, SPOKE_MIN_WIDTH, SPOKE_MAX_WIDTH), 0, 0.46, 0)
		spoke.Rotation = angles[index]
		spoke.BackgroundColor3 = SpinWheel.segmentColor(segment)
		spoke.BackgroundTransparency = 0.15
		spoke.BorderSizePixel = 0
		spoke.ZIndex = 4
		spoke.Parent = rotor
		UITheme.corner(UITheme.Radius.Small).Parent = spoke

		local tag = UITheme.label(
			if segment.kind == "skin" then "SKIN" else tostring(segment.coins),
			UITheme.TextSizes.Tiny,
			UITheme.Colors.PanelDark,
			UITheme.Fonts.Bold
		)
		tag.Name = "Tag"
		tag.Position = UDim2.new(0, 0, 0, 6)
		tag.Size = UDim2.new(1, 0, 0, 14)
		tag.TextXAlignment = Enum.TextXAlignment.Center
		tag.ZIndex = 5
		tag.Parent = spoke
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
	buildSpokes(rotor, angles)

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
