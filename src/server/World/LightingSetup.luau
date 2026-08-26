--!nonstrict
--[[
	LightingSetup.luau
	Global lighting and post-processing, applied once at boot.

	The maps are flat-shaded SmoothPlastic blocks with Neon strips. Neon only
	reads as *glowing* when a Bloom pass picks it up, so the bloom threshold sits
	just under the brightness of a saturated Neon surface. Everything else here
	exists to stop the Lego palette from looking washed out under Future
	lighting: a little contrast and saturation, a thin atmosphere for depth.

	Effects are looked up by name and reused, so calling apply() twice does not
	stack duplicate BloomEffects.
]]

local Lighting = game:GetService("Lighting")

local LightingSetup = {}

-- Neon parts render around 1.0-1.2 scene brightness; blooming below that would
-- smear the white trim as well.
local BLOOM_THRESHOLD = 0.95

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
	Lighting.Ambient = Color3.fromRGB(62, 62, 74)
	Lighting.OutdoorAmbient = Color3.fromRGB(112, 112, 128)
	Lighting.Brightness = 2.2
	Lighting.ClockTime = 14.5
	Lighting.GeographicLatitude = 12
	Lighting.ExposureCompensation = 0.1
	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = 0.45
	Lighting.EnvironmentSpecularScale = 0.35
	Lighting.ShadowSoftness = 0.35

	-- Maps sit 2000 studs apart; fog must not reach from one to the next, and
	-- indoor Mirage should never be hazy, so fog is effectively off and depth
	-- comes from the Atmosphere instead.
	Lighting.FogEnd = 100000
	Lighting.FogStart = 99000

	local atmosphere = ensure("Atmosphere", "LaserTagAtmosphere")
	atmosphere.Density = 0.28
	atmosphere.Offset = 0.15
	atmosphere.Color = Color3.fromRGB(206, 212, 232)
	atmosphere.Decay = Color3.fromRGB(112, 128, 168)
	atmosphere.Glare = 0.15
	atmosphere.Haze = 1.2

	local bloom = ensure("BloomEffect", "LaserTagBloom")
	bloom.Enabled = true
	bloom.Intensity = 0.7
	bloom.Size = 22
	bloom.Threshold = BLOOM_THRESHOLD

	local colorCorrection = ensure("ColorCorrectionEffect", "LaserTagColor")
	colorCorrection.Enabled = true
	colorCorrection.Brightness = 0.015
	colorCorrection.Contrast = 0.12
	colorCorrection.Saturation = 0.16
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
