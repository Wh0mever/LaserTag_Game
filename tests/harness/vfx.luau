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
local realTask = require("@lune/task")
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

-- Emit exists only while a game runs, and nothing here draws particles.
roblox.implementMethod("ParticleEmitter", "Emit", function() end)

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
	-- Runtime-only properties the data model has no default for.
	root.AssemblyLinearVelocity = V3.zero
	root.Parent = character
	character.PrimaryPart = root

	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.FloorMaterial = roblox.Enum.Material.Plastic
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
-- Sparks and flashes fly out of the surface, not along it
--
-- A ParticleEmitter throws particles out of its TOP face unless told otherwise.
-- Both emitters here sit on an attachment whose -Z axis is the useful way (down
-- the beam for the flash, off the wall for the sparks), so left at the default
-- the muzzle flash sprayed sideways and the impact burst skimmed the surface.
-- The muzzle itself belongs at the end of the barrel: half way along it, the
-- flash appeared inside the gun.
--------------------------------------------------------------------------------

heading("Emitters point the right way")

do
	boot("desktop")
	local VFXController = Env.load("src/client/Controllers/VFXController")
	Env.load("src/client/ClientState").init()
	VFXController.init()
	VFXController.start()

	local folder = Env.workspace():FindFirstChild("LaserTagVFX")
	local emitters, wrong = 0, 0
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("ParticleEmitter") then
			emitters += 1
			if descendant.EmissionDirection ~= roblox.Enum.NormalId.Front then
				wrong += 1
			end
		end
	end
	check(emitters > 0, "the effects own particle emitters")
	check(wrong == 0, `every emitter fires out of its front face, along -Z ({wrong} of {emitters} do not)`)

	VFXController.stop()
end

heading("The muzzle sits at the barrel tip")

do
	boot("desktop")
	local GunModelFactory = Env.load("src/shared/GunModelFactory")
	local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")

	for _, weaponId in WeaponConfig.Order do
		local model = GunModelFactory.build(weaponId, nil)
		-- The most forward point of any piece of the gun: parts are laid out
		-- around the Handle at the origin, and forward is -Z.
		local tip = math.huge
		for _, part in partsOf(model) do
			tip = math.min(tip, part.CFrame.Position.Z - part.Size.Z / 2)
		end
		local muzzleZ = GunModelFactory.getMuzzle(model).Position.Z
		check(
			math.abs(muzzleZ - tip) <= 0.05,
			`{weaponId}: the muzzle is at the end of the barrel (muzzle {muzzleZ}, tip {tip})`
		)
	end
end

--------------------------------------------------------------------------------
-- A scorch mark only goes on something solid
--
-- Every impact used to leave a dark slab, and the slab is painted flat against
-- "the surface" — which for a body hit is a moving player, and for another
-- player's miss is empty air at the end of the range. Both left black squares
-- hanging in mid-air. Sparks and the flash still belong to a body hit; the mark
-- does not.
--------------------------------------------------------------------------------

heading("Scorch marks stay on walls")

-- Freshly booted VFX plus the two things a ray can find.
local function vfxSession()
	boot("desktop")
	local player = Env.service("Players").LocalPlayer
	Env.load("src/client/ClientState").init()
	local VFXController = Env.load("src/client/Controllers/VFXController")
	VFXController.init()
	VFXController.start()
	player.Character = makeCharacter(nil)

	local wall = roblox.Instance.new("Part")
	wall.Name = "Wall"
	wall.Parent = Env.workspace()

	local enemy = roblox.Instance.new("Model")
	enemy.Name = "Enemy"
	local enemyHumanoid = roblox.Instance.new("Humanoid")
	enemyHumanoid.Parent = enemy
	local torso = roblox.Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Parent = enemy
	enemy.Parent = Env.workspace()

	return VFXController, wall, torso, Env.workspace():FindFirstChild("LaserTagVFX")
end

-- The impact slabs that are lit and whether a mark is showing on them.
local function impactsOf(folder: any): { { scorch: boolean, facing: any } }
	local found = {}
	for _, child in folder:GetChildren() do
		local light = child:FindFirstChildOfClass("PointLight")
		if child.Name:match("^Impact") and light and light.Enabled then
			table.insert(found, { scorch = child.Transparency < 1, facing = child.CFrame.LookVector })
		end
	end
	return found
end

do
	local muzzleAt = V3.new(0, 5, 0)
	local color = roblox.Color3.new(0, 1, 1)

	-- Another player's shot into a wall: the mark goes on, facing out of it.
	local VFX, wall, torso, folder = vfxSession()
	local probes = {}
	Env.raycast = function(origin, direction)
		table.insert(probes, { origin = origin, direction = direction })
		return { Instance = wall, Position = V3.new(0, 5, -30), Normal = V3.new(1, 0, 0), Distance = 1 }
	end
	VFX.playRemoteShot(2, "Rifle", muzzleAt, V3.new(0, 5, -30), color)
	local hits = impactsOf(folder)
	check(#hits == 1, `a shot into a wall bursts once (got {#hits})`)
	if hits[1] then
		check(hits[1].scorch, "a shot into a wall leaves a scorch mark")
		check(hits[1].facing:Dot(V3.new(1, 0, 0)) > 0.99, "the mark faces out of the wall along its normal")
	end
	check(#probes == 1, `the surface is probed once (got {#probes})`)
	if probes[1] then
		-- The probe has to cover the reported hit point, or it would find a
		-- different surface than the one the server hit.
		local along = probes[1].direction.Unit
		local toHit = V3.new(0, 5, -30) - probes[1].origin
		local across = (toHit - along * toHit:Dot(along)).Magnitude
		check(
			across < 0.01 and toHit:Dot(along) > 0 and toHit.Magnitude < probes[1].direction.Magnitude,
			"the probe spans the hit point"
		)
	end
	VFX.stop()

	-- Into a player: sparks, no mark.
	VFX, wall, torso, folder = vfxSession()
	Env.raycast = function()
		return { Instance = torso, Position = V3.new(0, 5, -30), Normal = V3.new(0, 0, 1), Distance = 1 }
	end
	VFX.playRemoteShot(2, "Rifle", muzzleAt, V3.new(0, 5, -30), color)
	hits = impactsOf(folder)
	check(#hits == 1 and not hits[1].scorch, "a shot into a player sparks but leaves no mark")
	VFX.stop()

	-- Nothing under the reported point: a player who has already moved on. The
	-- sparks still tell the viewer someone was hit; there is no wall for a mark.
	VFX, wall, torso, folder = vfxSession()
	Env.raycast = nil
	VFX.playRemoteShot(2, "Rifle", muzzleAt, V3.new(0, 5, -30), color)
	hits = impactsOf(folder)
	check(#hits == 1 and not hits[1].scorch, "a hit on something that has moved sparks without a mark")
	VFX.stop()

	-- The end of the range: nothing was hit at all.
	VFX, wall, torso, folder = vfxSession()
	Env.raycast = function()
		return { Instance = wall, Position = V3.new(0, 5, -400), Normal = V3.new(0, 0, 1), Distance = 1 }
	end
	VFX.playRemoteShot(2, "Rifle", muzzleAt, V3.new(0, 5, -400), color)
	check(#livingBeams(folder) == 1, "a miss still draws its beam")
	check(#impactsOf(folder) == 0, "a miss at the end of the range bursts nowhere")
	VFX.stop()

	-- The local player's own shots.
	VFX, wall, torso, folder = vfxSession()
	Env.raycast = function()
		return { Instance = wall, Position = V3.new(0, 5, -20), Normal = V3.new(0, 0, 1), Distance = 20 }
	end
	VFX.playLocalShot("Rifle", muzzleAt, V3.new(0, 0, -1))
	hits = impactsOf(folder)
	check(#hits == 1 and hits[1].scorch, "your own shot into a wall leaves a mark")
	VFX.stop()

	VFX, wall, torso, folder = vfxSession()
	Env.raycast = function()
		return { Instance = torso, Position = V3.new(0, 5, -20), Normal = V3.new(0, 0, 1), Distance = 20 }
	end
	VFX.playLocalShot("Rifle", muzzleAt, V3.new(0, 0, -1))
	hits = impactsOf(folder)
	check(#hits == 1 and not hits[1].scorch, "your own shot into a player sparks but leaves no mark")
	VFX.stop()

	Env.raycast = nil
end

--------------------------------------------------------------------------------
-- The hitmarker punches outward
--
-- The four bars sit at fixed pixel offsets from the middle of their frame, and
-- the frame was what grew. A frame anchored at its centre grows around that
-- centre, so nothing the bars are positioned from ever moved: the "punch" was
-- an animation of a property that had no visible effect. The distance from the
-- crosshair is what has to change.
--------------------------------------------------------------------------------

heading("Hitmarker")

do
	boot("desktop")
	local player = Env.service("Players").LocalPlayer
	Env.load("src/client/ClientState").init()
	local VFXController = Env.load("src/client/Controllers/VFXController")
	local ScreenEffects = Env.load("src/client/Controllers/VFX/ScreenEffects")
	local Constants = Env.load("src/shared/Constants")
	VFXController.init()
	VFXController.start()

	VFXController.showHitmarker(false, false)
	local gui = player.PlayerGui:FindFirstChild("CombatFeedback")
	local bars = {}
	for _, descendant in gui:GetDescendants() do
		if descendant.Name:match("^Bar%d$") then
			table.insert(bars, descendant)
		end
	end
	check(#bars == 4, `the hitmarker has four bars (got {#bars})`)

	local function radiusOf(bar: any): number
		local position = bar.Position
		return math.sqrt(position.X.Offset ^ 2 + position.Y.Offset ^ 2)
	end

	local now = os.clock()
	ScreenEffects.step(now)
	local start = radiusOf(bars[1])
	ScreenEffects.step(now + Constants.HITMARKER_DURATION * 0.8)
	local late = radiusOf(bars[1])
	check(late - start >= 3, `the bars move away from the crosshair as it fades (from {start} to {late})`)

	-- Symmetric: every bar goes out by the same amount, in its own direction.
	local same = true
	for _, bar in bars do
		same = same and math.abs(radiusOf(bar) - late) < 0.01
	end
	check(same, "all four bars are at the same distance from the centre")

	VFXController.stop()
end

--------------------------------------------------------------------------------
-- The crosshair shows the NEXT shot's spread
--
-- The server rolls a shot's cone from that shot's place in the spray. The
-- bloom used to read the place of the shot already fired, so a Lance (pin
-- accurate on its first round, ten times looser on the second) showed a
-- perfect point in the instant after firing, exactly when the next round would
-- go wide. What the player needs to see is what pulling the trigger now costs.
--------------------------------------------------------------------------------

heading("Crosshair bloom")

do
	boot("desktop")
	Env.load("src/client/ClientState").init()
	local RecoilController = Env.load("src/client/Controllers/RecoilController")
	local SprayPatterns = Env.load("src/shared/Config/SprayPatterns")
	local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
	RecoilController.init()

	local lance = WeaponConfig.get("Lance")
	check(
		RecoilController.getBloomDeg("Lance") == lance.baseSpreadDeg,
		`a weapon that has not fired rests at its base spread (got {RecoilController.getBloomDeg("Lance")})`
	)

	RecoilController.onShot("Lance", os.clock())
	local second = SprayPatterns.getServerSpreadDeg("Lance", 2)
	check(
		math.abs(RecoilController.getBloomDeg("Lance") - second) < 1e-6,
		`right after a Lance shot the crosshair shows the second round's cone, {second} (got {RecoilController.getBloomDeg(
			"Lance"
		)})`
	)

	-- Hold the rifle. Eight rounds is the last of the second tier, so the
	-- crosshair has to already be showing the third.
	local rifle = WeaponConfig.get("Rifle")
	for shot = 1, 8 do
		RecoilController.onShot("Rifle", os.clock() - (9 - shot) * 0.001)
	end
	local expected = math.max(rifle.baseSpreadDeg, SprayPatterns.getServerSpreadDeg("Rifle", 9))
	check(
		expected > SprayPatterns.getServerSpreadDeg("Rifle", 8),
		"the ninth rifle round really is in a wider tier than the eighth"
	)
	check(
		math.abs(RecoilController.getBloomDeg("Rifle") - expected) < 1e-6,
		`after eight rifle rounds the crosshair shows the ninth's cone, {expected} (got {RecoilController.getBloomDeg(
			"Rifle"
		)})`
	)

	-- Stop firing and it tightens again, without waiting for another shot.
	RecoilController.resetSpray()
	RecoilController.onShot("Lance", os.clock() - lance.sprayResetTime - 1)
	check(
		RecoilController.getBloomDeg("Lance") == lance.baseSpreadDeg,
		"the crosshair tightens once the spray reset time has passed"
	)
end

--------------------------------------------------------------------------------
-- Recoil is softened for a thumb, not for a touchscreen
--
-- The softening exists because correcting recoil with a thumb on glass is
-- slower than with a wrist. It was keyed on the device having a touchscreen at
-- all, so a touchscreen laptop aimed with its mouse got a weaker kick than
-- every desktop player. What matters is the input that fired the shot.
--------------------------------------------------------------------------------

heading("Touch recoil follows the input that fired")

do
	local function firstKickFor(device: string, lastInput: any?): number
		boot(device)
		Env.lastInputType = lastInput
		Env.load("src/client/ClientState").init()
		local CameraController = Env.load("src/client/Controllers/CameraController")
		local RecoilController = Env.load("src/client/Controllers/RecoilController")
		RecoilController.init()
		CameraController.resetRecoil()
		RecoilController.onShot("Rifle", os.clock())
		return (CameraController.getRecoilOffset())
	end

	local Enum = roblox.Enum
	local full = firstKickFor("desktop", nil)
	check(full > 0, "a rifle shot kicks the view")

	local phone = firstKickFor("phone", nil)
	check(phone < full * 0.9, `a phone player firing with a thumb gets the softened kick ({phone} against {full})`)

	local laptopMouse = firstKickFor("touchLaptop", Enum.UserInputType.MouseButton1)
	check(
		math.abs(laptopMouse - full) < 1e-6,
		`a touchscreen laptop firing with its mouse gets the full kick ({laptopMouse} against {full})`
	)

	local laptopTouch = firstKickFor("touchLaptop", Enum.UserInputType.Touch)
	check(
		math.abs(laptopTouch - phone) < 1e-6,
		`the same laptop fired by touch gets the phone's kick ({laptopTouch} against {phone})`
	)
end

--------------------------------------------------------------------------------
-- Mashing the view button saves once
--
-- Every tap of the view button applied the new perspective AND sent the whole
-- settings table to the server. The save remote is rate limited and every
-- refused call counts against the sender, so a player playing with the button
-- could talk themselves into a kick. The view changes at once; the save waits
-- for the taps to stop.
--------------------------------------------------------------------------------

heading("View button saves once")

do
	boot("desktop")
	local ClientState = Env.load("src/client/ClientState")
	ClientState.init()
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	Perspective.init()
	-- What turns the stored setting into the live perspective.
	Env.load("src/client/Controllers/SettingsController").init()

	local saves = {}
	ClientState.saveSettings = function()
		table.insert(saves, ClientState.settings.Perspective)
	end

	local before = Perspective.get()
	for _ = 1, 5 do
		Perspective.toggle()
		Env.advance(0.2)
	end
	check(Perspective.get() ~= before, "five taps leave the view flipped (odd number of toggles)")
	check(#saves == 0, `nothing is sent while the button is still being pressed (sent {#saves})`)

	Env.advance(1.0)
	check(#saves == 0, "nothing is sent before the taps have been quiet for a moment")

	Env.advance(1.0)
	check(#saves == 1, `one save goes out once they stop (sent {#saves})`)
	check(saves[1] == Perspective.get(), "and it carries the perspective the player ended on")

	-- A lone tap still saves: the choice must survive to the next session.
	Perspective.toggle()
	Env.advance(3)
	check(#saves == 2 and saves[2] == Perspective.get(), "a single tap is saved too")
end

--------------------------------------------------------------------------------
-- The death camera stays inside the room
--
-- It parks a fixed nine studs behind and four and a half above whoever it is
-- watching, and nothing checked what is there. Killed in a corridor, the view
-- was inside the ceiling; killed by someone standing against a wall, inside
-- the wall. The eye is pulled in toward the target until it clears whatever
-- is in the way.
--------------------------------------------------------------------------------

heading("Death camera occlusion")

do
	-- Where the camera ends up after the death view has had time to settle.
	local function deathEyeDistance(wallDistance: number?): (number, any)
		boot("desktop")
		local player = Env.service("Players").LocalPlayer
		Env.load("src/client/ClientState").init()
		local ClientState = Env.load("src/client/ClientState")
		local CameraController = Env.load("src/client/Controllers/CameraController")
		CameraController.init()

		local character = makeCharacter(nil)
		character.PrimaryPart.CFrame = CF.new(0, 10, 0)
		player.Character = character
		local focus = V3.new(0, 11.5, 0)

		local seen = nil
		Env.raycast = function(origin, direction, params)
			if not wallDistance or (origin - focus).Magnitude > 0.01 then
				return nil
			end
			seen = params
			return {
				Instance = character.PrimaryPart,
				Position = origin + direction.Unit * wallDistance,
				Normal = -direction.Unit,
				Distance = wallDistance,
			}
		end

		ClientState.Died:Fire(nil, 3)
		check(CameraController.isDeathCamActive(), "the death view starts")
		for _ = 1, 400 do
			Env.stepRender()
		end

		local eye = Env.workspace().CurrentCamera.CFrame.Position
		return (eye - focus).Magnitude, seen
	end

	local open = deathEyeDistance(nil)
	check(open > 9, `with nothing in the way the camera sits back at its full distance (got {open})`)

	local wall, params = deathEyeDistance(5)
	check(
		math.abs(wall - 4.5) < 0.05,
		`a wall five studs away pulls the camera in to just short of it (got {wall}, wanted 4.5)`
	)
	check(params ~= nil and #params.FilterDescendantsInstances > 0, "the probe ignores the bodies it is looking at")

	local tight = deathEyeDistance(1)
	check(
		math.abs(tight - 1.5) < 0.05,
		`a wall right behind the target still leaves a view of it, no closer than 1.5 studs (got {tight})`
	)
	Env.raycast = nil
end

--------------------------------------------------------------------------------
-- The first-person gun stays out of walls
--
-- The viewmodel is real geometry in the world, drawn with the same depth buffer
-- as the map. At full size the rifle's barrel reached four studs in front of
-- the camera and the Lance's five, so standing against a wall pushed the gun
-- through it. Shrunk about its pivot and brought in by the same factor it is
-- the same picture on screen, and nothing in it is more than a stud or two from
-- the eye.
--------------------------------------------------------------------------------

heading("Viewmodel geometry")

do
	boot("desktop")
	local player = Env.service("Players").LocalPlayer
	local ClientState = Env.load("src/client/ClientState")
	ClientState.init()
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Viewmodel = Env.load("src/client/Controllers/ViewmodelController")
	local Recoil = Env.load("src/client/Controllers/RecoilController")
	local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
	Perspective.set(Perspective.FIRST)
	Recoil.init()
	Viewmodel.init()

	player.Character = makeCharacter(nil)
	ClientState.isDead = false
	player:SetAttribute("InMatch", "Dust")
	Viewmodel.start()

	-- Farthest any corner of the gun gets from the camera, which sits at the origin.
	local function reach(model: any): number
		local farthest = 0
		for _, part in partsOf(model) do
			local half = part.Size / 2
			for _, sx in { -1, 1 } do
				for _, sy in { -1, 1 } do
					for _, sz in { -1, 1 } do
						local corner = part.CFrame * V3.new(half.X * sx, half.Y * sy, half.Z * sz)
						farthest = math.max(farthest, corner.Magnitude)
					end
				end
			end
		end
		return farthest
	end

	-- Real seconds: the raise animation runs off os.clock. Each weapon is given
	-- time to finish it, so the pose measured is the pose at rest.
	local function settled(weaponId: string): any
		Viewmodel.setWeapon(weaponId)
		realTask.wait(0.4)
		local errors = Env.stepRender()
		check(#errors == 0, `the viewmodel renders cleanly{if errors[1] then ": " .. errors[1].err else ""}`)
		return Viewmodel.getModel()
	end

	local expectedDirection = {
		Rifle = V3.new(0.95, -0.95, -1.15).Unit,
		Pistol = V3.new(0.78, -0.82, -1.0).Unit,
	}
	local holds = {}

	for _, weaponId in { "Rifle", "Pistol", "Lance" } do
		local model = settled(weaponId)
		check(model ~= nil, `{weaponId} has a viewmodel in first person`)
		if not model then
			continue
		end

		local farthest = reach(model)
		check(farthest <= 1.75, `{weaponId} reaches no further than 1.75 studs from the camera (reaches {farthest})`)

		local handle = model.PrimaryPart.CFrame.Position
		-- Where the gun sits in the units it was designed in, whatever it was scaled to.
		holds[weaponId] = handle / model:GetScale()

		if expectedDirection[weaponId] then
			check(
				handle.Unit:Dot(expectedDirection[weaponId]) > 0.9999,
				`{weaponId} sits in the same place on screen as before (direction {tostring(handle.Unit)})`
			)
		end

		-- The beam of a local shot starts here, so it must be the barrel tip of
		-- the shrunk gun and not of the full-size one.
		local tip = Viewmodel.getMuzzlePosition()
		local barrelTip = model.PrimaryPart.CFrame
			* V3.new(0, 0, WeaponConfig.get(weaponId).muzzleOffset.z * model:GetScale())
		check(
			tip ~= nil and (tip - barrelTip).Magnitude < 0.01,
			`{weaponId}'s muzzle is at the barrel tip of the gun on screen (at {tostring(tip)}, tip {tostring(barrelTip)})`
		)
	end

	-- The longer gun is held further back than the generic pose (0.9, -0.9, -1.1),
	-- or its stock ends up in the near plane.
	if holds.Lance then
		check(holds.Lance.Z < -1.2, `the Lance is held further back than the default pose (hold z {holds.Lance.Z})`)
	end

	-- A reload dips the gun by the same proportion of its distance as before.
	Viewmodel.setWeapon("Rifle")
	realTask.wait(0.4)
	Env.stepRender()
	local restY = Viewmodel.getModel().PrimaryPart.CFrame.Position.Y
	Viewmodel.playReload(0.5)
	realTask.wait(0.25)
	Env.stepRender()
	local dipped = Viewmodel.getModel().PrimaryPart.CFrame.Position
	local proportion = (restY - dipped.Y) / -dipped.Z
	check(
		math.abs(proportion - 0.55 / 1.15) < 0.03,
		`the reload dip keeps its proportion on screen (dropped {proportion} of the distance, wanted {0.55 / 1.15})`
	)
end

--------------------------------------------------------------------------------
-- The first-person beam and flash keep their size on screen
--
-- Shrinking the gun brings its muzzle to a stud or so from the eye. A beam a
-- quarter of a stud wide and a half-stud flash, unchanged, would then fill a
-- quarter of the view for a tenth of a second instead of the sliver they were
-- at four studs. The near end of the effect scales with the gun; the far end
-- of a beam, which is far away either way, does not.
--------------------------------------------------------------------------------

heading("First-person beam scale")

do
	boot("desktop")
	local player = Env.service("Players").LocalPlayer
	local ClientState = Env.load("src/client/ClientState")
	ClientState.init()
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Viewmodel = Env.load("src/client/Controllers/ViewmodelController")
	local VFXController = Env.load("src/client/Controllers/VFXController")
	local EffectPool = Env.load("src/client/Controllers/VFX/EffectPool")
	local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
	Perspective.set(Perspective.FIRST)
	Env.load("src/client/Controllers/RecoilController").init()
	Viewmodel.init()
	VFXController.init()
	VFXController.start()

	player.Character = makeCharacter(nil)
	ClientState.isDead = false
	player:SetAttribute("InMatch", "Dust")
	Viewmodel.start()
	Env.stepRender()

	local scale = Viewmodel.getModel():GetScale()
	local width = WeaponConfig.get("Rifle").beamWidth
	local folder = Env.workspace():FindFirstChild("LaserTagVFX")

	local function largestFlash(part: any): number
		local emitter = part:FindFirstChildWhichIsA("ParticleEmitter", true)
		local largest = 0
		for _, keypoint in emitter.Size.Keypoints do
			largest = math.max(largest, keypoint.Value)
		end
		return largest
	end

	VFXController.playLocalShot("Rifle", V3.new(0, 0, 0), V3.new(0, 0, -1))
	local own = livingBeams(folder)[1]
	check(own ~= nil, "a local shot in first person draws a beam")
	if own then
		local beam = own:FindFirstChildOfClass("Beam")
		check(
			math.abs(beam.Width0 - width * scale) < 1e-4,
			`the beam is thin where it leaves the shrunk gun (near width {beam.Width0}, wanted {width * scale})`
		)
		check(math.abs(beam.Width1 - width * 0.45) < 1e-4, `and unchanged at the far end (far width {beam.Width1})`)
		check(
			math.abs(largestFlash(own) - 0.55 * scale) < 1e-4,
			`the muzzle flash is small in proportion (largest {largestFlash(own)}, wanted {0.55 * scale})`
		)
	end

	-- The pooled part is reused: the next shot, someone else's, must not inherit
	-- the small flash.
	EffectPool.step(os.clock() + 5)
	VFXController.playRemoteShot(2, "Rifle", V3.new(20, 5, 0), V3.new(20, 5, -50), roblox.Color3.new(1, 0, 0))
	local other = livingBeams(folder)[1]
	check(other ~= nil, "another player's shot draws a beam")
	if other then
		local beam = other:FindFirstChildOfClass("Beam")
		check(
			math.abs(beam.Width0 - width) < 1e-4,
			`another player's beam is full width at the muzzle (near width {beam.Width0})`
		)
		check(
			math.abs(largestFlash(other) - 0.55) < 1e-4,
			`and their flash is full size, not the shrunk one left over (largest {largestFlash(other)})`
		)
	end

	VFXController.stop()
end

--------------------------------------------------------------------------------
-- The death card fits a phone
--
-- It was a 420x178 panel in the middle of the screen: on a phone held sideways
-- (640x294 as Roblox reports it) that is over half the view, sitting on top of
-- the very player who just killed you, under a heavy dim. It is now a compact
-- strip pinned to the top edge, over the clock and score, which the death view
-- has no use for.
--------------------------------------------------------------------------------

heading("Death card on a phone")

do
	boot("phone")
	local camera = Env.workspace().CurrentCamera
	camera.ViewportSize = roblox.Vector2.new(640, 294)
	local player = Env.service("Players").LocalPlayer
	local ClientState = Env.load("src/client/ClientState")
	ClientState.init()
	local UIController = Env.load("src/client/UI/UIController")
	local Spectator = Env.load("src/client/Controllers/SpectatorController")
	-- The death view has to be running for the card to say who is being watched.
	Env.load("src/client/Controllers/CameraController").init()
	Spectator.init()
	player.Character = makeCharacter(nil)

	ClientState.isDead = true
	ClientState.Died:Fire(nil, 3)

	local gui = player.PlayerGui:FindFirstChild("Spectator")
	local card = gui and gui:FindFirstChild("Card", true)
	local dim = gui and gui:FindFirstChild("Dim", true)
	check(card ~= nil, "dying puts the card up")

	if card then
		local scale = UIController.computeScale(camera.ViewportSize)
		local limit = card:FindFirstChildOfClass("UISizeConstraint")
		local width = if limit then limit.MaxSize.X else card.Size.X.Offset
		local height = card.Size.Y.Offset

		check(
			height * scale / camera.ViewportSize.Y <= 0.35,
			`the card takes a third of the phone's height at most (takes {height * scale / camera.ViewportSize.Y})`
		)
		check(
			width * scale / camera.ViewportSize.X <= 0.5,
			`and half its width at most (takes {width * scale / camera.ViewportSize.X})`
		)
		check(
			card.AnchorPoint.Y == 0 and card.Position.Y.Scale == 0 and card.Position.Y.Offset >= 0,
			"the card hangs from the top edge, so its top can never be off screen"
		)
		check(dim ~= nil and dim.BackgroundTransparency >= 0.75, "the dim leaves the killer visible")

		local function textOf(name: string): string?
			local label = card:FindFirstChild(name, true)
			return label and label.Text
		end
		check(
			textOf("Countdown") == "3",
			`the countdown starts at the respawn time (shows {tostring(textOf("Countdown"))})`
		)
		check(
			textOf("Killer") == "ВНЕ ИГРЫ",
			`an unattributed death says so (shows {tostring(textOf("Killer"))})`
		)
		local bare = card.Size.Y.Offset

		-- Killed by someone: the card names them and the line under the bar
		-- says the view is theirs.
		local killer = {
			DisplayName = "Nurik",
			UserId = 77,
			Parent = Env.service("Players"),
			GetAttribute = function()
				return "A"
			end,
		}
		Env.service("Players").GetPlayerByUserId = function()
			return killer
		end
		ClientState.Died:Fire(77, 3)

		check(
			textOf("Eyebrow") == "ВАС УБИЛ",
			`a kill is attributed (eyebrow shows {tostring(textOf("Eyebrow"))})`
		)
		check(textOf("Killer") == "NURIK", `the killer is named in capitals (shows {tostring(textOf("Killer"))})`)
		check(
			textOf("Watching") == "НАБЛЮДЕНИЕ: Nurik",
			`and the card says whose view this is (shows {tostring(textOf("Watching"))})`
		)
		check(
			card.Size.Y.Offset > bare and card.Size.Y.Offset * scale / camera.ViewportSize.Y <= 0.35,
			"the line under the bar makes room for itself and the card is still compact"
		)
	end
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
