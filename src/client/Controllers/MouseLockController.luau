--!nonstrict
--[[
	MouseLockController.luau
	Owns the cursor. Two inputs decide whether the mouse is free:

	  * the Right Ctrl toggle published by InputController.MouseUnlockToggled
	  * whether any menu is open (UIController.MenuVisibilityChanged)

	Either one frees the cursor; the cursor re-locks only when both are clear.

	Ownership note: this controller is the ONLY place that writes
	`player.CameraMode`, `UserInputService.MouseBehavior` and `MouseIconEnabled`.
	CameraController owns workspace.CurrentCamera instead.

	WHY THIS IS NOT JUST A MouseBehavior WRITE. Roblox's own PlayerModule decides
	the cursor from a cached `inFirstPerson` flag, which it derives from the
	camera's subject distance — not from Player.CameraMode. StarterPlayer pins
	CameraMinZoomDistance and CameraMaxZoomDistance to 0.5, below the module's
	1.0 first-person threshold, so that flag is latched true for the whole
	session and no CameraMode value can clear it. CameraModule:Update then runs
	every rendered frame at Enum.RenderPriority.Camera and writes LockCenter
	while it is set. A one-shot write from menu-open code therefore survives
	exactly one frame, which is why the first version of this file appeared to
	work and did nothing.

	So the cursor is freed two ways, deliberately belt and braces:

	  * a full-screen GuiButton with Modal = true. This is the engine-level
	    override Roblox documents on Player.CameraMode, evaluated above
	    MouseBehavior, so the PlayerModule may keep writing LockCenter and lose.
	    It also zeroes the mouse delta, which is what stops the view spinning
	    while the cursor travels across a panel.
	  * a render-step binding one priority above the camera's, re-asserting the
	    cursor after the module has had its turn. Modal has known gaps (Studio
	    under LockFirstPerson, and buttons near the bottom edge), and being
	    unable to click anything is too total a failure to leave on one mechanism.

	CameraMode is written once per perspective change and never as part of
	freeing the cursor. Flipping it to Classic to release the cursor — which is
	what this file used to do — achieved nothing but a deferred round trip
	through the camera module on every menu toggle.

	In third person the PlayerModule stops forcing LockCenter of its own accord,
	because it no longer believes the camera is first person. That is the same
	property in reverse: the cursor must then be locked here, or the view stops
	turning with the mouse. `writeCursor` does it in both modes, so the two
	perspectives take the same path.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.InputController)
local PerspectiveController = require(script.Parent.PerspectiveController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)

local MouseLockController = {}
MouseLockController.Priority = 5

-- Both zoom distances are pinned to the same value, so the view sits exactly
-- where the perspective says and the scroll wheel cannot move it. PerspectiveController
-- owns which value that is.

-- One above Enum.RenderPriority.Camera, so this runs immediately after
-- CameraModule:Update has written its LockCenter for the frame.
local AFTER_CAMERA = Enum.RenderPriority.Camera.Value + 1
local GUARD_BINDING = "LaserTagCursorGuard"

local player = Players.LocalPlayer
local trove = Trove.new()
--[[
	Whether there is a cursor to manage. False on a phone.

	NOT whether this controller does anything: the perspective — camera mode and
	zoom — is applied on every device, and used not to be. A phone took the early
	return before applyPerspective ran and before Changed was connected, so it
	kept StarterPlayer's LockFirstPerson and its 0.5 zoom for the whole session.
	Third person did not exist on mobile, and the touch VIEW button flipped the
	stored setting and saved it while the camera never moved — which is worse
	than an inert button, because the preference then disagreed with the screen
	and followed the player to their desktop.
]]
local cursorEnabled = true
local toggleUnlocked = false
local effectiveUnlocked = false
local modalButton: TextButton? = nil
local guardBound = false

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

--[[
	Whether this client manages a cursor. False on a phone, which has none —
	it says nothing about whether the camera is managed, which it always is.
]]
function MouseLockController.isEnabled(): boolean
	return cursorEnabled
end

--[[
	The invisible full-screen button whose mere visibility is the engine-level
	override. It lives at the bottom DisplayOrder so it is under every panel and
	under the side buttons: it must never receive a click, only be on screen.

	Full-screen and anchored at the top-left on purpose — a modal button whose
	AbsolutePosition sits within 58 pixels of the bottom of the viewport stops
	applying, a known engine bug that a small button would walk straight into.
]]
local function ensureModal(): TextButton?
	if modalButton and modalButton.Parent then
		return modalButton
	end

	local gui = UIController.getScreenGui("CursorModal", Constants.DISPLAY_ORDER.Background)
	if not gui then
		return nil
	end

	local button = Instance.new("TextButton")
	button.Name = "ModalCapture"
	button.Position = UDim2.fromScale(0, 0)
	button.Size = UDim2.fromScale(1, 1)
	button.BackgroundTransparency = 1
	button.Text = ""
	button.AutoButtonColor = false
	button.Modal = true
	button.Visible = false
	button.ZIndex = 1
	button.Parent = gui
	trove:Add(button)
	modalButton = button
	return button
end

--[[
	Writes the cursor state. Called from apply() and again every frame while the
	cursor is meant to be free, because Roblox's camera module rewrites it at a
	lower render priority on every one of those frames.
]]
local function writeCursor()
	if not cursorEnabled then
		return
	end

	if effectiveUnlocked then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	else
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

local function setGuard(active: boolean)
	if active == guardBound then
		return
	end
	guardBound = active

	if active then
		RunService:BindToRenderStep(GUARD_BINDING, AFTER_CAMERA, writeCursor)
	else
		RunService:UnbindFromRenderStep(GUARD_BINDING)
	end
end

--[[
	Camera mode and zoom for the current perspective.

	Both zoom distances are pinned to the same number so the scroll wheel cannot
	move the view: how far a player can see round a corner is a balance
	property, not a preference to be discovered accidentally.
]]
local function applyPerspective()
	local zoom = PerspectiveController.zoom()
	player.CameraMinZoomDistance = zoom
	player.CameraMaxZoomDistance = zoom
	player.CameraMode = if PerspectiveController.isFirstPerson()
		then Enum.CameraMode.LockFirstPerson
		else Enum.CameraMode.Classic

	-- The cursor has to be re-asserted after the change: leaving first person
	-- makes the camera module stop writing LockCenter, and nothing else would
	-- put it back for a player who is mid-match rather than mid-menu.
	writeCursor()
end

local function apply()
	if not cursorEnabled then
		return
	end

	local modal = ensureModal()
	if modal then
		modal.Visible = effectiveUnlocked
	end

	-- Bound only while the cursor is free: a permanent binding would be a write
	-- war with engine code for the whole session to no purpose, since during
	-- play the camera module already wants exactly what this wants.
	setGuard(effectiveUnlocked)
	writeCursor()
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
	cursorEnabled = not isTouchOnly()

	-- Before the touch early return, and deliberately so. The camera belongs to
	-- every device; only the cursor work below is desktop-only. StarterPlayer
	-- ships LockFirstPerson with both zoom distances at 0.5, so a client that
	-- never reaches this line is welded into first person for the session — which
	-- is exactly what phones used to get.
	applyPerspective()
	trove:Add(PerspectiveController.Changed:Connect(applyPerspective))

	if not cursorEnabled then
		-- A phone has no cursor to free and no Right Ctrl to free it with. The
		-- touch buttons are bound by MobileControlsController instead.
		return
	end

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
	if cursorEnabled then
		apply()
	end
end

function MouseLockController.stop()
	setGuard(false)
	trove:Clean()
	modalButton = nil
end

return MouseLockController
