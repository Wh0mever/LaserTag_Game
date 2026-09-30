--!nonstrict
--[[
	UIController.luau
	The screen registry. Every client screen asks this module for its ScreenGui
	instead of creating one, which gives us three things for free: one place that
	knows the DisplayOrder layering, one UIScale per screen so phones get smaller
	UI, and menu exclusivity (opening the shop closes the equip panel).

	WHERE THE UISCALE LIVES. Not on the ScreenGui. Every screen roots itself at
	`fromScale(1, 1)`, and whether the engine multiplies the Scale part of a
	ScreenGui child by a UIScale placed directly under the ScreenGui (drawing
	that root at 82% of a phone's screen) is not something this project can
	test: the Lune sandbox has no layout engine. So each scaled screen gets a
	full-screen host Frame sized 1/scale that carries the UIScale itself:

	    ScreenGui
	      Scaled  (Frame, Size = fromScale(1/scale, 1/scale))
	        UIScale (Scale = scale)
	        ...the screen's own widgets...

	A UIScale on a Frame scales that Frame, Scale part included, so the host
	comes out as exactly the screen, its children's Scale parts fill it, and
	their pixel offsets are multiplied by the scale. That is the same on either
	reading of the ScreenGui question. getScreenGui hands out the host for a
	scaled screen; getScreen still answers with the ScreenGui.

	Because offsets inside a host are multiplied by the scale, anything
	positioned in pixels of the REAL screen (GuiService's top-bar inset above
	all) has to be divided by UIController.scale first.

	Menu hotkeys are wired here, once: InputController.MenuToggled is routed
	straight to toggleMenu(name). A screen registers itself with the matching
	name ("Equip", "Shop", "Friends", "Spin") and must NOT bind MenuToggled
	itself — two listeners would toggle twice and cancel out.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.Parent.Controllers.InputController)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)

local UIController = {}
-- Loads before any screen in the UI folder so screens can register during init().
UIController.Priority = 1

export type MenuHandle = {
	open: () -> (),
	close: () -> (),
	isOpen: () -> boolean,
}

local player = Players.LocalPlayer
local trove = Trove.new()

type ScaledScreen = {
	screenGui: ScreenGui,
	host: Frame,
	uiScale: UIScale,
	-- Multiplies the nominal 1/scale, per axis. 1 unless calibration found the
	-- engine sizing the host at something other than the screen.
	factor: Vector2,
	-- Corrections made since the last resize, so a host the engine will never
	-- size right is given up on instead of chased.
	fixes: number,
	-- The host measurement the last correction was made from. The same
	-- measurement again means the engine has not laid the correction out yet.
	measured: Vector2?,
	trove: any,
}

local screens: { [string]: ScreenGui } = {}
local scaledScreens: { [string]: ScaledScreen } = {}
local menus: { [string]: MenuHandle } = {}
local currentMenu: string? = nil
local playerGui: Instance? = nil

UIController.scale = 1
UIController.MenuVisibilityChanged = Signal.new()
UIController.ScaleChanged = Signal.new()
-- Every viewport resize or rotation, whether or not it moved the scale. Things
-- sized off the viewport itself (the touch cluster) need this rather than
-- ScaleChanged, which is silent whenever the scale happens not to move.
UIController.ViewportChanged = Signal.new()

--------------------------------------------------------------------------------
-- ScreenGui registry
--------------------------------------------------------------------------------

--[[
	PlayerGui exists before any StarterPlayerScripts LocalScript runs, so the
	FindFirstChildOfClass path is the one that is taken in practice; the bounded
	WaitForChild only covers a pathological join and never hangs (SE-11).
]]
local function resolvePlayerGui(): Instance?
	if playerGui and playerGui.Parent then
		return playerGui
	end

	playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not playerGui then
		warn("[UIController] PlayerGui never appeared — no UI will be created")
	end
	return playerGui
end

-- Off by more than this and the host is not the screen. A percent is well
-- above what pixel rounding and the scale's own rounding to hundredths cause.
local CALIBRATION_TOLERANCE = 0.01
local MAX_CALIBRATIONS = 3

local function hostSize(scale: number, factor: Vector2): UDim2
	return UDim2.fromScale(factor.X / scale, factor.Y / scale)
end

-- nil for "no layout yet": a real screen reports zero before its first pass and
-- the Lune sandbox raises on an AbsoluteSize nothing has written.
local function measure(instance: Instance): Vector2?
	local ok, size = pcall(function()
		return (instance :: any).AbsoluteSize
	end)
	if not ok or typeof(size) ~= "Vector2" or size.X <= 0 or size.Y <= 0 then
		return nil
	end
	return size
end

--[[
	Makes the host the size of its screen, whatever the engine does with the
	UIScale. Sizing it 1/scale is the design; this is the check that the design
	came out, and the repair if it did not.

	The ratio is applied to the host's current size, so it converges in one step
	for any engine that scales linearly. MAX_CALIBRATIONS is for one that does
	not.
]]
local function calibrate(entry: ScaledScreen)
	if entry.fixes >= MAX_CALIBRATIONS then
		return
	end

	local screenSize = measure(entry.screenGui)
	local hostAbsolute = measure(entry.host)
	if not screenSize or not hostAbsolute then
		return
	end

	local ratioX = screenSize.X / hostAbsolute.X
	local ratioY = screenSize.Y / hostAbsolute.Y
	if math.abs(ratioX - 1) <= CALIBRATION_TOLERANCE and math.abs(ratioY - 1) <= CALIBRATION_TOLERANCE then
		entry.measured = nil
		return
	end

	local last = entry.measured
	if last and last.X == hostAbsolute.X and last.Y == hostAbsolute.Y then
		return
	end

	entry.fixes += 1
	entry.measured = hostAbsolute
	entry.factor = Vector2.new(entry.factor.X * ratioX, entry.factor.Y * ratioY)
	entry.host.Size = hostSize(UIController.scale, entry.factor)
end

local function buildScaledScreen(screenGui: ScreenGui): ScaledScreen
	local host = Instance.new("Frame")
	host.Name = "Scaled"
	host.BackgroundTransparency = 1
	host.BorderSizePixel = 0
	host.Size = hostSize(UIController.scale, Vector2.new(1, 1))

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = UIController.scale
	uiScale.Parent = host
	host.Parent = screenGui

	local entry: ScaledScreen = {
		screenGui = screenGui,
		host = host,
		uiScale = uiScale,
		factor = Vector2.new(1, 1),
		fixes = 0,
		measured = nil,
		trove = Trove.new(),
	}

	entry.trove:Connect(host:GetPropertyChangedSignal("AbsoluteSize"), function()
		calibrate(entry)
	end)
	entry.trove:Connect(screenGui:GetPropertyChangedSignal("AbsoluteSize"), function()
		calibrate(entry)
	end)

	return entry
end

--[[
	Creates (once) and returns the parent a screen builds into.

	For a scaled screen that is the host Frame (see the header); the ScreenGui
	itself is `getScreen(name)`. Every caller only uses the result as a Parent,
	which is the whole of the contract.

	`displayOrder` should come from Constants.DISPLAY_ORDER.

	`options.unscaled` leaves the screen out of the small-screen UIScale, and
	gives back the ScreenGui itself. Only for a screen that already sizes itself
	from the viewport — the touch cluster measures everything in fractions of the
	viewport height, so scaling it again would shrink the fire button twice on
	exactly the device it is for.
]]
function UIController.getScreenGui(name: string, displayOrder: number?, options: { unscaled: boolean? }?): Instance?
	local existing = screens[name]
	if existing and existing.Parent then
		local entry = scaledScreens[name]
		return if entry then entry.host else existing
	end

	local parent = resolvePlayerGui()
	if not parent then
		return nil
	end

	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = name
	-- Screens outlive the character: rebuilding a shop on every respawn would
	-- lose scroll position and reset any in-flight purchase state.
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = displayOrder or Constants.DISPLAY_ORDER.HUD
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = parent

	screens[name] = screenGui

	-- A ScreenGui that was destroyed and is being rebuilt leaves its host's
	-- listeners behind otherwise.
	local previous = scaledScreens[name]
	if previous then
		previous.trove:Clean()
		scaledScreens[name] = nil
	end

	if options and options.unscaled then
		return screenGui
	end

	local entry = buildScaledScreen(screenGui)
	scaledScreens[name] = entry
	return entry.host
end

-- The ScreenGui itself, whether or not it is scaled.
function UIController.getScreen(name: string): ScreenGui?
	return screens[name]
end

-- What a screen's widgets are parented to: the host of a scaled screen, the
-- ScreenGui of an unscaled one. Same answer getScreenGui gave, without
-- creating anything.
function UIController.getScreenRoot(name: string): Instance?
	local entry = scaledScreens[name]
	if entry then
		return entry.host
	end
	return screens[name]
end

--[[
	Re-measures every scaled screen against its ScreenGui and corrects any host
	that is not the screen's size. Driven by the AbsoluteSize signals; public so
	the harness, which has no layout engine to fire them, can drive it.
]]
function UIController.calibrate()
	for _, entry in scaledScreens do
		calibrate(entry)
	end
end

--------------------------------------------------------------------------------
-- Responsive scale
--------------------------------------------------------------------------------

--[[
	1 on a monitor or a tablet, shrinking on a phone.

	Height leads: a phone on its side reports about 640x294, so a width test
	alone (what this used to be) passes it as a desktop and draws every panel
	at monitor size on a screen a third as tall. Width still takes part so a
	narrow window does not keep panels wider than itself.

	Rounded to hundredths so a viewport that jitters by a pixel while the
	on-screen keyboard or the Roblox menu animates does not rescale every
	screen on every frame of it.
]]
function UIController.computeScale(viewport: Vector2?): number
	local size = viewport
	if not size then
		local camera = workspace.CurrentCamera
		if not camera then
			return 1
		end
		size = camera.ViewportSize
	end
	if size.X <= 0 or size.Y <= 0 then
		return 1
	end

	local fit = math.min(size.Y / Constants.UI_REFERENCE_HEIGHT, size.X / Constants.UI_REFERENCE_WIDTH)
	local clamped = math.clamp(fit, Constants.UI_MIN_SCALE, 1)
	return math.floor(clamped * 100 + 0.5) / 100
end

local function computeScale(): number
	return UIController.computeScale()
end

local function applyScale()
	local wanted = computeScale()
	if wanted == UIController.scale then
		return
	end

	UIController.scale = wanted
	for name, entry in scaledScreens do
		if not entry.screenGui.Parent then
			entry.trove:Clean()
			scaledScreens[name] = nil
			continue
		end
		-- A new scale is a new problem: whatever the engine did to the old
		-- host size says nothing about this one.
		entry.factor = Vector2.new(1, 1)
		entry.fixes = 0
		entry.measured = nil
		entry.uiScale.Scale = wanted
		entry.host.Size = hostSize(wanted, entry.factor)
	end

	UIController.ScaleChanged:Fire(wanted)
end

local viewportTrove = Trove.new()

--[[
	Every viewport resize or rotation: rescale, then announce. Public so the
	harness, whose camera cannot fire a property signal, can drive it.
]]
function UIController.refreshViewport()
	applyScale()
	-- A resize starts a fresh round of host corrections.
	for _, entry in scaledScreens do
		entry.fixes = 0
		entry.measured = nil
	end

	local camera = workspace.CurrentCamera
	if camera then
		UIController.ViewportChanged:Fire(camera.ViewportSize)
	end
end

--[[
	The viewport in real pixels, nil before a camera exists.
]]
function UIController.getViewportSize(): Vector2?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local size = camera.ViewportSize
	if size.X <= 0 or size.Y <= 0 then
		return nil
	end
	return size
end

--[[
	The space a scaled screen lays out in: the viewport divided by the scale, so
	a 640x294 phone at 0.82 is a 780x358 canvas. Offsets inside a host are in
	these units; the answer to "does it fit" is asked here, not of the viewport.
]]
function UIController.getCanvasSize(): Vector2?
	local size = UIController.getViewportSize()
	if not size then
		return nil
	end
	return size / UIController.scale
end

local function watchViewport()
	viewportTrove:Clean()

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	viewportTrove:Connect(camera:GetPropertyChangedSignal("ViewportSize"), UIController.refreshViewport)
	applyScale()
end

--------------------------------------------------------------------------------
-- Menus
--------------------------------------------------------------------------------

local function handleIsOpen(handle: MenuHandle): boolean
	local ok, open = pcall(handle.isOpen)
	return ok and open == true
end

--[[
	`handle` is {open, close, isOpen} — Panel:asMenuHandle() returns exactly this.
]]
function UIController.registerMenu(name: string, handle: MenuHandle)
	if type(handle) ~= "table" or type(handle.open) ~= "function" or type(handle.close) ~= "function" then
		warn(`[UIController] registerMenu("{name}") needs a handle with open/close/isOpen`)
		return
	end

	menus[name] = handle
end

function UIController.unregisterMenu(name: string)
	if currentMenu == name then
		currentMenu = nil
	end
	menus[name] = nil
end

function UIController.isMenuOpen(name: string): boolean
	local handle = menus[name]
	return handle ~= nil and handleIsOpen(handle)
end

function UIController.isAnyMenuOpen(): boolean
	-- Asks the handles rather than trusting `currentMenu`: a screen that closed
	-- itself from its own X button would otherwise leave the cursor unlocked.
	for _, handle in menus do
		if handleIsOpen(handle) then
			return true
		end
	end
	return false
end

--[[
	True while UIController is the one doing the closing, so a panel reporting
	its own close does not fire the signal a second time.
]]
local closingFromController = false

--[[
	A panel telling us it closed ITSELF — its own X button, or a tap on the
	overlay behind it.

	Without this the signal never fires for those two paths, and the signal is
	what frees the mouse and puts the touch controls back. So closing the shop
	with its X left a desktop player's cursor locked and a phone player with no
	fire button at all, until some unrelated menu happened to open and close and
	shook everything loose. On a phone that reads as "the game takes a minute to
	start working".

	Calling closeMenu instead does not help: it returns early when the panel is
	already shut, which by then it is.
]]
function UIController.notifyClosed(name: string)
	if closingFromController then
		return
	end
	if not menus[name] then
		return
	end

	if currentMenu == name then
		currentMenu = nil
	end
	UIController.MenuVisibilityChanged:FireSync(name, false)
end

function UIController.closeMenu(name: string)
	local handle = menus[name]
	if not handle then
		return
	end

	local wasOpen = handleIsOpen(handle)
	if currentMenu == name then
		currentMenu = nil
	end
	if not wasOpen then
		return
	end

	closingFromController = true
	local ok, err = pcall(handle.close)
	closingFromController = false
	if not ok then
		warn(`[UIController] {name}.close() failed: {err}`)
	end

	UIController.MenuVisibilityChanged:FireSync(name, false)
end

function UIController.closeAll(except: string?)
	for name, handle in menus do
		if name ~= except and handleIsOpen(handle) then
			UIController.closeMenu(name)
		end
	end
end

function UIController.openMenu(name: string)
	local handle = menus[name]
	if not handle then
		warn(`[UIController] no menu registered as "{name}"`)
		return
	end

	if handleIsOpen(handle) then
		return
	end

	local ok, err = pcall(handle.open)
	if not ok then
		warn(`[UIController] {name}.open() failed: {err}`)
		return
	end

	-- Exclusivity, applied AFTER the new panel is open rather than before.
	-- Closing first meant that switching straight from the shop to the spinner
	-- passed through a moment with nothing open, and everything listening to
	-- MenuVisibilityChanged — the cursor above all — did a pointless lock and
	-- unlock inside a single frame. No frame renders between these two calls,
	-- so nobody ever sees two panels.
	UIController.closeAll(name)

	currentMenu = name
	-- FireSync so MouseLockController frees the cursor in the same frame the
	-- panel appears, instead of one Signal hop later.
	UIController.MenuVisibilityChanged:FireSync(name, true)
end

function UIController.toggleMenu(name: string)
	if UIController.isMenuOpen(name) then
		UIController.closeMenu(name)
	else
		UIController.openMenu(name)
	end
end

function UIController.getOpenMenu(): string?
	return currentMenu
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function UIController.init()
	ClientState.init()
	ClientState.isTouch = UserInputService.TouchEnabled

	UIController.scale = computeScale()

	trove:Add(InputController.MenuToggled:Connect(function(name: string)
		if menus[name] then
			UIController.toggleMenu(name)
		end
	end))

	trove:Connect(workspace:GetPropertyChangedSignal("CurrentCamera"), watchViewport)
	trove:Add(viewportTrove)

	watchViewport()
end

function UIController.stop()
	trove:Clean()
end

return UIController
