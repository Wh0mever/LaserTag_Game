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
	}
): BasePart
	local part = Instance.new("Part")
	part.Name = config.name
	part.Size = config.size
	part.Color = config.color
	part:SetAttribute("Tone", config.tone or "accent")
	part.Material = config.material or Enum.Material.SmoothPlastic
	part.Transparency = config.transparency or 0
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CFrame = handle.CFrame * CFrame.new(config.offset)
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

local function buildRifle(model: Model, handle: BasePart, accent: Color3, body: Color3, detail: Color3)
	handle.Size = Vector3.new(0.5, 0.55, 3.2)

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

local function buildPistol(model: Model, handle: BasePart, accent: Color3, body: Color3, detail: Color3)
	handle.Size = Vector3.new(0.4, 0.5, 1.7)

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
local function buildLance(model: Model, handle: BasePart, accent: Color3, body: Color3, detail: Color3)
	handle.Size = Vector3.new(0.46, 0.62, 4.4)

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
	local accent = toColor3(skin.color)
	local body = darken(accent, BODY_DARKEN)
	local detail = darken(accent, DETAIL_DARKEN)

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
		buildRifle(model, handle, accent, body, detail)
	elseif weaponId == "Lance" then
		buildLance(model, handle, accent, body, detail)
	else
		buildPistol(model, handle, accent, body, detail)
	end

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
	Recolour an existing model in place — cheaper than rebuilding when a player
	equips a different skin.
]]
function GunModelFactory.applySkin(model: Model, skinId: string)
	local skin = SkinCatalog.get(skinId) or SkinCatalog.get(SkinCatalog.DEFAULT_SKIN_ID)
	local accent = toColor3(skin.color)
	local body = darken(accent, BODY_DARKEN)
	local detail = darken(accent, DETAIL_DARKEN)

	local byTone = { body = body, detail = detail, accent = accent }

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Falls back to the material for a part built before tones existed,
			-- so an old model recolours its neon rather than nothing at all.
			local tone = descendant:GetAttribute("Tone")
			local wanted = byTone[tone] or (if descendant.Material == Enum.Material.Neon then accent else nil)
			if wanted then
				descendant.Color = wanted
			end
		end
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
