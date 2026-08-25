--!nonstrict
--[[
	SkinCatalog.luau
	Cosmetic weapon skins: laser beam colour and gun accent colour only.

	Deliberately cosmetic-only. Selling anything that changes damage, fire rate
	or accuracy would be pay-to-win in a competitive PvP mode, which the skill's
	monetization guidance rules out.

	Colours are {r, g, b} tables so this module stays Roblox-free.
]]

local SkinCatalog = {}

SkinCatalog.Rarity = {
	Common = { tier = 1, color = { r = 200, g = 200, b = 200 } },
	Rare = { tier = 2, color = { r = 60, g = 140, b = 255 } },
	Epic = { tier = 3, color = { r = 170, g = 70, b = 255 } },
	Legendary = { tier = 4, color = { r = 255, g = 190, b = 40 } },
}

SkinCatalog.Skins = {
	default = {
		id = "default",
		displayName = "Standard",
		price = 0,
		rarity = "Common",
		color = { r = 0, g = 229, b = 255 },
		accentColor = { r = 235, g = 235, b = 245 },
		isDefault = true,
	},
	crimson = {
		id = "crimson",
		displayName = "Crimson",
		price = 400,
		rarity = "Common",
		color = { r = 255, g = 60, b = 60 },
		accentColor = { r = 120, g = 20, b = 20 },
		isDefault = false,
	},
	gold = {
		id = "gold",
		displayName = "Gold Rush",
		price = 600,
		rarity = "Rare",
		color = { r = 255, g = 200, b = 40 },
		accentColor = { r = 140, g = 100, b = 10 },
		isDefault = false,
	},
	cyan = {
		id = "cyan",
		displayName = "Deep Cyan",
		price = 600,
		rarity = "Rare",
		color = { r = 40, g = 220, b = 255 },
		accentColor = { r = 10, g = 90, b = 120 },
		isDefault = false,
	},
	toxic = {
		id = "toxic",
		displayName = "Toxic",
		price = 800,
		rarity = "Rare",
		color = { r = 130, g = 255, b = 60 },
		accentColor = { r = 40, g = 110, b = 20 },
		isDefault = false,
	},
	magenta = {
		id = "magenta",
		displayName = "Magenta Pulse",
		price = 1200,
		rarity = "Epic",
		color = { r = 255, g = 60, b = 200 },
		accentColor = { r = 110, g = 20, b = 90 },
		isDefault = false,
		pattern = "pulse",
	},
	galaxy = {
		id = "galaxy",
		displayName = "Galaxy",
		price = 2500,
		rarity = "Epic",
		color = { r = 150, g = 90, b = 255 },
		accentColor = { r = 40, g = 20, b = 90 },
		isDefault = false,
		pattern = "galaxy",
	},
	dragon = {
		id = "dragon",
		displayName = "Dragonfire",
		price = 5000,
		rarity = "Legendary",
		color = { r = 255, g = 120, b = 20 },
		accentColor = { r = 120, g = 40, b = 0 },
		isDefault = false,
		pattern = "flame",
	},
}

-- Display order for the shop grid, cheapest first.
SkinCatalog.Order = { "default", "crimson", "gold", "cyan", "toxic", "magenta", "galaxy", "dragon" }

SkinCatalog.DEFAULT_SKIN_ID = "default"

function SkinCatalog.get(skinId: any)
	if type(skinId) ~= "string" then
		return nil
	end
	return SkinCatalog.Skins[skinId]
end

function SkinCatalog.exists(skinId: any): boolean
	return SkinCatalog.get(skinId) ~= nil
end

function SkinCatalog.isPurchasable(skinId: any): boolean
	local skin = SkinCatalog.get(skinId)
	return skin ~= nil and not skin.isDefault and skin.price > 0
end

function SkinCatalog.rarityColor(skinId: string)
	local skin = SkinCatalog.get(skinId)
	local rarity = skin and SkinCatalog.Rarity[skin.rarity]
	return rarity and rarity.color or SkinCatalog.Rarity.Common.color
end

return SkinCatalog
