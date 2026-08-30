--!nonstrict
--[[
	CharacterVisualsController.luau
	Hides the local character from its own camera so first person shows an empty
	view instead of the inside of a torso, and leaves every other player fully
	visible (LocalTransparencyModifier is client-only and per-instance, so this
	never affects what anyone else sees).

	Why every frame: the engine recomputes LocalTransparencyModifier for the
	character each render pass (that is how Roblox's own first-person fade works),
	so a one-shot assignment is overwritten within a frame. The per-frame cost is
	bounded by caching the part list on CharacterAdded and maintaining it from
	DescendantAdded/Removing rather than walking the tree each pass.

	Accessories and the welded third-person gun model attached by
	PlayerService.giveWeapons are descendants of the character, so they are picked
	up by the same cache.

	Hiding pauses whenever the camera is outside the head: during the death
	camera, which watches the killer from behind the body, and for the whole
	match in third person, where the player's own back is the thing they are
	aiming past.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local CameraController = require(script.Parent.CameraController)
local ClientState = require(script.Parent.Parent.ClientState)
local PerspectiveController = require(script.Parent.PerspectiveController)
local Trove = require(Shared.Util.Trove)

local CharacterVisualsController = {}
CharacterVisualsController.Priority = 4

local RENDER_BINDING = "LaserTagCharacterVisuals"
-- Runs after the camera has settled so the hide decision uses this frame's
-- death-camera state rather than the previous frame's.
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 2

local player = Players.LocalPlayer
local trove = Trove.new()
local characterTrove = Trove.new()

local hidden: { Instance } = {}
local hiddenSet: { [Instance]: boolean } = {}
local character: Model? = nil
local applied = false

--[[
	Only BasePart and Decal expose LocalTransparencyModifier. Decals matter
	because a face decal keeps rendering on a fully transparent head part.
]]
local function isHideable(instance: Instance): boolean
	return instance:IsA("BasePart") or instance:IsA("Decal")
end

local function track(instance: Instance)
	if hiddenSet[instance] or not isHideable(instance) then
		return
	end

	hiddenSet[instance] = true
	table.insert(hidden, instance)
end

local function untrack(instance: Instance)
	if not hiddenSet[instance] then
		return
	end

	hiddenSet[instance] = nil
	local index = table.find(hidden, instance)
	if index then
		table.remove(hidden, index)
	end
end

local function setModifier(value: number)
	for index = #hidden, 1, -1 do
		local instance = hidden[index]
		if instance.Parent then
			(instance :: any).LocalTransparencyModifier = value
		else
			untrack(instance)
		end
	end
end

local function onCharacterAdded(newCharacter: Model)
	characterTrove:Clean()
	table.clear(hidden)
	table.clear(hiddenSet)

	character = newCharacter
	applied = false

	for _, descendant in newCharacter:GetDescendants() do
		track(descendant)
	end

	characterTrove:Connect(newCharacter.DescendantAdded, track)
	characterTrove:Connect(newCharacter.DescendantRemoving, untrack)
	characterTrove:Add(function()
		character = nil
	end)
end

local function onRender()
	if not character or character.Parent == nil then
		return
	end

	-- Two reasons to be visible, and they are the same reason: the camera is
	-- outside the head. The death camera watches the killer from behind the
	-- body, and third person watches the player's own back all match.
	if CameraController.isDeathCamActive() or not PerspectiveController.isFirstPerson() then
		if applied then
			-- Restore once, then leave the parts alone so the engine's own fading
			-- still works.
			setModifier(0)
			applied = false
		end
		return
	end

	setModifier(1)
	applied = true
end

function CharacterVisualsController.init()
	ClientState.init()

	trove:Connect(player.CharacterAdded, onCharacterAdded)
	trove:Connect(player.CharacterRemoving, function()
		characterTrove:Clean()
		table.clear(hidden)
		table.clear(hiddenSet)
		applied = false
	end)

	RunService:BindToRenderStep(RENDER_BINDING, RENDER_PRIORITY, onRender)
	trove:Add(function()
		RunService:UnbindFromRenderStep(RENDER_BINDING)
	end)
end

function CharacterVisualsController.start()
	-- The character may already exist when this controller starts (the server
	-- spawns players itself, so CharacterAdded can fire before the client boots).
	local existing = player.Character
	if existing then
		onCharacterAdded(existing)
	end
end

--[[
	The tracked part list, exposed so a viewmodel or spectate controller can
	re-use the same set instead of walking the character again.
]]
function CharacterVisualsController.getHiddenParts(): { Instance }
	return hidden
end

function CharacterVisualsController.stop()
	characterTrove:Clean()
	trove:Clean()
end

return CharacterVisualsController
