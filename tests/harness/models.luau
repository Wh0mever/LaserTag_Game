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

-- An unknown skin must be refused or ignored, never applied as nil colour.
local okUnknown = pcall(function()
	GunModelFactory.applySkin(sample, "no-such-skin")
end)
check(okUnknown, "applySkin survives an unknown skin id")

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
