--!nonstrict
--[[
	ScreenEffects.luau
	The screen-space half of the combat VFX: the hitmarker at the crosshair and
	the directional indicator that points at whoever just shot you.

	Both are built on FIRST USE rather than at boot. Controllers start before the
	UI pass, and a ScreenGui created that early would register its UIScale with
	UIController before UIController has computed the device scale — a phone
	would get desktop-sized feedback. By the first hit that ordering is long
	settled.

	The indicator is a marker pinned above the centre of a container frame; the
	CONTAINER is what rotates. Spinning a parent about the crosshair is one
	property write per frame, where recomputing the marker's own Position on a
	circle would be two plus a trig pair.

	Helper module for VFXController: no init/start, so the Loader leaves it alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local EffectPool = require(script.Parent.EffectPool)
local UIController = require(script.Parent.Parent.Parent.UI.UIController)
local UITheme = require(script.Parent.Parent.Parent.UI.UITheme)
local VFXSound = require(script.Parent.VFXSound)

local ScreenEffects = {}

-- Four attackers at once is already an ambush; a fifth arrow adds nothing.
local INDICATOR_POOL = 4
local INDICATOR_DURATION = 1.3
local INDICATOR_RADIUS = 118

local HITMARKER_SIZE = 42
local HITMARKER_GROWTH = 14

local root: Frame? = nil
local hitmarker: Frame? = nil
local hitmarkerBars: { Frame } = {}
local hitmarkerShownAt = 0
local hitmarkerLifetime = Constants.HITMARKER_DURATION

--------------------------------------------------------------------------------
-- Directional damage indicator
--------------------------------------------------------------------------------

local function makeIndicator(index: number)
	local container = Instance.new("Frame")
	container.Name = "DamageIndicator" .. index
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(INDICATOR_RADIUS * 2 + 80, INDICATOR_RADIUS * 2 + 80)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = root

	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.AnchorPoint = Vector2.new(0.5, 0.5)
	marker.Position = UDim2.new(0.5, 0, 0.5, -INDICATOR_RADIUS)
	marker.Size = UDim2.fromOffset(70, 7)
	marker.BackgroundColor3 = UITheme.Colors.Negative
	marker.BorderSizePixel = 0
	marker.Parent = container
	UITheme.corner(4).Parent = marker

	return { container = container, marker = marker, from = Vector3.zero }
end

local function stepIndicator(item, alpha: number)
	local camera = workspace.CurrentCamera
	if camera then
		local cameraCF = camera.CFrame
		local toAttacker = item.from - cameraCF.Position
		-- Flattened to the XZ plane: an attacker above or below is still "that
		-- way", and pitch would make the arrow swing when the player looks down.
		local flat = Vector3.new(toAttacker.X, 0, toAttacker.Z)
		if flat.Magnitude > 0.05 then
			local direction = flat.Unit
			local look, right = cameraCF.LookVector, cameraCF.RightVector
			local forwardDot = direction.X * look.X + direction.Z * look.Z
			local rightDot = direction.X * right.X + direction.Z * right.Z
			-- GuiObject.Rotation is clockwise-positive, which is exactly what an
			-- attacker on the right producing a positive angle here needs.
			item.container.Rotation = math.deg(math.atan2(rightDot, forwardDot))
		end
	end

	item.marker.BackgroundTransparency = alpha * alpha
end

local function finishIndicator(item)
	item.container.Visible = false
end

--------------------------------------------------------------------------------
-- Hitmarker
--------------------------------------------------------------------------------

local function buildHitmarker(parent: Frame): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Hitmarker"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(HITMARKER_SIZE, HITMARKER_SIZE)
	frame.BackgroundTransparency = 1
	frame.Visible = false
	frame.Parent = parent

	table.clear(hitmarkerBars)
	for index = 1, 4 do
		local angle = 45 + (index - 1) * 90
		local radians = math.rad(angle)

		local bar = Instance.new("Frame")
		bar.Name = "Bar" .. index
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Size = UDim2.fromOffset(14, 3)
		bar.Rotation = angle
		bar.Position = UDim2.new(0.5, math.cos(radians) * 13, 0.5, math.sin(radians) * 13)
		bar.BackgroundColor3 = UITheme.Colors.Text
		bar.BorderSizePixel = 0
		bar.Parent = frame

		table.insert(hitmarkerBars, bar)
	end

	return frame
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function ensureScreen(): boolean
	if root and root.Parent then
		return true
	end

	local gui = UIController.getScreenGui("CombatFeedback", Constants.DISPLAY_ORDER.HUD + 1)
	if not gui then
		return false
	end

	local frame = Instance.new("Frame")
	frame.Name = "Root"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundTransparency = 1
	frame.Parent = gui
	root = frame

	hitmarker = buildHitmarker(frame)
	EffectPool.create("indicator", INDICATOR_POOL, makeIndicator)

	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Centre-screen confirmation that a shot connected. A kill is drawn red and
	held twice as long as a body hit, which is the difference the player reads
	without looking away from their crosshair.
]]
function ScreenEffects.hitmarker(killed: boolean, isHeadshot: boolean)
	if not ensureScreen() or not hitmarker then
		return
	end

	local color = if killed
		then UITheme.Colors.Negative
		elseif isHeadshot then UITheme.Colors.Coin
		else UITheme.Colors.Text

	for _, bar in hitmarkerBars do
		bar.BackgroundColor3 = color
		bar.BackgroundTransparency = 0
	end

	hitmarkerLifetime = if killed then Constants.HITMARKER_DURATION * 2 else Constants.HITMARKER_DURATION
	hitmarkerShownAt = os.clock()
	hitmarker.Size = UDim2.fromOffset(HITMARKER_SIZE, HITMARKER_SIZE)
	hitmarker.Visible = true

	VFXSound.playLocal(if killed then "Kill" else "Hitmarker")
end

--[[
	Arc around the crosshair pointing at `fromPosition`. Re-aimed every frame
	while it fades, so turning toward the attacker sweeps it in to the centre.
]]
function ScreenEffects.damageIndicator(fromPosition: Vector3)
	if not ensureScreen() then
		return
	end

	local item = EffectPool.acquire("indicator")
	if not item then
		return
	end

	item.from = fromPosition
	item.marker.BackgroundTransparency = 0
	item.container.Visible = true
	EffectPool.play("indicator", item, INDICATOR_DURATION, stepIndicator, finishIndicator)
end

--[[
	Fade the hitmarker. Driven from VFXController's Heartbeat alongside
	EffectPool.step; the hitmarker is a singleton, so it is not worth a pool.
]]
function ScreenEffects.step(now: number)
	if hitmarkerShownAt <= 0 or not hitmarker then
		return
	end

	local alpha = (now - hitmarkerShownAt) / hitmarkerLifetime
	if alpha >= 1 then
		hitmarkerShownAt = 0
		hitmarker.Visible = false
		return
	end

	-- Punching outward as it fades is what sells the hit; a static cross reads
	-- as a UI element rather than as feedback.
	local size = HITMARKER_SIZE + alpha * HITMARKER_GROWTH
	hitmarker.Size = UDim2.fromOffset(size, size)
	for _, bar in hitmarkerBars do
		bar.BackgroundTransparency = alpha * alpha
	end
end

function ScreenEffects.teardown()
	table.clear(hitmarkerBars)
	hitmarkerShownAt = 0
	if root then
		root:Destroy()
	end
	root = nil
	hitmarker = nil
end

return ScreenEffects
