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

local BODY_COLOR = Color3.fromRGB(38, 40, 48)
local DETAIL_COLOR = Color3.fromRGB(22, 23, 28)

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
	}
): BasePart
	local part = Instance.new("Part")
	part.Name = config.name
	part.Size = config.size
	part.Color = config.color
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

local function buildRifle(model: Model, handle: BasePart, accent: Color3)
	handle.Size = Vector3.new(0.5, 0.55, 3.2)

	addPart(model, handle, {
		name = "Barrel",
		size = Vector3.new(0.32, 0.32, 1.6),
		offset = Vector3.new(0, 0.06, -2.1),
		color = DETAIL_COLOR,
	})
	addPart(model, handle, {
		name = "Grip",
		size = Vector3.new(0.36, 0.9, 0.5),
		offset = Vector3.new(0, -0.66, 0.5),
		color = BODY_COLOR,
	})
	addPart(model, handle, {
		name = "Magazine",
		size = Vector3.new(0.34, 0.9, 0.45),
		offset = Vector3.new(0, -0.62, -0.45),
		color = DETAIL_COLOR,
	})
	addPart(model, handle, {
		name = "Stock",
		size = Vector3.new(0.4, 0.55, 0.9),
		offset = Vector3.new(0, -0.08, 1.85),
		color = BODY_COLOR,
	})
	addPart(model, handle, {
		name = "Sight",
		size = Vector3.new(0.16, 0.24, 0.7),
		offset = Vector3.new(0, 0.4, -0.3),
		color = DETAIL_COLOR,
	})
	-- The neon chevron stripe: this is what carries the equipped skin colour.
	addPart(model, handle, {
		name = "SkinStripe",
		size = Vector3.new(0.53, 0.16, 2.2),
		offset = Vector3.new(0, 0.18, -0.2),
		color = accent,
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "EnergyCell",
		size = Vector3.new(0.4, 0.3, 0.4),
		offset = Vector3.new(0, 0.05, 1.15),
		color = accent,
		material = Enum.Material.Neon,
	})

	addStuds(model, handle, { count = 4, spacing = 0.5, startZ = -1.1, y = 0.34, color = BODY_COLOR })
end

local function buildPistol(model: Model, handle: BasePart, accent: Color3)
	handle.Size = Vector3.new(0.4, 0.5, 1.7)

	addPart(model, handle, {
		name = "Barrel",
		size = Vector3.new(0.26, 0.26, 0.8),
		offset = Vector3.new(0, 0.05, -1.15),
		color = DETAIL_COLOR,
	})
	addPart(model, handle, {
		name = "Grip",
		size = Vector3.new(0.32, 0.85, 0.45),
		offset = Vector3.new(0, -0.6, 0.45),
		color = BODY_COLOR,
	})
	addPart(model, handle, {
		name = "Sight",
		size = Vector3.new(0.14, 0.18, 0.4),
		offset = Vector3.new(0, 0.34, -0.4),
		color = DETAIL_COLOR,
	})
	addPart(model, handle, {
		name = "SkinStripe",
		size = Vector3.new(0.43, 0.14, 1.1),
		offset = Vector3.new(0, 0.16, -0.15),
		color = accent,
		material = Enum.Material.Neon,
	})
	addPart(model, handle, {
		name = "EnergyCell",
		size = Vector3.new(0.3, 0.24, 0.3),
		offset = Vector3.new(0, -0.5, 0.45),
		color = accent,
		material = Enum.Material.Neon,
	})

	addStuds(model, handle, { count = 2, spacing = 0.45, startZ = -0.5, y = 0.3, color = BODY_COLOR })
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

	local model = Instance.new("Model")
	model.Name = weaponId

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Color = BODY_COLOR
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
		buildRifle(model, handle, accent)
	else
		buildPistol(model, handle, accent)
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

	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Neon then
			descendant.Color = accent
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
