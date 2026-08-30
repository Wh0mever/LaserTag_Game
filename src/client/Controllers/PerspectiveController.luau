--!nonstrict
--[[
	PerspectiveController.luau
	Which shoulder the player is looking over. One value, one signal, and no
	Roblox API of its own — every module that has to change behaviour between
	first and third person asks here rather than each keeping its own copy.

	Four things move together, and all four are wrong if any one of them is
	missed:

	  * the camera            MouseLockController, which owns CameraMode and the
	                          zoom distances
	  * the player's body     CharacterVisualsController hides it in first
	                          person and must not in third
	  * the viewmodel         ViewmodelController's gun is a first-person prop
	                          parented to the camera; in third person the real
	                          welded gun on the character is what is seen
	  * where a shot comes    WeaponClient — see below, this is the one that
	                          from                 breaks the game rather than the look

	THE SHOOTING PART. The server accepts a shot only if the claimed origin is
	within WeaponConfig.MAX_ORIGIN_DEVIATION of where it believes the player's
	eyes are. A third-person camera sits about ten studs behind the head, so
	sending the camera position — which is what a first-person client can get
	away with — would have every single shot rejected as origin spoofing. The
	shot is therefore fired from the head toward whatever the camera's crosshair
	is over, in both modes.

	Nothing here is authoritative. The perspective is a client-local preference
	stored on the profile like sensitivity; the server neither knows nor cares
	which one is set, and no shot resolves differently because of it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local InputController = require(script.Parent.InputController)
local SettingsConfig = require(Shared.Config.SettingsConfig)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local PerspectiveController = {}
-- Before MouseLockController (5), which reads this to pick a camera mode.
PerspectiveController.Priority = 4

local SETTING_ID = "Perspective"

PerspectiveController.FIRST = "First"
PerspectiveController.THIRD = "Third"

-- Third-person framing. Pinned to a single distance rather than a range for the
-- same reason first person is: a zoom the player can scroll is a zoom that
-- silently changes how far they can see round a corner, which is not a setting
-- this game wants to offer by accident.
PerspectiveController.THIRD_ZOOM = 12
PerspectiveController.FIRST_ZOOM = 0.5

PerspectiveController.Changed = Signal.new()

local trove = Trove.new()
local current = SettingsConfig.get(SETTING_ID).default

function PerspectiveController.get(): string
	return current
end

function PerspectiveController.isFirstPerson(): boolean
	return current == PerspectiveController.FIRST
end

--[[
	The zoom distance for the current perspective. MouseLockController pins both
	CameraMinZoomDistance and CameraMaxZoomDistance to this.
]]
function PerspectiveController.zoom(): number
	return if current == PerspectiveController.FIRST
		then PerspectiveController.FIRST_ZOOM
		else PerspectiveController.THIRD_ZOOM
end

--[[
	Adopt `mode`. Anything unrecognised resolves to the configured default rather
	than being ignored, so a corrupt profile cannot leave the camera in a state
	no option in the menu corresponds to.

	Fires Changed only on an actual change: the settings panel re-applies every
	setting on every push, and rebuilding the viewmodel on each of those would
	throw away a reload animation mid-play.
]]
function PerspectiveController.set(mode: any)
	local resolved = SettingsConfig.clamp(SETTING_ID, mode)
	if resolved == current then
		return
	end

	current = resolved
	PerspectiveController.Changed:Fire(current)
end

--[[
	Flip to the other perspective and remember it, which is what the hotkey does.

	Stored, not just applied: a view that reverts on the next join is a setting
	the player has to find again every session, and this one is reached mid-fight
	rather than from a menu.
]]
function PerspectiveController.toggle()
	local other = if PerspectiveController.isFirstPerson()
		then PerspectiveController.THIRD
		else PerspectiveController.FIRST

	ClientState.applySetting(SETTING_ID, other)
	ClientState.saveSettings()
end

function PerspectiveController.init()
	ClientState.init()
	PerspectiveController.set(SettingsConfig.sanitize(ClientState.settings)[SETTING_ID])

	trove:Add(InputController.PerspectiveToggled:Connect(PerspectiveController.toggle))
end

function PerspectiveController.stop()
	trove:Clean()
	current = SettingsConfig.get(SETTING_ID).default
end

return PerspectiveController
