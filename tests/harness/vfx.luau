--!nonstrict
--[[
	tests/harness/vfx.luau
	What the player SEES and FEELS when the gun goes off: where the beam starts,
	what the viewmodel does against a wall, the sparks, the hitmarker, the
	crosshair, the death view and the view button.

	Everything here is presentation, so the checks are written as geometry and
	as counts of what reached the engine — a beam that starts at the head is a
	beam whose first point is at the head — rather than as "was function X
	called". The sandbox has no renderer, so each check reads the property the
	engine would draw from.

	The data model behind this sandbox lacks a few engine members these effects
	stand on (Model:PivotTo and :ScaleTo, Attachment.WorldPosition). They are
	given honest implementations below, in terms of the parts' own CFrames and
	sizes, because a viewmodel test that could not move the model would only be
	testing the mock.

	Run:  lune run tests/harness/vfx
]]

local Env = require("./env")
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
-- Engine members the data model does not have
--------------------------------------------------------------------------------

local SCALE_ATTRIBUTE = "HarnessScale"

local function partsOf(model: any): { any }
	local parts = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
		end
	end
	return parts
end

-- Attachment.WorldPosition is a property the class database already knows, so
-- it cannot be replaced by a getter; it can be written, though. Every move of a
-- model below therefore re-records where its attachments now are, which is the
-- value the engine would compute on read.
local function syncAttachments(model: any)
	for _, part in partsOf(model) do
		for _, child in part:GetChildren() do
			if child:IsA("Attachment") then
				child.WorldPosition = part.CFrame * child.Position
			end
		end
	end
end

roblox.implementMethod("Model", "GetPivot", function(self)
	return self.PrimaryPart.CFrame
end)

roblox.implementMethod("Model", "PivotTo", function(self, target)
	local pivot = self.PrimaryPart.CFrame
	for _, part in partsOf(self) do
		part.CFrame = target * pivot:ToObjectSpace(part.CFrame)
	end
	syncAttachments(self)
end)

roblox.implementMethod("Model", "GetScale", function(self)
	return self:GetAttribute(SCALE_ATTRIBUTE) or 1
end)

-- Scales about the pivot, as the engine does: sizes, the parts' distance from
-- the pivot, and attachment positions all change by the same ratio.
roblox.implementMethod("Model", "ScaleTo", function(self, factor: number)
	local ratio = factor / (self:GetAttribute(SCALE_ATTRIBUTE) or 1)
	local pivot = self.PrimaryPart.CFrame
	for _, part in partsOf(self) do
		local relative = pivot:ToObjectSpace(part.CFrame)
		local rotation = relative - relative.Position
		part.Size = part.Size * ratio
		part.CFrame = pivot * (roblox.CFrame.new(relative.Position * ratio) * rotation)
		for _, child in part:GetChildren() do
			if child:IsA("Attachment") then
				child.Position = child.Position * ratio
			end
		end
	end
	self:SetAttribute(SCALE_ATTRIBUTE, factor)
	syncAttachments(self)
end)

-- Emit exists only while a game runs. The count is kept so a check can ask how
-- many particles an effect actually released.
local emitted = 0

roblox.implementMethod("ParticleEmitter", "Emit", function(_self, count: number?)
	emitted += count or 1
end)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local V3 = roblox.Vector3
local CF = roblox.CFrame

local function boot(device: string)
	Env.reset()
	Env.setDevice(device)
	Env.enableClientRuntime()
end

-- A living character with a HumanoidRootPart. `gunId` welds a gun on the way
-- the server does: a Model carrying the WeaponId attribute.
local function makeCharacter(gunId: string?, gunAt: any?)
	local character = roblox.Instance.new("Model")
	character.Name = "HarnessCharacter"

	local root = roblox.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = V3.new(2, 2, 1)
	root.Parent = character
	character.PrimaryPart = root

	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = character

	if gunId then
		local gun = Env.load("src/shared/GunModelFactory").build(gunId, nil)
		gun.Parent = character
		gun:PivotTo(gunAt or CF.new(0, 0, 0))
	end

	return character
end

-- The pooled part of every beam that is currently switched on.
local function livingBeams(folder: any): { any }
	local found = {}
	for _, child in folder:GetChildren() do
		local beam = child:FindFirstChildOfClass("Beam")
		if beam and beam.Enabled then
			table.insert(found, child)
		end
	end
	return found
end

local function near(a: any, b: any, tolerance: number): boolean
	return (a - b).Magnitude <= tolerance
end

--------------------------------------------------------------------------------
-- In third person the beam leaves the gun, not the head
--
-- The viewmodel exists only in first person, so in third person (the default
-- view) there was no muzzle to read and the shot fell back to the origin the
-- server was told about: the head. The server draws everyone else's beam from
-- the welded gun's muzzle (ShotResolver.muzzlePosition); the shooter's own
-- screen has to agree with it.
--------------------------------------------------------------------------------

heading("Third person: the beam starts at the gun")

do
	boot("desktop")
	local player = Env.service("Players").LocalPlayer
	Env.load("src/client/ClientState").init()
	local VFXController = Env.load("src/client/Controllers/VFXController")
	VFXController.init()
	VFXController.start()

	local character = makeCharacter("Rifle", CF.new(10, 5, -20))
	player.Character = character

	local gun = character:FindFirstChildWhichIsA("Model")
	local muzzleAt = Env.load("src/shared/GunModelFactory").getMuzzle(gun).WorldPosition
	local head = V3.new(0, 5, 0)

	VFXController.playLocalShot("Rifle", head, V3.new(0, 0, -1))

	local folder = Env.workspace():FindFirstChild("LaserTagVFX")
	local beams = livingBeams(folder)
	check(#beams == 1, `one shot draws one beam (got {#beams})`)
	if beams[1] then
		local start = beams[1].CFrame.Position
		check(
			near(start, muzzleAt, 0.05),
			`the beam starts at the gun's muzzle, not the head (starts {tostring(start)}, muzzle {tostring(muzzleAt)})`
		)
	end

	-- With no gun to draw from (a hub spawn, a rebuild in flight) the shot still
	-- has to come from somewhere sensible.
	for _, child in folder:GetChildren() do
		local beam = child:FindFirstChildOfClass("Beam")
		if beam then
			beam.Enabled = false
		end
	end
	player.Character = makeCharacter(nil)
	VFXController.playLocalShot("Rifle", head, V3.new(0, 0, -1))
	local fallback = livingBeams(folder)
	check(
		#fallback == 1 and near(fallback[1].CFrame.Position, head, 0.05),
		"with no gun on the character the beam falls back to the shot origin"
	)

	VFXController.stop()
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")
check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} vfx check(s) failed`, 0)
end

print("  All vfx checks passed.")
