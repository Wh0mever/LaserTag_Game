--!nonstrict
--[[
	MouseLockController.luau
	Owns the cursor. Two inputs decide whether the mouse is free:

	  * the Right Ctrl toggle published by InputController.MouseUnlockToggled
	  * whether any menu is open (UIController.MenuVisibilityChanged)

	Either one frees the cursor; the cursor re-locks only when both are clear.

	Ownership note: this controller is the ONLY place that writes
	`player.CameraMode`, `UserInputService.MouseBehavior` and `MouseIconEnabled`.
	CameraController owns workspace.CurrentCamera instead. The split matters
	because Roblox's own camera module force-locks the mouse every frame while
	CameraMode is LockFirstPerson — setting MouseBehavior alone would be undone
	immediately. Flipping CameraMode to Classic releases that clamp, and because
	StarterPlayer pins both zoom distances to 0.5 the view stays first person in
	either mode.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local InputController = require(script.Parent.InputController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)

local MouseLockController = {}
MouseLockController.Priority = 5

-- StarterPlayer already pins these; re-asserting on the Player instance keeps
-- the view first person even if a future Studio session edits StarterPlayer.
local FIRST_PERSON_ZOOM = 0.5

local player = Players.LocalPlayer
local trove = Trove.new()
local enabled = true
local toggleUnlocked = false
local effectiveUnlocked = false

--[[
	A phone reports TouchEnabled with no mouse at all, so there is nothing to
	lock. A touchscreen laptop reports TouchEnabled *and* MouseEnabled and must
	keep the desktop behaviour, hence the two-part test rather than
	ClientState.isTouch (which mirrors TouchEnabled alone).
]]
local function isTouchOnly(): boolean
	return UserInputService.TouchEnabled and not UserInputService.MouseEnabled
end

function MouseLockController.isUnlocked(): boolean
	return effectiveUnlocked
end

function MouseLockController.isEnabled(): boolean
	return enabled
end

local function apply()
	if not enabled then
		return
	end

	if effectiveUnlocked then
		player.CameraMode = Enum.CameraMode.Classic
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

local function refresh()
	local wanted = toggleUnlocked or UIController.isAnyMenuOpen()
	if wanted == effectiveUnlocked then
		-- Still re-assert: a respawn resets MouseBehavior even when our own
		-- desired state has not changed.
		apply()
		return
	end

	effectiveUnlocked = wanted
	InputController.setFireSuppressed(wanted)
	apply()
end

--[[
	Programmatic override of the Right Ctrl toggle. Kept in sync with
	InputController so the next Right Ctrl press flips from the current state
	instead of appearing to do nothing.
]]
function MouseLockController.setUnlocked(unlocked: boolean)
	InputController.setMouseUnlocked(unlocked == true)
end

function MouseLockController.init()
	ClientState.init()
	enabled = not isTouchOnly()

	if not enabled then
		-- Touch devices get first person with no cursor management at all.
		player.CameraMode = Enum.CameraMode.LockFirstPerson
		return
	end

	player.CameraMaxZoomDistance = FIRST_PERSON_ZOOM
	player.CameraMinZoomDistance = FIRST_PERSON_ZOOM

	trove:Add(InputController.MouseUnlockToggled:Connect(function(unlocked: boolean)
		toggleUnlocked = unlocked
		refresh()
	end))

	trove:Add(UIController.MenuVisibilityChanged:Connect(function()
		refresh()
	end))

	-- Respawning resets MouseBehavior and MouseIconEnabled to the engine default.
	trove:Connect(player.CharacterAdded, function()
		refresh()
	end)

	refresh()
end

function MouseLockController.start()
	if enabled then
		apply()
	end
end

function MouseLockController.stop()
	trove:Clean()
end

return MouseLockController
