--!nonstrict
--[[
	SkinCatalog.luau
	Cosmetic weapon skins: laser beam colour and gun accent colour only.

	Deliberately cosmetic-only. Selling anything that changes damage, fire rate
	or accuracy would be pay-to-win in a competitive PvP mode, which the skill's
	monetization guidance rules out.

	Colours are {r, g, b} tables so this module stays Roblox-free.

	PRICING
	Rarity is the only thing that sets a price. Each tier is roughly 3x the one
	below it, and prices inside a tier stay within about 1.4x of each other, so
	the badge on a card tells a player what it costs before they read the number.
	The old ladder did not hold: Epic ran 1200-3200 (2.7x apart internally) while
	the cheapest Legendary was only 1.56x the dearest Epic, so rarity and price
	had come loose from each other.

	  Common     1200-1400     roughly two matches
	  Rare       3500-4500     roughly six
	  Epic      10000-14000    roughly twenty
	  Legendary 36000-48000    roughly sixty

	Those match counts assume an average player (see tests/Economy.spec.luau,
	which asserts the bands and the earn rate together — a price change that
	makes a tier unreachable, or reachable in an afternoon, fails there).
]]

local SkinCatalog = {}

SkinCatalog.Rarity = {
	Common = { tier = 1, color = { r = 200, g = 200, b = 200 } },
	Rare = { tier = 2, color = { r = 60, g = 140, b = 255 } },
	Epic = { tier = 3, color = { r = 170, g = 70, b = 255 } },
	Legendary = { tier = 4, color = { r = 255, g = 190, b = 40 } },
}

-- Price band per rarity, as {min, max}. The catalog above must stay inside
-- these, and tests/Economy.spec.luau is what makes "must" mean something.
SkinCatalog.PriceBands = {
	Common = { min = 1000, max = 1500 },
	Rare = { min = 3000, max = 5000 },
	Epic = { min = 9000, max = 15000 },
	Legendary = { min = 30000, max = 50000 },
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
		price = 1200,
		rarity = "Common",
		color = { r = 255, g = 60, b = 60 },
		accentColor = { r = 120, g = 20, b = 20 },
		isDefault = false,
	},
	gold = {
		id = "gold",
		displayName = "Gold Rush",
		price = 3500,
		rarity = "Rare",
		color = { r = 255, g = 200, b = 40 },
		accentColor = { r = 140, g = 100, b = 10 },
		isDefault = false,
	},
	cyan = {
		id = "cyan",
		displayName = "Deep Cyan",
		price = 3500,
		rarity = "Rare",
		color = { r = 40, g = 220, b = 255 },
		accentColor = { r = 10, g = 90, b = 120 },
		isDefault = false,
	},
	toxic = {
		id = "toxic",
		displayName = "Toxic",
		price = 4000,
		rarity = "Rare",
		color = { r = 130, g = 255, b = 60 },
		accentColor = { r = 40, g = 110, b = 20 },
		isDefault = false,
	},
	magenta = {
		id = "magenta",
		displayName = "Magenta Pulse",
		price = 10000,
		rarity = "Epic",
		color = { r = 255, g = 60, b = 200 },
		accentColor = { r = 110, g = 20, b = 90 },
		isDefault = false,
		pattern = "pulse",
	},
	galaxy = {
		id = "galaxy",
		displayName = "Galaxy",
		price = 12500,
		rarity = "Epic",
		color = { r = 150, g = 90, b = 255 },
		accentColor = { r = 40, g = 20, b = 90 },
		isDefault = false,
		pattern = "galaxy",
	},
	dragon = {
		id = "dragon",
		displayName = "Dragonfire",
		price = 36000,
		rarity = "Legendary",
		color = { r = 255, g = 120, b = 20 },
		accentColor = { r = 120, g = 40, b = 0 },
		isDefault = false,
		pattern = "flame",
	},
	arctic = {
		id = "arctic",
		displayName = "Arctic",
		price = 1400,
		rarity = "Common",
		color = { r = 176, g = 232, b = 255 },
		accentColor = { r = 60, g = 110, b = 150 },
		isDefault = false,
	},
	ember = {
		id = "ember",
		displayName = "Ember",
		price = 4500,
		rarity = "Rare",
		color = { r = 255, g = 122, b = 26 },
		accentColor = { r = 96, g = 32, b = 8 },
		isDefault = false,
	},
	voidwalker = {
		id = "voidwalker",
		displayName = "Voidwalker",
		price = 11000,
		rarity = "Epic",
		color = { r = 122, g = 62, b = 255 },
		accentColor = { r = 24, g = 10, b = 48 },
		isDefault = false,
		pattern = "pulse",
	},
	prism = {
		id = "prism",
		displayName = "Prism",
		price = 14000,
		rarity = "Epic",
		color = { r = 255, g = 128, b = 220 },
		accentColor = { r = 90, g = 220, b = 255 },
		isDefault = false,
		pattern = "pulse",
	},
	eclipse = {
		id = "eclipse",
		displayName = "Eclipse",
		price = 48000,
		rarity = "Legendary",
		color = { r = 255, g = 236, b = 168 },
		accentColor = { r = 18, g = 16, b = 28 },
		isDefault = false,
		pattern = "flame",
	},
}

-- Display order for the shop grid, cheapest first.
SkinCatalog.Order = {
	"default",
	"crimson",
	"arctic",
	"gold",
	"cyan",
	"toxic",
	"ember",
	"magenta",
	"voidwalker",
	"galaxy",
	"prism",
	"dragon",
	"eclipse",
}

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
