--!nonstrict
--[[
	LightingSetup.luau
	Global lighting and post-processing, applied once at boot.

	The maps are flat-shaded SmoothPlastic blocks with Neon strips, and the whole
	rig exists to make the Neon the only thing that glows.

	That is a property of the scene, not of one dial. Neon is emissive and
	ignores Lighting.Brightness; every diffuse surface scales with it. So the sun
	and the ambient terms are set low enough that an ordinary wall stays well
	under the bloom threshold, and the map palettes keep their bright end for
	trim rather than floors. Get either wrong and the frame is white: the first
	version of this file paired a default 0.95 threshold with Brightness 2.2 and
	near-white plazas, and the hub rendered as one flat sheet.

	tests/harness/lighting.luau applies this rig for real and measures the maps
	against it, so the relationship is checked rather than described.

	Effects are looked up by name and reused, so calling apply() twice does not
	stack duplicate BloomEffects.
]]

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

-- 0.95 is the engine default. Sitting a little above it leaves headroom for the
-- brightest trim without costing the neon its halo — but the threshold is the
-- smaller half of the job. What keeps ordinary surfaces out of the bloom pass
-- is that they are not near-white and the sun is not overdriven, both of which
-- tests/harness/lighting.luau measures directly.
local BLOOM_THRESHOLD = 1.15

local applied = false

local function ensure(className: string, name: string): Instance
	local existing = Lighting:FindFirstChild(name)
	if existing and existing.ClassName == className then
		return existing
	end
	if existing then
		existing:Destroy()
	end

	local instance = Instance.new(className)
	instance.Name = name
	instance.Parent = Lighting
	return instance
end

--[[
	Applies the global lighting rig. Idempotent.
]]
function LightingSetup.apply()
	Lighting.Technology = Enum.Technology.Future
	-- Ambient, OutdoorAmbient and EnvironmentDiffuseScale all add sky light and
	-- Future stacks them rather than choosing between them, so a value that
	-- looks moderate in isolation is paid for three times over.
	Lighting.Ambient = Color3.fromRGB(40, 42, 52)
	Lighting.OutdoorAmbient = Color3.fromRGB(92, 96, 112)
	Lighting.Brightness = 1.8
	-- Late afternoon rather than near-noon: at this latitude a high sun lands
	-- almost square on the largest surface in the game, the hub floor, and a
	-- raking angle is also what gives flat block geometry any shape at all.
	Lighting.ClockTime = 16.2
	Lighting.GeographicLatitude = 12
	-- Applied before the tonemap, so a positive bias does not merely brighten
	-- the image, it pushes more of it over the bloom threshold.
	Lighting.ExposureCompensation = -0.1
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.32
	Lighting.EnvironmentSpecularScale = 0.22
	Lighting.ShadowSoftness = 0.35

	-- Maps sit 2000 studs apart; fog must not reach from one to the next, and
	-- indoor Mirage should never be hazy, so fog is effectively off and depth
	-- comes from the Atmosphere instead.
	Lighting.FogEnd = 100000
	Lighting.FogStart = 99000

	local atmosphere = ensure("Atmosphere", "LaserTagAtmosphere")
	atmosphere.Density = 0.22
	atmosphere.Offset = 0.15
	-- Haze scatters this colour toward the camera, so the colour matters more
	-- than the amount: a near-white one lays a white veil over the whole scene
	-- at any density. Cool blue-grey reads as distance instead.
	atmosphere.Color = Color3.fromRGB(150, 160, 190)
	atmosphere.Decay = Color3.fromRGB(112, 128, 168)
	-- Glare draws a sun lobe into the same buffer bloom reads from. In an arena
	-- where players pan across the sky constantly it is a second, independent
	-- way to blow the frame out.
	atmosphere.Glare = 0
	atmosphere.Haze = 0.85

	local bloom = ensure("BloomEffect", "LaserTagBloom")
	bloom.Enabled = true
	bloom.Intensity = 0.5
	bloom.Size = 18
	bloom.Threshold = BLOOM_THRESHOLD

	local colorCorrection = ensure("ColorCorrectionEffect", "LaserTagColor")
	colorCorrection.Enabled = true
	-- Contrast pivots about mid-grey, so on an already-bright image it pushes
	-- the top end further toward clipping instead of separating tones. Saturation
	-- is the part that actually makes a Lego palette read as one.
	colorCorrection.Brightness = 0
	colorCorrection.Contrast = 0.06
	colorCorrection.Saturation = 0.2
	colorCorrection.TintColor = Color3.fromRGB(255, 252, 250)

	-- No SunRaysEffect. It is a screen-space pass that costs frames on every
	-- device, and both arenas are enclosed — players would almost never see the
	-- sun it draws rays from. In a game decided by reaction time, that is a bad
	-- trade. The neon look comes from Material.Neon plus the bloom above, which
	-- do not depend on it.

	applied = true
end

function LightingSetup.isApplied(): boolean
	return applied
end

return LightingSetup
