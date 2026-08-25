--!nonstrict
--[[
	ShopLogic.luau
	Every rule for buying and equipping a cosmetic skin, expressed as pure
	functions over a plain profile table. No Roblox API and no Player, so
	tests/ShopLogic.spec.luau requires this file directly off Roblox while the
	server hands it live Profile.Data.

	The catalog is INJECTED rather than required. A module under src/server can
	only reach src/shared through the DataModel, which the off-Roblox runner does
	not have (the same constraint Combat/DamageCalc documents), and mirroring
	prices here would let the shop's numbers drift from the real ones.
	ShopService injects SkinCatalog at boot; the spec injects that same module by
	relative path, so the tests price skins exactly as the game does.

	Until something injects a catalog every gate below denies. Failing closed is
	the only safe default for functions that hand out cosmetics.

	ATOMICITY: applyBuy and applyEquip validate completely before they write
	anything, so a rejected call leaves the profile byte-for-byte as it found it.
	Keep it that way — never create a missing sub-table during validation, or a
	failed purchase would still have changed the table it claimed not to touch.
]]

local ShopLogic = {}

--[[
	One distinct string per rejection reason. The client shows these verbatim,
	so a player can tell "you cannot afford this" from "you already own this"
	without the UI having to re-derive either.
]]
ShopLogic.Errors = {
	CatalogUnavailable = "The shop is unavailable right now",
	NoProfile = "Your data is still loading",
	UnknownSkin = "That skin does not exist",
	NotPurchasable = "That skin is not for sale",
	AlreadyOwned = "You already own that skin",
	InsufficientCoins = "Not enough coins",
	UnknownWeapon = "That weapon does not exist",
	NotOwned = "You do not own that skin",
}

local Errors = ShopLogic.Errors

local catalog: any = nil

--[[
	Supply the skin catalog. Expects the SkinCatalog interface:
	`get(id)`, `isPurchasable(id)` and `DEFAULT_SKIN_ID`.
]]
function ShopLogic.setCatalog(skinCatalog: any)
	catalog = skinCatalog
end

function ShopLogic.getCatalog(): any
	return catalog
end

--[[
	Whether `data` carries the three fields every shop operation reads or writes.
	A profile missing any of them is mid-load or corrupt; treating it as empty
	would let a purchase write into a table nothing will ever save.
]]
local function isProfile(data: any): boolean
	return type(data) == "table"
		and type(data.Coins) == "number"
		and type(data.OwnedSkins) == "table"
		and type(data.EquippedSkins) == "table"
end

--[[
	Whether `skinId` may be bought with the balance in `data`.
	Returns (false, reason) with a distinct reason per rejection.
]]
function ShopLogic.canBuy(data: any, skinId: any): (boolean, string?)
	if not catalog then
		return false, Errors.CatalogUnavailable
	end

	if not isProfile(data) then
		return false, Errors.NoProfile
	end

	local skin = catalog.get(skinId)
	if not skin then
		return false, Errors.UnknownSkin
	end

	-- The default skin is written into every profile by the template, so selling
	-- it would be charging for something the player already has.
	if not catalog.isPurchasable(skinId) then
		return false, Errors.NotPurchasable
	end

	if data.OwnedSkins[skinId] then
		return false, Errors.AlreadyOwned
	end

	if data.Coins < skin.price then
		return false, Errors.InsufficientCoins
	end

	return true, nil
end

--[[
	Deduct the price and grant the skin, or change nothing at all.

	Both writes happen after every check has passed and neither can fail on its
	own, which is what makes the pair atomic: there is no intermediate state in
	which coins are gone and the skin is not owned.
]]
function ShopLogic.applyBuy(data: any, skinId: any): (boolean, string?)
	local ok, err = ShopLogic.canBuy(data, skinId)
	if not ok then
		return false, err
	end

	local skin = catalog.get(skinId)
	data.Coins -= skin.price
	data.OwnedSkins[skinId] = true

	return true, nil
end

--[[
	Whether `skinId` may be worn on `weaponId`.

	The weapon has to be one the profile already tracks a skin for: that key set
	comes from the profile template, so an unknown weapon id cannot open a new
	slot in the saved data.
]]
function ShopLogic.canEquip(data: any, weaponId: any, skinId: any): (boolean, string?)
	if not catalog then
		return false, Errors.CatalogUnavailable
	end

	if not isProfile(data) then
		return false, Errors.NoProfile
	end

	if type(weaponId) ~= "string" or data.EquippedSkins[weaponId] == nil then
		return false, Errors.UnknownWeapon
	end

	if not catalog.get(skinId) then
		return false, Errors.UnknownSkin
	end

	-- The default skin ships with every profile and is never recorded in
	-- OwnedSkins, so it is always equippable. Everything else must be owned, or
	-- the equip path becomes a way to wear cosmetics that were never bought.
	if skinId ~= catalog.DEFAULT_SKIN_ID and not data.OwnedSkins[skinId] then
		return false, Errors.NotOwned
	end

	return true, nil
end

--[[
	Wear `skinId` on `weaponId`, or change nothing at all.
]]
function ShopLogic.applyEquip(data: any, weaponId: any, skinId: any): (boolean, string?)
	local ok, err = ShopLogic.canEquip(data, weaponId, skinId)
	if not ok then
		return false, err
	end

	data.EquippedSkins[weaponId] = skinId

	return true, nil
end

--[[
	Coin price of a skin, or 0 for anything unknown or free. Callers use this for
	display only — canBuy is the authority on whether a balance covers it.
]]
function ShopLogic.priceOf(skinId: any): number
	local skin = catalog and catalog.get(skinId)
	local price = skin and skin.price
	return if type(price) == "number" and price > 0 then price else 0
end

return ShopLogic
