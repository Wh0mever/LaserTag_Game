--!nonstrict
--[[
	ShopService.luau
	The only path by which a skin is bought or equipped. The client sends an
	intent (a skin id); the server decides, using the player's live profile, and
	answers with a ShopResult:

		{ok: boolean, err: string?, coins: number?, skinId: string?}

	Nothing about a purchase is trusted from the wire — not the price, not
	ownership, not the balance. Economy/ShopLogic owns those rules and is unit
	tested; this file is the wiring between it, the remotes and DataService.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local DataService = require(script.Parent.DataService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local ShopLogic = require(script.Parent.Parent.Economy.ShopLogic)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local Validators = require(script.Parent.Parent.Net.Validators)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local ShopService = {}
ShopService.Priority = 6

-- Rate limits from the network contract. Ten shop actions per five seconds is
-- far beyond what a human clicking a grid produces, and well below what a
-- script hunting for a race in the purchase path would need.
local SHOP_RATE, SHOP_WINDOW = 10, 5

local playerService: any = nil
local playerServiceResolved = false

--[[
	PlayerService is required on first use rather than at module scope. It loads
	at priority 4 and rebuilding a weapon model is a cosmetic refresh, so a build
	without it should still be able to sell skins.
]]
local function getPlayerService(): any
	if playerServiceResolved then
		return playerService
	end
	playerServiceResolved = true

	local moduleScript = script.Parent:FindFirstChild("PlayerService")
	if not moduleScript or not moduleScript:IsA("ModuleScript") then
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	if not ok then
		warn(`[ShopService] could not require PlayerService: {result}`)
		return nil
	end

	playerService = if type(result) == "table" then result else nil
	return playerService
end

local function failure(err: string, data: any)
	return { ok = false, err = err, coins = if data then data.Coins else nil }
end

--[[
	Buy one skin.

	ShopLogic.applyBuy is the transaction: it deducts and grants together or does
	neither, and it is the version under test. DataService, however, owns
	everything that has to happen *alongside* a balance change — the Coins
	attribute, leaderstats and the CoinsChanged remote — and exposes no way to
	resync a balance that moved behind its back. So the deduction is rewound and
	re-spent through DataService.trySpendCoins, which performs it once with all
	its side effects. Nothing between those two statements yields, so no other
	code can ever observe the rewound balance.
]]
local function onBuySkinRequest(player: Player, skinId: string)
	local data = DataService.getData(player)
	if not data then
		return failure(ShopLogic.Errors.NoProfile, nil)
	end

	local coinsBefore = data.Coins

	local ok, err = ShopLogic.applyBuy(data, skinId)
	if not ok then
		return failure(err, data)
	end

	local spent = coinsBefore - data.Coins
	data.Coins = coinsBefore

	if spent > 0 and not DataService.trySpendCoins(player, spent) then
		-- Only reachable if the profile went inactive between the two calls.
		-- Undo the grant rather than leave the player holding a free skin.
		data.OwnedSkins[skinId] = nil
		return failure(ShopLogic.Errors.NoProfile, data)
	end

	DataService.pushSnapshot(player)

	return { ok = true, coins = data.Coins, skinId = skinId }
end

--[[
	Equip one skin on one weapon.

	The third-person gun models bake the skin's colours in at build time, so the
	models are rebuilt here; without that the change would not appear until the
	player's next respawn.
]]
local function onEquipSkinRequest(player: Player, weaponId: string, skinId: string)
	local data = DataService.getData(player)
	if not data then
		return failure(ShopLogic.Errors.NoProfile, nil)
	end

	if not WeaponConfig.exists(weaponId) then
		return failure(ShopLogic.Errors.UnknownWeapon, data)
	end

	local ok, err = ShopLogic.applyEquip(data, weaponId, skinId)
	if not ok then
		return failure(err, data)
	end

	local service = getPlayerService()
	if service and type(service.giveWeapons) == "function" then
		service.giveWeapons(player)
	end

	DataService.pushSnapshot(player)

	return { ok = true, coins = data.Coins, skinId = skinId }
end

local function validateBuy(_player: Player, ...): (boolean, string?)
	return Validators.checkTypes(table.pack(...), { "string" })
end

local function validateEquip(_player: Player, ...): (boolean, string?)
	return Validators.checkTypes(table.pack(...), { "string", "string" })
end

function ShopService.init()
	-- ShopLogic is Roblox-free by design and cannot require the catalog itself;
	-- see the note at the top of that file.
	ShopLogic.setCatalog(SkinCatalog)

	Remotes.register({
		Name = RemoteNames.BuySkinRequest,
		Type = "Function",
		Handler = onBuySkinRequest,
		Validator = validateBuy,
		RateLimit = SHOP_RATE,
		WindowSeconds = SHOP_WINDOW,
	})

	Remotes.register({
		Name = RemoteNames.EquipSkinRequest,
		Type = "Function",
		Handler = onEquipSkinRequest,
		Validator = validateEquip,
		RateLimit = SHOP_RATE,
		WindowSeconds = SHOP_WINDOW,
	})
end

return ShopService
