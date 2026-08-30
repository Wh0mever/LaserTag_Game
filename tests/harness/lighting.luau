--!nonstrict
--[[
	tests/harness/lighting.luau
	Runs the real lighting rig and checks it against the surfaces it lights.

	LightingSetup.apply() has never been executed by anything except a running
	game: the module harness only requires the file, so every property name and
	every number in it is unverified until a playtest. That matters most for the
	bloom threshold, which is not a look-and-feel dial but a comparison against
	the brightness of the map — set it below what an ordinary lit wall returns
	and the whole map glows, which reads as a broken renderer rather than as a
	setting anyone chose.

	The rig is applied here for real (Lune validates every property against
	Roblox's class database) and then compared against every part the map builder
	produces, split by material: Neon is meant to bloom, everything else is not.

	Run:  lune run tests/harness/lighting
]]

local Env = require("./env")
-- The sandbox hands `Enum` to the modules it loads, not to this file, so the
-- comparison against Material.Neon takes it from the same place the sandbox does.
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

local passed = 0
local failed = 0
local failures: { string } = {}

local function check(ok: boolean, message: string)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, message)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

--------------------------------------------------------------------------------
-- Apply the rig
--------------------------------------------------------------------------------

heading("Applying the rig")

local LightingSetup = Env.load("src/server/World/LightingSetup")
local Lighting = Env.service("Lighting")

check(not LightingSetup.isApplied(), "the rig reports itself unapplied before apply()")

local applyOk, applyErr = pcall(LightingSetup.apply)
check(applyOk, `apply() runs{if applyOk then "" else ": " .. tostring(applyErr)}`)
if not applyOk then
	error(applyErr, 0)
end
check(LightingSetup.isApplied(), "the rig reports itself applied")

local function effect(name: string, className: string)
	local found = Lighting:FindFirstChild(name)
	check(found ~= nil and found.ClassName == className, `Lighting holds a {className} named {name}`)
	return found
end

local atmosphere = effect("LaserTagAtmosphere", "Atmosphere")
local bloom = effect("LaserTagBloom", "BloomEffect")
local colorCorrection = effect("LaserTagColor", "ColorCorrectionEffect")

-- Calling apply() twice must not stack a second bloom pass on top of the first:
-- two BloomEffects is double the cost and a look nobody tuned.
LightingSetup.apply()
local counts: { [string]: number } = {}
for _, child in Lighting:GetChildren() do
	counts[child.ClassName] = (counts[child.ClassName] or 0) + 1
end
for _, className in { "Atmosphere", "BloomEffect", "ColorCorrectionEffect" } do
	check(counts[className] == 1, `apply() is idempotent for {className} (got {counts[className] or 0})`)
end

check(bloom.Enabled, "bloom is enabled")
check(colorCorrection.Enabled, "colour correction is enabled")
check(atmosphere.Density > 0, "the atmosphere has some density")

--------------------------------------------------------------------------------
-- The rig's own numbers
--
-- Bloom is applied before the tonemap and its threshold is compared against
-- scene brightness, which Lune cannot compute — there is no renderer here. So
-- these are bounds on the inputs rather than a prediction of the output, each
-- one a value that was wrong when the hub rendered as a white sheet.
--------------------------------------------------------------------------------

heading("The rig")

-- 0.95 is the engine default, and a default threshold is only survivable if the
-- map is not mostly near-white — which the "Surfaces" section below is what
-- actually enforces. Sitting above the default buys headroom for the trim.
check(bloom.Threshold >= 0.95, `the bloom threshold is not below the engine default (got {bloom.Threshold})`)

-- Neon is emissive and ignores Lighting.Brightness; every diffuse surface
-- scales with it. So this is the one dial that separates "the neon glows" from
-- "the floor glows", and it only moves one of them.
check(Lighting.Brightness <= 2, `the sun is not overdriven (Brightness {Lighting.Brightness})`)

-- Applied before the tonemap, so a positive bias pushes the whole frame toward
-- the bloom threshold rather than merely looking brighter.
check(Lighting.ExposureCompensation <= 0, `exposure is not biased upward (got {Lighting.ExposureCompensation})`)

-- Glare draws its own sun lobe into the same buffer the threshold reads, on top
-- of the bloom pass. In an arena where players pan across the sky constantly it
-- is a second, unrelated way to white out the frame.
check(atmosphere.Glare <= 0.05, `atmospheric glare is off (got {atmosphere.Glare})`)

-- Haze scatters Atmosphere.Color toward the camera. The haze value matters far
-- less than the colour it scatters: a near-white one lays a white veil over
-- everything at any density.
check(
	math.max(atmosphere.Color.R, atmosphere.Color.G, atmosphere.Color.B) <= 0.8,
	"the atmosphere scatters a tinted colour rather than a white one"
)

--------------------------------------------------------------------------------
-- What the maps are made of
--
-- Two scale-free properties, which is all that can be honestly asserted without
-- a renderer. Both were false when the hub blew out, and either one being false
-- is enough to produce it:
--
--   1. ORDERING. Every Neon surface must be brighter than every ordinary one.
--      Bloom has a single threshold; if the brightest wall outranks the dimmest
--      neon strip, no value of that threshold can pick out the neon, and the
--      one that makes the neon glow necessarily makes the wall glow too.
--
--   2. AREA. Bright surfaces must be trim and highlights, not floors. A palette
--      can satisfy the ordering and still fill the screen with pale grey, and
--      a screen that is mostly pale grey is a white screen once anything at all
--      blooms.
--
-- Brightness is measured as the peak channel, because that is what clips first
-- and what the bloom pass sees; luminance would let a saturated colour with one
-- maxed channel read as dark.
--------------------------------------------------------------------------------

heading("Surfaces")

-- Above this, an ordinary surface is a highlight and must stay small.
local BRIGHT = 0.72
-- Above this it is effectively white, and nothing diffuse should be.
local NEAR_WHITE = 0.86
-- Shares of the map's ordinary surface area allowed at each level.
local MAX_BRIGHT_SHARE = 0.3
local MAX_NEAR_WHITE_SHARE = 0.05
-- Neon must clear the brightest ordinary surface by this much for one threshold
-- to be able to sit between them.
local SEPARATION = 0.06

local function peakOf(color: any): number
	return math.max(color.R, color.G, color.B)
end

--[[
	Surface area of a part, in studs squared. Area is the whole point: one
	near-white bench is a highlight, the same colour on a 200x200 plaza floor is
	the entire screen.
]]
local function areaOf(size: any): number
	return 2 * (size.X * size.Y + size.Y * size.Z + size.Z * size.X)
end

local MapBuilder = Env.load("src/server/World/MapBuilder")
local MAPS = {
	{ id = "Hub", def = Env.load("src/shared/MapDefs/HubDef") },
	{ id = "Dust", def = Env.load("src/shared/MapDefs/DustDef") },
	{ id = "Mirage", def = Env.load("src/shared/MapDefs/MirageDef") },
	{ id = "Nexus", def = Env.load("src/shared/MapDefs/NexusDef") },
}

local NEON = roblox.Enum.Material.Neon

for _, entry in MAPS do
	local built = MapBuilder.build(entry.def)

	local brightest, brightestPart = 0, "?"
	local dimmestNeon, dimmestNeonPart = math.huge, "?"
	local totalArea, brightArea, whiteArea = 0, 0, 0
	local whitestPart = "?"

	local function walk(node)
		for _, child in node:GetChildren() do
			if child:IsA("BasePart") then
				local peak = peakOf(child.Color)
				if child.Material == NEON then
					if peak < dimmestNeon then
						dimmestNeon, dimmestNeonPart = peak, child.Name
					end
				else
					local area = areaOf(child.Size)
					totalArea += area
					if peak >= BRIGHT then
						brightArea += area
					end
					if peak >= NEAR_WHITE then
						whiteArea += area
						whitestPart = child.Name
					end
					if peak > brightest then
						brightest, brightestPart = peak, child.Name
					end
				end
			end
			walk(child)
		end
	end
	walk(built.model)

	local brightShare = if totalArea > 0 then brightArea / totalArea else 0
	local whiteShare = if totalArea > 0 then whiteArea / totalArea else 0

	print(
		string.format(
			"  %-7s brightest ordinary %.3f (%s); dimmest neon %.3f (%s); bright %.1f%%, near-white %.1f%% of %d studs²",
			entry.id,
			brightest,
			brightestPart,
			dimmestNeon,
			dimmestNeonPart,
			brightShare * 100,
			whiteShare * 100,
			math.floor(totalArea)
		)
	)

	-- One threshold has to separate the two populations. If the brightest wall
	-- outranks the dimmest neon strip there is no value that can: the setting
	-- that makes the lasers glow is the same setting that makes the map glow.
	check(
		dimmestNeon >= brightest + SEPARATION,
		string.format(
			"%s: neon outranks every ordinary surface (dimmest neon %s %.3f vs brightest %s %.3f)",
			entry.id,
			dimmestNeonPart,
			dimmestNeon,
			brightestPart,
			brightest
		)
	)

	-- The hub failed this one at 42%: a 200x200 near-white plaza floor with a
	-- near-white inlay on top of it. Ordering alone would have passed.
	check(
		whiteShare <= MAX_NEAR_WHITE_SHARE,
		string.format(
			"%s: near-white is trim, not floors (%.1f%% of surface at/above %.2f, worst %s; cap %.0f%%)",
			entry.id,
			whiteShare * 100,
			NEAR_WHITE,
			whitestPart,
			MAX_NEAR_WHITE_SHARE * 100
		)
	)

	check(
		brightShare <= MAX_BRIGHT_SHARE,
		string.format(
			"%s: the bright end of the palette stays a minority (%.1f%% at/above %.2f; cap %.0f%%)",
			entry.id,
			brightShare * 100,
			BRIGHT,
			MAX_BRIGHT_SHARE * 100
		)
	)
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")
print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} lighting check(s) failed`, 0)
end

print("  All lighting checks passed.")
