--!nonstrict
--[[
	SettingsController.luau
	Turns the three stored settings into the properties that actually do
	something, and keeps them applied.

		Sensitivity   -> UserInputService.MouseDeltaSensitivity
		Volume        -> the LaserTagSFX SoundGroup
		FieldOfView   -> CameraController.setFieldOfView

	Every one is a client-local property. None of them is sent to the server as
	anything the server acts on — SettingsService only remembers the numbers — so
	a player cannot buy an advantage here. Sensitivity in particular is a raw
	input scale: it changes how far the view turns per unit of mouse movement and
	nothing about what a shot does when it lands.

	Applied on every SettingsChanged rather than only at boot, because the panel
	fires that signal as a slider moves. That is what makes a sensitivity slider
	usable at all: you have to feel the change while dragging it, not after
	closing a menu.

	The sound group does not exist until VFXController.start() builds it, and
	controller start order is not something this module should depend on, so the
	volume is re-applied on a short retry until the group appears.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local CameraController = require(script.Parent.CameraController)
local ClientState = require(script.Parent.Parent.ClientState)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Trove = require(Shared.Util.Trove)
local VFXSound = require(script.Parent.VFX.VFXSound)

local SettingsController = {}
-- After CameraController and VFXController, whose instances this writes into.
SettingsController.Priority = 40

-- How long to keep looking for the SoundGroup before giving up. Generous: the
-- cost of waiting is a few frames at the wrong volume, and the cost of giving up
-- too early is a volume setting that silently does nothing for the session.
local SOUND_GROUP_TIMEOUT = 10
local SOUND_GROUP_RETRY = 0.25

local trove = Trove.new()
local soundGroupResolved = false

local function applyVolume(volume: number): boolean
	local group = VFXSound.getGroup()
	if not group then
		return false
	end

	group.Volume = volume
	return true
end

--[[
	Push every setting at the thing that implements it.

	Values come from ClientState, which sanitises on arrival and on change, so
	they are already in range — the clamp here is for the case where this is
	called before any profile has landed.
]]
function SettingsController.apply(settings: any)
	local resolved = SettingsConfig.sanitize(settings or ClientState.settings)

	UserInputService.MouseDeltaSensitivity = resolved.Sensitivity
	CameraController.setFieldOfView(resolved.FieldOfView)

	if applyVolume(resolved.Volume) then
		soundGroupResolved = true
	end
end

function SettingsController.init()
	ClientState.init()

	trove:Add(ClientState.SettingsChanged:Connect(function(settings)
		SettingsController.apply(settings)
	end))
end

function SettingsController.start()
	SettingsController.apply(ClientState.settings)

	-- VFXController builds the SoundGroup in its own start(); if it has not run
	-- yet, keep trying until it has. Stops at the first success, so the common
	-- case costs one extra frame.
	if soundGroupResolved then
		return
	end

	task.spawn(function()
		local waited = 0
		while not soundGroupResolved and waited < SOUND_GROUP_TIMEOUT do
			task.wait(SOUND_GROUP_RETRY)
			waited += SOUND_GROUP_RETRY
			if applyVolume(SettingsConfig.sanitize(ClientState.settings).Volume) then
				soundGroupResolved = true
			end
		end
	end)
end

function SettingsController.stop()
	trove:Clean()
	soundGroupResolved = false
end

return SettingsController
