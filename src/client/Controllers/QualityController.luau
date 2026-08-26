--!nonstrict
--[[
	QualityController.luau
	Trades looks for frames on devices that need it — locally, per player.

	The lighting rig is built for a desktop: Future technology with soft
	shadows, an Atmosphere, bloom and colour correction. That stack is expensive
	on a phone, and this is a shooter where the player who renders a frame first
	wins the duel. A pretty 24fps loses to a plain 60.

	Every change here is written on the client, so it affects this player only
	and never replicates. Nobody else's game gets uglier because one player is
	on a weak device, and the server has no idea any of this happened.

	The profile is chosen from what the device tells us rather than from a
	benchmark: a benchmark costs the first seconds of a match to measure, and
	those are the seconds a player is deciding whether to stay.
]]

local Lighting = game:GetService("Lighting")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Trove = require(Shared.Util.Trove)

local QualityController = {}
QualityController.Priority = 5

-- Below this width a device is treated as a phone rather than a tablet. It is
-- the same breakpoint the UI uses to switch to its compact layout.
local SMALL_VIEWPORT_WIDTH = 600

local trove = Trove.new()
local currentProfile = "high"

--------------------------------------------------------------------------------
-- Profiles
--------------------------------------------------------------------------------

local function postEffects(): { Instance }
	local found = {}
	for _, child in Lighting:GetChildren() do
		if child:IsA("PostEffect") or child:IsA("Atmosphere") then
			table.insert(found, child)
		end
	end
	return found
end

local function applyHigh()
	Lighting.GlobalShadows = true
	for _, effect in postEffects() do
		if effect:IsA("PostEffect") then
			effect.Enabled = true
		end
	end
end

local function applyLow()
	-- Shadows are the single biggest cost in the Future pipeline, and in a
	-- neon-lit arena they carry very little of the readability.
	Lighting.GlobalShadows = false

	for _, effect in postEffects() do
		if effect:IsA("BloomEffect") then
			-- Bloom stays: it is what makes the lasers and neon read as glowing,
			-- so losing it would change what the game looks like rather than how
			-- smoothly it runs. It is narrowed instead.
			effect.Size = math.min(effect.Size, 12)
			effect.Intensity = math.min(effect.Intensity, 0.45)
		elseif effect:IsA("PostEffect") then
			effect.Enabled = false
		end
	end
end

--------------------------------------------------------------------------------
-- Detection
--------------------------------------------------------------------------------

local function isLowEndDevice(): boolean
	-- A touch device with no keyboard is a phone or tablet. Desktop players who
	-- happen to have a touchscreen still have a keyboard, so they keep the full
	-- rig.
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return true
	end

	local camera = Workspace.CurrentCamera
	if camera and camera.ViewportSize.X < SMALL_VIEWPORT_WIDTH then
		return true
	end

	return false
end

local function refresh()
	local profile = if isLowEndDevice() then "low" else "high"
	if profile == currentProfile then
		return
	end

	currentProfile = profile
	if profile == "low" then
		applyLow()
	else
		applyHigh()
	end
end

--------------------------------------------------------------------------------
-- Public
--------------------------------------------------------------------------------

function QualityController.getProfile(): string
	return currentProfile
end

--[[
	Force a profile, for a settings toggle or for testing. Passing nil returns
	control to device detection.
]]
function QualityController.setProfile(profile: string?)
	if profile == nil then
		currentProfile = ""
		refresh()
		return
	end

	currentProfile = profile
	if profile == "low" then
		applyLow()
	else
		applyHigh()
	end
end

function QualityController.init()
	-- Start pessimistic on touch devices so the first frame is already cheap,
	-- rather than rendering one expensive frame and then correcting.
	currentProfile = ""
	refresh()
end

function QualityController.start()
	local camera = Workspace.CurrentCamera
	if camera then
		-- A phone rotating between portrait and landscape changes the viewport,
		-- and so does a desktop window being resized onto a second monitor.
		trove:Add(camera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh))
	end

	trove:Add(Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		local newCamera = Workspace.CurrentCamera
		if newCamera then
			trove:Add(newCamera:GetPropertyChangedSignal("ViewportSize"):Connect(refresh))
		end
		refresh()
	end))
end

function QualityController.stop()
	trove:Clean()
end

return QualityController
