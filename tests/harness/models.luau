--!nonstrict
--[[
	tests/harness/models.luau
	Builds every weapon in every skin, for real, outside Roblox.

	GunModelFactory is the other large piece of Instance-building code that unit
	tests cannot reach. It runs on both sides — the client clones it into the
	camera as a viewmodel, the server parents it to the character so other
	players see it — so a fault here is visible to everyone in the match.

	Run:  lune run tests/harness/models
]]

local roblox = require("@lune/roblox")

local Env = require("./env")

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

heading("Loading modules")

local GunModelFactory = Env.load("src/shared/GunModelFactory")
local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
local SkinCatalog = Env.load("src/shared/Config/SkinCatalog")
print("  loaded")

--------------------------------------------------------------------------------
-- Every weapon in every skin
--------------------------------------------------------------------------------

local function countParts(model: any): number
	local count = 0
	for _, child in model:GetDescendants() do
		if child:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

local skinIds = {}
for skinId in SkinCatalog.Skins do
	table.insert(skinIds, skinId)
end
table.sort(skinIds)

heading(`Building {#WeaponConfig.Order} weapons x {#skinIds} skins`)

for _, weaponId in WeaponConfig.Order do
	for _, skinId in skinIds do
		local ok, model = pcall(function()
			return GunModelFactory.build(weaponId, skinId)
		end)

		if not ok then
			failed += 1
			table.insert(failures, `{weaponId}/{skinId} threw: {model}`)
			continue
		end

		check(model ~= nil, `{weaponId}/{skinId} builds`)
		if not model then
			continue
		end

		local parts = countParts(model)
		check(parts > 0, `{weaponId}/{skinId} has parts (got {parts})`)

		-- Without a PrimaryPart the model cannot be positioned, so the gun would
		-- sit at the origin instead of in the player's hands.
		check(model.PrimaryPart ~= nil, `{weaponId}/{skinId} has a PrimaryPart`)

		-- The muzzle attachment is where the laser beam starts. No muzzle means
		-- beams fire from the wrong place for every observer.
		local muzzle = GunModelFactory.getMuzzle(model)
		check(muzzle ~= nil, `{weaponId}/{skinId} exposes a muzzle attachment`)

		-- A weapon welded to a character must not drag it around or fall apart.
		local unanchoredNonWelded = 0
		for _, child in model:GetDescendants() do
			if child:IsA("BasePart") and child.CanCollide then
				unanchoredNonWelded += 1
			end
		end
		check(unanchoredNonWelded == 0, `{weaponId}/{skinId} has no colliding parts ({unanchoredNonWelded})`)
	end
end

local firstWeapon = WeaponConfig.Order[1]
local sample = GunModelFactory.build(firstWeapon, SkinCatalog.DEFAULT_SKIN_ID)
print(`  {firstWeapon} in the default skin: {countParts(sample)} parts`)

--------------------------------------------------------------------------------
-- Skin swapping on an existing model
--------------------------------------------------------------------------------

heading("Re-skinning a built model")

for _, skinId in skinIds do
	local ok, err = pcall(function()
		GunModelFactory.applySkin(sample, skinId)
	end)
	check(ok, `applySkin({skinId}) succeeds{if ok then "" else ": " .. tostring(err)}`)
end

--[[
	The WHOLE gun has to take the skin, not just its neon.

	The body and detail colours used to be two module-level constants, so every
	weapon was the same near-black object whatever was equipped and a Legendary
	gold skin was a black gun with a gold stripe. That passed every check there
	was: the model built, the parts were there, the neon was the right colour.
	Nothing asked whether the gun LOOKED like the skin.
]]
local function bodyColorOf(model)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute("Tone") == "body" then
			return descendant.Color
		end
	end
	return nil
end

local goldGun = GunModelFactory.build(firstWeapon, "gold")
local cyanGun = GunModelFactory.build(firstWeapon, "cyan")
local goldBody = goldGun and bodyColorOf(goldGun)
local cyanBody = cyanGun and bodyColorOf(cyanGun)

check(goldBody ~= nil, "a built gun has body-toned parts")
if goldBody and cyanBody then
	check(
		goldBody ~= cyanBody,
		`two skins give two different gun bodies (gold {tostring(goldBody)}, cyan {tostring(cyanBody)})`
	)
	-- Gold is warm, cyan is cold: the hue has to survive the darkening, or
	-- every skin collapses back to the same grey by another route.
	check(goldBody.R > goldBody.B, `the gold gun's body is warm (r {goldBody.R}, b {goldBody.B})`)
	check(cyanBody.B > cyanBody.R, `the cyan gun's body is cold (r {cyanBody.R}, b {cyanBody.B})`)
	-- Still dark enough for the neon to be the brightest thing on the weapon.
	check(goldBody.R < 0.75, `the body stays dark rather than becoming a toy brick ({goldBody.R})`)
end

-- Re-skinning must move the body too, not only the neon.
if cyanGun then
	GunModelFactory.applySkin(cyanGun, "gold")
	local after = bodyColorOf(cyanGun)
	check(after == goldBody, "applySkin recolours the body, not just the glowing parts")
end

-- An unknown skin must be refused or ignored, never applied as nil colour.
local okUnknown = pcall(function()
	GunModelFactory.applySkin(sample, "no-such-skin")
end)
check(okUnknown, "applySkin survives an unknown skin id")

--------------------------------------------------------------------------------
-- Skins have to LOOK like what they cost
--------------------------------------------------------------------------------

--[[
	An Epic or Legendary skin used to be the default gun in another colour:
	`pattern` was named in the catalog and never built, and `accentColor` was
	never read. A Common skin is exactly that, so the shop was charging thirty
	times as much for the same object. These checks are about the object, not the
	price: every rarity above Rare has decoration, every decoration is cheap and
	stays on the receiver, and every skin uses its second colour.
]]
heading("Skin decoration")

local PATTERN_CAP = 10
local EDGE = 0.03 -- the furthest a decal may stand off the receiver

local function patternParts(model: any): { any }
	local found = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute("Pattern") ~= nil then
			table.insert(found, descendant)
		end
	end
	return found
end

local function sameColor(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) < 0.004 and math.abs(a.G - b.G) < 0.004 and math.abs(a.B - b.B) < 0.004
end

-- The parts of a model as comparable text: name, colour, material, size, place.
local function signature(model: any): { string }
	local lines = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local p = descendant.CFrame.Position
			table.insert(
				lines,
				string.format(
					"%s|%s|%s|%.3f,%.3f,%.3f|%.3f,%.3f,%.3f",
					descendant.Name,
					tostring(descendant.Color),
					tostring(descendant.Material),
					descendant.Size.X,
					descendant.Size.Y,
					descendant.Size.Z,
					p.X,
					p.Y,
					p.Z
				)
			)
		end
	end
	table.sort(lines)
	return lines
end

local function differs(a: { string }, b: { string }): boolean
	if #a ~= #b then
		return true
	end
	for index = 1, #a do
		if a[index] ~= b[index] then
			return true
		end
	end
	return false
end

-- Every id the catalog names has a builder, so no skin promises a look it never
-- delivers.
check(GunModelFactory.Patterns ~= nil, "the factory exposes its pattern builders")
local builders = GunModelFactory.Patterns or {}
for skinId, skin in SkinCatalog.Skins do
	if skin.pattern ~= nil then
		check(builders[skin.pattern] ~= nil, `{skinId} names pattern "{skin.pattern}", which has no builder`)
	end
end
for patternId in builders do
	local used = false
	for _, skin in SkinCatalog.Skins do
		used = used or skin.pattern == patternId
	end
	check(used, `pattern "{patternId}" is implemented but no skin uses it`)
end

for _, weaponId in WeaponConfig.Order do
	local default = GunModelFactory.build(weaponId, SkinCatalog.DEFAULT_SKIN_ID)
	local defaultParts = countParts(default)
	local defaultSig = signature(default)
	local crimsonSig = signature(GunModelFactory.build(weaponId, "crimson"))

	for _, skinId in skinIds do
		local skin = SkinCatalog.Skins[skinId]
		local model = GunModelFactory.build(weaponId, skinId)
		local tag = `{weaponId}/{skinId}`
		local decals = patternParts(model)

		-- Epic and Legendary have to show what they cost.
		if SkinCatalog.Rarity[skin.rarity].tier >= 3 then
			check(skin.pattern ~= nil, `{tag} is {skin.rarity} but names no pattern`)
			check(#decals >= 4, `{tag} shows a visible pattern ({#decals} decal parts)`)
		else
			check(#decals == 0, `{tag} is {skin.rarity} and carries no pattern parts ({#decals})`)
		end

		-- Cheap: both the viewmodel and the third-person gun build one.
		check(#decals <= PATTERN_CAP, `{tag} pattern stays under {PATTERN_CAP} parts (got {#decals})`)
		check(
			countParts(model) - defaultParts <= PATTERN_CAP,
			`{tag} adds at most {PATTERN_CAP} parts over the default (got {countParts(model) - defaultParts})`
		)

		-- Decoration is inert and rides on the receiver, never off the silhouette.
		local handle = model.PrimaryPart
		local half = handle.Size / 2
		for _, decal in decals do
			check(
				not decal.CanCollide and not decal.CanQuery and not decal.CanTouch and decal.Massless,
				`{tag}/{decal.Name} is massless and neither collides, queries nor touches`
			)
			check(decal:FindFirstChildOfClass("WeldConstraint") ~= nil, `{tag}/{decal.Name} is welded`)
			local worst = { x = 0, y = 0, z = 0 }
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = handle.CFrame:PointToObjectSpace(
							(decal.CFrame * roblox.CFrame.new(
								sx * decal.Size.X / 2,
								sy * decal.Size.Y / 2,
								sz * decal.Size.Z / 2
							)).Position
						)
						worst.x = math.max(worst.x, math.abs(corner.X) - half.X)
						worst.y = math.max(worst.y, math.abs(corner.Y) - half.Y)
						worst.z = math.max(worst.z, math.abs(corner.Z) - half.Z)
					end
				end
			end
			check(
				worst.x <= EDGE and worst.y <= EDGE and worst.z <= 0.001,
				`{tag}/{decal.Name} stays on the receiver (over by x {worst.x}, y {worst.y}, z {worst.z})`
			)
		end

		-- accentColor is used: some part wears it exactly.
		if not skin.isDefault then
			local wanted = roblox.Color3.fromRGB(skin.accentColor.r, skin.accentColor.g, skin.accentColor.b)
			local wearing = false
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("BasePart") and sameColor(descendant.Color, wanted) then
					wearing = true
				end
			end
			check(wearing, `{tag} shows its accentColor on the gun`)

			-- Not only a recolour of the default.
			local sig = signature(model)
			check(differs(sig, defaultSig), `{tag} differs from the default gun`)
			check(skinId == "crimson" or differs(sig, crimsonSig), `{tag} differs from another skin`)
		end
	end
end

-- A pattern skin differs from a plain skin in parts, not only in colour.
do
	local plain = GunModelFactory.build(firstWeapon, "toxic")
	local decorated = GunModelFactory.build(firstWeapon, "galaxy")
	check(countParts(decorated) > countParts(plain), "a pattern skin has more parts than a plain one")
end

-- Three patterns, three looks.
do
	local names = {}
	for _, skinId in { "magenta", "galaxy", "dragon" } do
		local model = GunModelFactory.build(firstWeapon, skinId)
		local list = {}
		for _, decal in patternParts(model) do
			table.insert(list, decal.Name)
		end
		table.sort(list)
		names[skinId] = table.concat(list, ",")
	end
	check(
		names.magenta ~= names.galaxy and names.galaxy ~= names.dragon and names.magenta ~= names.dragon,
		"pulse, galaxy and flame build different parts"
	)
end

-- Re-skinning a gun in place gives the same gun as building it fresh, patterns
-- included: without this a re-skinned gun kept the old skin's decoration.
for _, weaponId in WeaponConfig.Order do
	for _, pair in { { "dragon", "galaxy" }, { "galaxy", "crimson" }, { "crimson", "eclipse" } } do
		local model = GunModelFactory.build(weaponId, pair[1])
		GunModelFactory.applySkin(model, pair[2])
		check(
			not differs(signature(model), signature(GunModelFactory.build(weaponId, pair[2]))),
			`{weaponId}: applySkin {pair[1]} -> {pair[2]} equals a fresh {pair[2]} build`
		)
		check(model:GetAttribute("SkinId") == pair[2], `{weaponId}: applySkin records the skin id`)
	end
end

-- The same skin builds the same gun every time (viewmodel and world model).
do
	local first = GunModelFactory.build("Lance", "dragon")
	local second = GunModelFactory.build("Lance", "dragon")
	check(not differs(signature(first), signature(second)), "two builds of one skin are identical")
end

--------------------------------------------------------------------------------
-- Unknown weapon
--------------------------------------------------------------------------------

heading("Unknown weapon")

local okBuild, unknown = pcall(function()
	return GunModelFactory.build("NoSuchWeapon", SkinCatalog.DEFAULT_SKIN_ID)
end)
check(okBuild and unknown == nil, "build() returns nil for an unknown weapon rather than throwing")

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")
-- Spawned work runs on its own thread now, so a thread that dies takes its
-- timer or its poll with it and says nothing. This is where it says something.
check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} model check(s) failed`, 0)
end

print("  All model checks passed.")
