--!nonstrict
--[[
	WorldEffects.luau
	The world-space half of the combat VFX: laser beams (with the muzzle flash
	that starts them), impacts, and floating damage numbers. All three are pooled
	through EffectPool.

	The beam and the muzzle flash share ONE pooled part. The flash belongs at the
	beam's origin attachment by definition, so splitting them would mean two
	pools, two acquisitions and two step callbacks for one visual event.

	Beams have no Material property, so the "neon" look is LightEmission = 1 over
	a skin-coloured ColorSequence. The fade is a width collapse rather than a
	Transparency ramp because Beam.Transparency is a NumberSequence: animating it
	would allocate a new sequence per beam per frame, which costs more than the
	beams do to draw.

	Helper module for VFXController: no init/start, so the Loader leaves it alone.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local EffectPool = require(script.Parent.EffectPool)
local UITheme = require(script.Parent.Parent.Parent.UI.UITheme)
local VFXSound = require(script.Parent.VFXSound)

local WorldEffects = {}

-- Pool sizes. Eighteen beams covers a 16-player firefight at rifle cadence with
-- room to spare; past that the oldest beams have already faded.
local BEAM_POOL, IMPACT_POOL, NUMBER_POOL = 18, 14, 10

local BEAM_LIFETIME = 0.1
local BEAM_TAPER = 0.45
local BEAM_TRANSPARENCY = NumberSequence.new(0.05, 0.4)

local MUZZLE_PARTICLES = 8
local MUZZLE_LIGHT_RANGE, MUZZLE_LIGHT_BRIGHTNESS = 9, 5
-- The flash must be over well before the beam is; a muzzle lit for the whole
-- beam reads as a flashlight rather than a discharge.
local MUZZLE_FRACTION = 0.45

local IMPACT_LIFETIME = 1.1
local IMPACT_PARTICLES = 12
local IMPACT_FLASH_FRACTION = 0.12
local IMPACT_LIGHT_RANGE, IMPACT_LIGHT_BRIGHTNESS = 7, 4
local SCORCH_TRANSPARENCY = 0.25

local NUMBER_RISE = 3.2
local NUMBER_SCATTER = 1.4
-- Hold the number fully opaque for this fraction of its life so it is readable
-- before it starts to go.
local NUMBER_HOLD = 0.45

local folder: Folder? = nil

--------------------------------------------------------------------------------
-- Shared part factory
--------------------------------------------------------------------------------

--[[
	An invisible, inert anchor part. Everything pooled here is a carrier for
	attachments, lights and GUIs rather than something the player sees directly,
	so nothing collides, queries, touches or casts a shadow.
]]
local function stubPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.new(0.05, 0.05, 0.05)
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Parent = folder
	return part
end

--------------------------------------------------------------------------------
-- Beam + muzzle flash
--------------------------------------------------------------------------------

local function makeBeam(index: number)
	local part = stubPart("Beam" .. index)

	local origin = Instance.new("Attachment")
	origin.Name = "Origin"
	origin.Parent = part

	local target = Instance.new("Attachment")
	target.Name = "Target"
	target.Parent = part

	local beam = Instance.new("Beam")
	beam.Attachment0 = origin
	beam.Attachment1 = target
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.LightInfluence = 0
	-- A laser is a straight line: one segment is the whole shape, and every
	-- extra one is a draw call for nothing.
	beam.Segments = 1
	beam.Transparency = BEAM_TRANSPARENCY
	beam.Enabled = false
	beam.Parent = part

	local flash = Instance.new("ParticleEmitter")
	flash.Rate = 0
	flash.Lifetime = NumberRange.new(0.05, 0.12)
	flash.Speed = NumberRange.new(6, 14)
	flash.SpreadAngle = Vector2.new(18, 18)
	flash.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 0),
	})
	flash.Transparency = NumberSequence.new(0.1)
	flash.LightEmission = 1
	flash.LightInfluence = 0
	flash.Drag = 6
	flash.Parent = origin

	local light = Instance.new("PointLight")
	light.Range = MUZZLE_LIGHT_RANGE
	light.Shadows = false
	light.Enabled = false
	light.Parent = part

	return {
		part = part,
		target = target,
		beam = beam,
		flash = flash,
		light = light,
		sound = VFXSound.positional(part, 8, 240),
		width = 0.25,
	}
end

local function stepBeam(item, alpha: number)
	local shrink = 1 - alpha
	item.beam.Width0 = item.width * shrink
	item.beam.Width1 = item.width * BEAM_TAPER * shrink

	if alpha < MUZZLE_FRACTION then
		item.light.Brightness = MUZZLE_LIGHT_BRIGHTNESS * (1 - alpha / MUZZLE_FRACTION)
	elseif item.light.Enabled then
		item.light.Enabled = false
	end
end

local function finishBeam(item)
	item.beam.Enabled = false
	item.light.Enabled = false
end

--[[
	One laser from `from` to `to`, with its muzzle flash at `from`.
	`soundKey` plays positionally at the muzzle; pass nil for the local player's
	own shot, whose report is played in 2D instead.
]]
function WorldEffects.beam(from: Vector3, to: Vector3, color: Color3, width: number, soundKey: string?)
	local distance = (to - from).Magnitude
	if distance < 0.1 then
		return
	end

	local item = EffectPool.acquire("beam")
	if not item then
		return
	end

	item.part.CFrame = CFrame.lookAt(from, to)
	item.target.Position = Vector3.new(0, 0, -distance)
	item.width = width

	item.beam.Color = ColorSequence.new(color)
	item.beam.Width0 = width
	item.beam.Width1 = width * BEAM_TAPER
	item.beam.Enabled = true

	item.flash.Color = ColorSequence.new(color)
	item.flash:Emit(MUZZLE_PARTICLES)

	item.light.Color = color
	item.light.Brightness = MUZZLE_LIGHT_BRIGHTNESS
	item.light.Enabled = true

	if soundKey then
		VFXSound.playAt(item.sound, soundKey)
	end

	EffectPool.play("beam", item, BEAM_LIFETIME, stepBeam, finishBeam)
end

--------------------------------------------------------------------------------
-- Impacts
--------------------------------------------------------------------------------

local function makeImpact(index: number)
	-- The part IS the scorch: a thin slab laid flat against the surface, so the
	-- mark needs no Decal and no texture asset.
	local part = Instance.new("Part")
	part.Name = "Impact" .. index
	part.Size = Vector3.new(0.75, 0.75, 0.06)
	part.Color = Color3.fromRGB(16, 16, 20)
	part.Material = Enum.Material.SmoothPlastic
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Parent = folder

	local burst = Instance.new("Attachment")
	burst.Name = "Burst"
	burst.Parent = part

	local sparks = Instance.new("ParticleEmitter")
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.15, 0.4)
	sparks.Speed = NumberRange.new(7, 16)
	sparks.SpreadAngle = Vector2.new(70, 70)
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	sparks.Transparency = NumberSequence.new(0.05)
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Acceleration = Vector3.new(0, -28, 0)
	sparks.Drag = 3
	sparks.Parent = burst

	local light = Instance.new("PointLight")
	light.Range = IMPACT_LIGHT_RANGE
	light.Shadows = false
	light.Enabled = false
	light.Parent = part

	return { part = part, sparks = sparks, light = light, sound = VFXSound.positional(part, 6, 140) }
end

local function stepImpact(item, alpha: number)
	item.part.Transparency = SCORCH_TRANSPARENCY + (1 - SCORCH_TRANSPARENCY) * alpha

	if alpha < IMPACT_FLASH_FRACTION then
		item.light.Brightness = IMPACT_LIGHT_BRIGHTNESS * (1 - alpha / IMPACT_FLASH_FRACTION)
	elseif item.light.Enabled then
		item.light.Enabled = false
	end
end

local function finishImpact(item)
	item.part.Transparency = 1
	item.light.Enabled = false
end

--[[
	Spark burst, flash and scorch at a hit position. `normal` only has to point
	away from the surface; a remote shot passes the direction back to the shooter,
	which is close enough for a mark that fades in about a second.
]]
function WorldEffects.impact(position: Vector3, normal: Vector3, color: Color3)
	local item = EffectPool.acquire("impact")
	if not item then
		return
	end

	local facing = if normal.Magnitude > 0.01 then normal.Unit else Vector3.yAxis
	-- Lift the slab a hair off the surface so it cannot z-fight the wall it is
	-- painted on.
	item.part.CFrame = CFrame.lookAt(position + facing * 0.03, position + facing)
	item.part.Transparency = SCORCH_TRANSPARENCY

	item.sparks.Color = ColorSequence.new(color)
	item.sparks:Emit(IMPACT_PARTICLES)

	item.light.Color = color
	item.light.Brightness = IMPACT_LIGHT_BRIGHTNESS
	item.light.Enabled = true

	VFXSound.playAt(item.sound, "Impact")
	EffectPool.play("impact", item, IMPACT_LIFETIME, stepImpact, finishImpact)
end

--------------------------------------------------------------------------------
-- Damage numbers
--------------------------------------------------------------------------------

local function makeDamageNumber(index: number)
	local part = stubPart("DamageNumber" .. index)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Number"
	billboard.Size = UDim2.fromOffset(160, 52)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 180
	billboard.Enabled = false
	billboard.Parent = part

	local label = UITheme.label("", UITheme.TextSizes.Heading, UITheme.Colors.Text, UITheme.Fonts.Heading)
	label.Size = UDim2.fromScale(1, 1)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextTruncate = Enum.TextTruncate.None
	label.TextStrokeColor3 = UITheme.Colors.Shadow
	label.Parent = billboard

	return { part = part, billboard = billboard, label = label, origin = Vector3.zero }
end

local function stepDamageNumber(item, alpha: number)
	item.part.Position = item.origin + Vector3.new(0, alpha * NUMBER_RISE, 0)

	local fade = math.max(0, (alpha - NUMBER_HOLD) / (1 - NUMBER_HOLD))
	item.label.TextTransparency = fade
	item.label.TextStrokeTransparency = 0.2 + 0.8 * fade
end

local function finishDamageNumber(item)
	item.billboard.Enabled = false
end

--[[
	Floating damage number. Headshots are drawn larger and in the coin gold so
	they read at a glance mid-firefight.
]]
function WorldEffects.damageNumber(position: Vector3, damage: number, isHeadshot: boolean)
	local item = EffectPool.acquire("number")
	if not item then
		return
	end

	-- Scatter, so two hits in the same second do not stack into one unreadable
	-- smear of overlapping text.
	item.origin = position
		+ Vector3.new(
			(math.random() - 0.5) * NUMBER_SCATTER,
			(math.random() - 0.5) * 0.6,
			(math.random() - 0.5) * NUMBER_SCATTER
		)
	item.part.Position = item.origin

	local rounded = math.floor(damage + 0.5)
	item.label.Text = if isHeadshot then `{rounded}!` else tostring(rounded)
	item.label.TextColor3 = if isHeadshot then UITheme.Colors.Coin else UITheme.Colors.Text
	item.label.TextSize = if isHeadshot then UITheme.TextSizes.Display else UITheme.TextSizes.Heading
	item.label.TextTransparency = 0
	item.label.TextStrokeTransparency = 0.2
	item.billboard.Enabled = true

	EffectPool.play("number", item, Constants.DAMAGE_NUMBER_DURATION, stepDamageNumber, finishDamageNumber)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

--[[
	Build the container and every pool. Returns the folder so the caller can put
	it in its own Trove. Client-created, so it never replicates; workspace is
	only a convenient world-space parent.
]]
function WorldEffects.setup(): Folder
	WorldEffects.teardown()

	local container = Instance.new("Folder")
	container.Name = "LaserTagVFX"
	container.Parent = workspace
	folder = container

	EffectPool.create("beam", BEAM_POOL, makeBeam)
	EffectPool.create("impact", IMPACT_POOL, makeImpact)
	EffectPool.create("number", NUMBER_POOL, makeDamageNumber)

	return container
end

function WorldEffects.teardown()
	if folder then
		folder:Destroy()
	end
	folder = nil
end

return WorldEffects
