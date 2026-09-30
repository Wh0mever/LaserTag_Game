--!nonstrict
--[[
	GunModelFactory.luau
	Builds the blocky, Lego-flavoured weapon models entirely in code — there are
	no .rbxm assets in this project, so a fresh clone builds a complete game.

	The same model is used twice:
	  * the client clones it into the Camera as a first-person viewmodel;
	  * the server welds one to each character so other players see the weapon.

	`Handle` is the PrimaryPart and carries the `Muzzle` attachment that laser
	beams originate from.

	A skin is drawn from its three inputs: `color` is the neon and, darkened, the
	body; `accentColor` is the metal trim and the second colour of a pattern;
	`pattern` adds a few thin decal Parts to the receiver. All of it is built here,
	so the viewmodel and the third-person gun cannot disagree.
]]

local SkinCatalog = require(script.Parent.Config.SkinCatalog)
local WeaponConfig = require(script.Parent.Config.WeaponConfig)

local GunModelFactory = {}

local function toColor3(rgb: { r: number, g: number, b: number }): Color3
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

--[[
	The gun's colours, derived from the equipped skin.

	They used to be two module-level constants — a near-black body and a darker
	detail — with the skin colour reaching only the two neon strips. So every
	weapon in the game was the same dark grey object whatever you had equipped,
	and a Legendary gold skin was a black gun with a gold stripe. That is not a
	skin, it is a sticker, and it is why the guns looked drab.

	Derived rather than listed per skin so all thirteen, and every future one,
	get it for free: the body is the skin colour taken most of the way to black,
	the detail further still. That keeps the hue — a gold gun is gold, a cyan gun
	is cyan — while staying dark enough to read as a machined object rather than
	a toy brick, and dark enough for the neon strips to stay the brightest thing
	on it.
]]
local BODY_DARKEN = 0.58
local DETAIL_DARKEN = 0.78

local function darken(color: Color3, amount: number): Color3
	return color:Lerp(Color3.new(0, 0, 0), amount)
end

-- The colours a skin paints the gun with, keyed by the Tone attribute addPart
-- records on each piece. One place, so build and applySkin cannot drift apart.
local function paletteOf(skin): { [string]: Color3 }
	local accent = toColor3(skin.color)
	return {
		accent = accent,
		body = darken(accent, BODY_DARKEN),
		detail = darken(accent, DETAIL_DARKEN),
		-- The skin's second colour, used as it is: it is what makes a Legendary
		-- gun two-toned rather than one hue in three brightnesses.
		trim = toColor3(skin.accentColor),
	}
end

--[[
	Create one welded piece of the gun. Every part is massless and non-collidable
	so the weapon never affects character physics.
]]
local function addPart(
	model: Model,
	handle: BasePart,
	config: {
		name: string,
		size: Vector3,
		offset: Vector3,
		color: Color3,
		material: Enum.Material?,
		transparency: number?,
		-- Which of the skin's three tones this piece takes. Recorded on the part
		-- so applySkin can recolour a built gun without knowing how it was laid
		-- out; without it, only the neon showed the new skin and the body kept
		-- the old one's colour.
		tone: string?,
		-- Roll about the X axis, for a piece lying in the receiver's side plane
		-- (a flame tongue). Radians.
		roll: number?,
		-- Marks the piece as skin decoration so applySkin can swap it out.
		pattern: string?,
	}
): BasePart
	local part = Instance.new("Part")
	part.Name = config.name
	part.Size = config.size
	part.Color = config.color
	part:SetAttribute("Tone", config.tone or "accent")
	if config.pattern then
		part:SetAttribute("Pattern", config.pattern)
	end
	part.Material = config.material or Enum.Material.SmoothPlastic
	part.Transparency = config.transparency or 0
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = handle.CFrame * CFrame.new(config.offset) * CFrame.Angles(config.roll or 0, 0, 0)
	part.Parent = model

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part

	return part
end

--[[
	Small cylinder studs on the top face — the Lego signature.
]]
local function addStuds(
	model: Model,
	handle: BasePart,
	config: {
		count: number,
		spacing: number,
		startZ: number,
		y: number,
		color: Color3,
	}
)
	for index = 1, config.count do
		local stud = Instance.new("Part")
		stud.Name = "Stud" .. index
		stud.Shape = Enum.PartType.Cylinder
		stud.Size = Vector3.new(0.12, 0.3, 0.3)
		stud.Color = config.color
		-- Studs are body-coloured; untagged, applySkin left them the old skin's colour.
		stud:SetAttribute("Tone", "body")
		stud.Material = Enum.Material.SmoothPlastic
		stud.Anchored = false
		stud.CanCollide = false
		stud.CanQuery = false
		stud.CanTouch = false
		stud.Massless = true
		-- Rotate the cylinder so its flat face points up.
		stud.CFrame = handle.CFrame
			* CFrame.new(0, config.y, config.startZ - (index - 1) * config.spacing)
			* CFrame.Angles(0, 0, math.rad(90))
		stud.Parent = model

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = handle
		weld.Part1 = stud
		weld.Parent = stud
	end
end

--[[
	Skin patterns.

	Each is a handful of thin Parts laid on the receiver (the Handle), sized as
	fractions of it, so one implementation fits the rifle, the pistol and the
	lance. Without them an Epic or Legendary skin was the default gun in another
	colour, which is exactly what a Common one is, so the price bought nothing
	you could see.

	The rules tests/harness/models.luau holds them to: at most 10
	parts (the viewmodel and the third-person gun each build one), nothing standing
	more than PROUD off the receiver, and only massless, unqueryable, welded Parts.
	`z` runs along the barrel, negative toward the muzzle, like the offsets below.
]]
local PROUD = 0.02 -- how far a decal may stand off the receiver

local function clamp(value: number, lo: number, hi: number): number
	return math.max(lo, math.min(hi, value))
end

-- One decal plate on each flank, mirrored. Sizes and places are absolute, in the
-- receiver's space; the pattern builders derive them from the receiver's size.
local function addFlank(
	model: Model,
	handle: BasePart,
	name: string,
	id: string,
	spec: {
		thickness: number,
		height: number,
		length: number,
		y: number,
		z: number,
		lift: number?,
		roll: number?,
		color: Color3,
		tone: string,
		material: Enum.Material,
	}
)
	for _, side in { 1, -1 } do
		addPart(model, handle, {
			name = name .. (if side == 1 then "R" else "L"),
			size = Vector3.new(spec.thickness, spec.height, spec.length),
			-- Sunk 0.005 into the receiver so no sliver of air shows behind it;
			-- `lift` stacks a second layer (a star) on top of a first (its panel).
			offset = Vector3.new(
				side * (handle.Size.X / 2 + spec.thickness / 2 - 0.005 + (spec.lift or 0)),
				spec.y,
				spec.z
			),
			color = spec.color,
			tone = spec.tone,
			material = spec.material,
			roll = if spec.roll then side * spec.roll else nil,
			pattern = id,
		})
	end
end

local PatternBuilders = {}

-- Pulse: neon energy rings round the receiver, separated by thin metal collars
-- in the skin's second colour, like a wave leaving the muzzle.
function PatternBuilders.pulse(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local size = handle.Size
	local ring = clamp(size.Z * 0.035, 0.07, 0.16)
	for index, at in { -0.30, -0.10, 0.10 } do
		addPart(model, handle, {
			name = "PatternRing" .. index,
			size = Vector3.new(size.X + PROUD * 2, size.Y + PROUD * 2, ring),
			offset = Vector3.new(0, 0, at * size.Z),
			color = palette.accent,
			tone = "accent",
			material = Enum.Material.Neon,
			pattern = "pulse",
		})
	end
	for index, at in { -0.40, -0.20, 0.0, 0.20 } do
		addPart(model, handle, {
			name = "PatternCollar" .. index,
			size = Vector3.new(size.X + PROUD, size.Y + PROUD, ring * 0.5),
			offset = Vector3.new(0, 0, at * size.Z),
			color = palette.trim,
			tone = "trim",
			material = Enum.Material.Metal,
			pattern = "pulse",
		})
	end
end

-- Galaxy: a dark nebula panel on each flank with three neon stars on it.
function PatternBuilders.galaxy(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local size = handle.Size
	addFlank(model, handle, "PatternNebula", "galaxy", {
		thickness = 0.02,
		height = size.Y * 0.62,
		length = size.Z * 0.34,
		y = 0,
		z = -0.08 * size.Z,
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})
	local star = clamp(size.Y * 0.16, 0.05, 0.12)
	local stars = {
		{ z = -0.17, y = 0.18, scale = 1 },
		{ z = -0.09, y = -0.16, scale = 0.7 },
		{ z = -0.01, y = 0.10, scale = 0.85 },
	}
	for index, spec in stars do
		addFlank(model, handle, "PatternStar" .. index, "galaxy", {
			thickness = 0.02,
			height = star * spec.scale,
			length = star * spec.scale,
			y = spec.y * size.Y,
			z = spec.z * size.Z,
			lift = 0.007,
			color = palette.accent,
			tone = "accent",
			material = Enum.Material.Neon,
		})
	end
end

-- Flame: three neon tongues licking back from a base strip on each flank, the
-- tallest at the rear.
function PatternBuilders.flame(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local size = handle.Size
	local base = size.Y * 0.1
	addFlank(model, handle, "PatternEmber", "flame", {
		thickness = 0.02,
		height = base,
		length = size.Z * 0.46,
		y = -size.Y / 2 + base / 2 + 0.01,
		z = 0.02 * size.Z,
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})
	local width = clamp(size.Z * 0.09, 0.07, 0.22)
	local roll = math.rad(25)
	local tongues = { { z = 0.16, tall = 0.8 }, { z = 0.02, tall = 0.62 }, { z = -0.12, tall = 0.46 } }
	for index, spec in tongues do
		local tall = size.Y * spec.tall
		-- Half the tilted rectangle's height, so the tongue stands on the base
		-- strip and its tip cannot clear the top of the receiver.
		local reach = (math.cos(roll) * tall + math.sin(roll) * width) / 2
		addFlank(model, handle, "PatternFlame" .. index, "flame", {
			thickness = 0.02,
			height = tall,
			length = width,
			y = -size.Y / 2 + base + reach - 0.02,
			z = spec.z * size.Z,
			lift = 0.007,
			roll = roll,
			color = palette.accent,
			tone = "accent",
			material = Enum.Material.Neon,
		})
	end
end

-- Exposed so the catalog and this file are checked against each other: an id
-- here that no skin names is dead code, and an id a skin names that is not here
-- is a promise the gun never keeps.
GunModelFactory.Patterns = PatternBuilders

local function addPattern(model: Model, handle: BasePart, skin, palette: { [string]: Color3 })
	local builder = if skin.pattern then PatternBuilders[skin.pattern] else nil
	if builder then
		builder(model, handle, palette)
	elseif skin.pattern then
		warn(`[GunModelFactory] skin {skin.id} names unknown pattern {tostring(skin.pattern)}`)
	end
	model:SetAttribute("Pattern", skin.pattern)
end

local function buildRifle(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local accent, body, detail = palette.accent, palette.body, palette.detail
	handle.Size = Vector3.new(0.5, 0.55, 3.2)

	-- The skin's second colour as machined trim: a collar at the muzzle and a
	-- pad on the butt, the two places a real rifle wears a different metal.
	addPart(model, handle, {
		name = "TrimMuzzle",
		size = Vector3.new(0.36, 0.36, 0.14),
		offset = Vector3.new(0, 0.06, -2.83),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})
	addPart(model, handle, {
		name = "TrimStock",
		size = Vector3.new(0.44, 0.6, 0.1),
		offset = Vector3.new(0, -0.08, 2.25),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})

	addPart(model, handle, {
		name = "Barrel",
		size = Vector3.new(0.32, 0.32, 1.6),
		offset = Vector3.new(0, 0.06, -2.1),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "Grip",
		size = Vector3.new(0.36, 0.9, 0.5),
		offset = Vector3.new(0, -0.66, 0.5),
		color = body,
		tone = "body",
	})
	addPart(model, handle, {
		name = "Magazine",
		size = Vector3.new(0.34, 0.9, 0.45),
		offset = Vector3.new(0, -0.62, -0.45),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "Stock",
		size = Vector3.new(0.4, 0.55, 0.9),
		offset = Vector3.new(0, -0.08, 1.85),
		color = body,
		tone = "body",
	})
	addPart(model, handle, {
		name = "Sight",
		size = Vector3.new(0.16, 0.24, 0.7),
		offset = Vector3.new(0, 0.4, -0.3),
		color = detail,
		tone = "detail",
	})
	-- The neon chevron stripe: this is what carries the equipped skin colour.
	addPart(model, handle, {
		name = "SkinStripe",
		size = Vector3.new(0.53, 0.16, 2.2),
		offset = Vector3.new(0, 0.18, -0.2),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "EnergyCell",
		size = Vector3.new(0.4, 0.3, 0.4),
		offset = Vector3.new(0, 0.05, 1.15),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})

	addStuds(model, handle, { count = 4, spacing = 0.5, startZ = -1.1, y = 0.34, color = body })
end

local function buildPistol(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local accent, body, detail = palette.accent, palette.body, palette.detail
	handle.Size = Vector3.new(0.4, 0.5, 1.7)

	addPart(model, handle, {
		name = "TrimMuzzle",
		size = Vector3.new(0.3, 0.3, 0.1),
		offset = Vector3.new(0, 0.05, -1.5),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})
	addPart(model, handle, {
		name = "TrimGrip",
		size = Vector3.new(0.36, 0.08, 0.49),
		offset = Vector3.new(0, -0.985, 0.45),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})

	addPart(model, handle, {
		name = "Barrel",
		size = Vector3.new(0.26, 0.26, 0.8),
		offset = Vector3.new(0, 0.05, -1.15),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "Grip",
		size = Vector3.new(0.32, 0.85, 0.45),
		offset = Vector3.new(0, -0.6, 0.45),
		color = body,
		tone = "body",
	})
	addPart(model, handle, {
		name = "Sight",
		size = Vector3.new(0.14, 0.18, 0.4),
		offset = Vector3.new(0, 0.34, -0.4),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "SkinStripe",
		size = Vector3.new(0.43, 0.14, 1.1),
		offset = Vector3.new(0, 0.16, -0.15),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "EnergyCell",
		size = Vector3.new(0.3, 0.24, 0.3),
		offset = Vector3.new(0, -0.5, 0.45),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})

	addStuds(model, handle, { count = 2, spacing = 0.45, startZ = -0.5, y = 0.3, color = body })
end

--[[
	The Arc Lance: long, front-heavy and obviously a marksman weapon at a
	glance. Reading an enemy's weapon before they fire is part of how a fight is
	decided, so the silhouette is deliberately unlike the other two — a long
	barrel, a big scope and a charge coil rather than a compact body.
]]
local function buildLance(model: Model, handle: BasePart, palette: { [string]: Color3 })
	local accent, body, detail = palette.accent, palette.body, palette.detail
	handle.Size = Vector3.new(0.46, 0.62, 4.4)

	addPart(model, handle, {
		name = "TrimMuzzle",
		size = Vector3.new(0.27, 0.27, 0.14),
		offset = Vector3.new(0, 0.08, -3.83),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})
	addPart(model, handle, {
		name = "TrimStock",
		size = Vector3.new(0.44, 0.66, 0.1),
		offset = Vector3.new(0, -0.16, 3.0),
		color = palette.trim,
		tone = "trim",
		material = Enum.Material.Metal,
	})

	addPart(model, handle, {
		name = "Barrel",
		size = Vector3.new(0.22, 0.22, 2.6),
		offset = Vector3.new(0, 0.08, -2.6),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "Scope",
		size = Vector3.new(0.3, 0.3, 1.5),
		offset = Vector3.new(0, 0.5, -0.5),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "ScopeLens",
		size = Vector3.new(0.22, 0.22, 0.1),
		offset = Vector3.new(0, 0.5, -1.28),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "Grip",
		size = Vector3.new(0.34, 0.95, 0.5),
		offset = Vector3.new(0, -0.72, 0.9),
		color = body,
		tone = "body",
	})
	addPart(model, handle, {
		name = "Stock",
		size = Vector3.new(0.4, 0.62, 1.1),
		offset = Vector3.new(0, -0.16, 2.5),
		color = body,
		tone = "body",
	})
	addPart(model, handle, {
		name = "Bipod",
		size = Vector3.new(0.9, 0.12, 0.12),
		offset = Vector3.new(0, -0.34, -1.9),
		color = detail,
		tone = "detail",
	})
	addPart(model, handle, {
		name = "ChargeCoil",
		size = Vector3.new(0.52, 0.52, 0.5),
		offset = Vector3.new(0, 0.02, -1.2),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "SkinStripe",
		size = Vector3.new(0.49, 0.16, 2.6),
		offset = Vector3.new(0, 0.24, 0),
		color = accent,
		tone = "accent",
		material = Enum.Material.Neon,
	})

	addStuds(model, handle, { count = 4, spacing = 0.62, startZ = -0.4, y = 0.36, color = body })
end

--[[
	Build a weapon model.

	`weaponId` must exist in WeaponConfig; `skinId` falls back to the default
	skin when unknown or unowned (ownership is enforced server-side before this
	is ever called with a player's choice).

	The returned model is unparented; the caller decides where it lives.
]]
function GunModelFactory.build(weaponId: string, skinId: string?): Model?
	local weapon = WeaponConfig.get(weaponId)
	if not weapon then
		warn(`[GunModelFactory] unknown weapon: {tostring(weaponId)}`)
		return nil
	end

	local skin = SkinCatalog.get(skinId) or SkinCatalog.get(SkinCatalog.DEFAULT_SKIN_ID)
	local palette = paletteOf(skin)
	local body = palette.body

	local model = Instance.new("Model")
	model.Name = weaponId

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Color = body
	handle:SetAttribute("Tone", "body")
	handle.Material = Enum.Material.SmoothPlastic
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.TopSurface = Enum.SurfaceType.Smooth
	handle.BottomSurface = Enum.SurfaceType.Smooth
	handle.Parent = model

	model.PrimaryPart = handle

	if weaponId == "Rifle" then
		buildRifle(model, handle, palette)
	elseif weaponId == "Lance" then
		buildLance(model, handle, palette)
	else
		buildPistol(model, handle, palette)
	end
	addPattern(model, handle, skin, palette)

	-- Beams and muzzle flashes attach here.
	local muzzle = Instance.new("Attachment")
	muzzle.Name = "Muzzle"
	muzzle.Position = Vector3.new(weapon.muzzleOffset.x, weapon.muzzleOffset.y, weapon.muzzleOffset.z)
	muzzle.Parent = handle

	model:SetAttribute("WeaponId", weaponId)
	model:SetAttribute("SkinId", skin.id)

	return model
end

--[[
	Re-skin an existing model in place — cheaper than rebuilding when a player
	equips a different skin. Recolours every piece by its tone and swaps the
	pattern parts, so the result is the gun build() would have made for that skin.
]]
function GunModelFactory.applySkin(model: Model, skinId: string)
	local skin = SkinCatalog.get(skinId) or SkinCatalog.get(SkinCatalog.DEFAULT_SKIN_ID)
	local palette = paletteOf(skin)

	-- The old skin's decoration goes first: a different pattern is a different
	-- set of parts, not a different colour, and recolouring it would leave a
	-- flame on a gun that is now meant to be plain.
	local stale = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute("Pattern") ~= nil then
			table.insert(stale, descendant)
		end
	end
	for _, part in stale do
		part:Destroy()
	end

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Falls back to the material for a part built before tones existed,
			-- so an old model recolours its neon rather than nothing at all.
			local tone = descendant:GetAttribute("Tone")
			local wanted = palette[tone] or (if descendant.Material == Enum.Material.Neon then palette.accent else nil)
			if wanted then
				descendant.Color = wanted
			end
		end
	end

	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	if handle then
		addPattern(model, handle, skin, palette)
	end

	model:SetAttribute("SkinId", skin.id)
end

--[[
	The muzzle attachment, or nil when the model was not built by this factory.
]]
function GunModelFactory.getMuzzle(model: Model): Attachment?
	local handle = model.PrimaryPart or model:FindFirstChild("Handle")
	return handle and handle:FindFirstChild("Muzzle") or nil
end

return GunModelFactory
