--!nonstrict
--[[
	UIController.luau
	The screen registry. Every client screen asks this module for its ScreenGui
	instead of creating one, which gives us three things for free: one place that
	knows the DisplayOrder layering, one UIScale per screen so phones get smaller
	UI, and menu exclusivity (opening the shop closes the equip panel).

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

local screens: { [string]: ScreenGui } = {}
local scales: { UIScale } = {}
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

--[[
	Creates (once) and returns the ScreenGui for a screen.
	`displayOrder` should come from Constants.DISPLAY_ORDER.

	`options.unscaled` leaves the screen out of the small-screen UIScale. Only
	for a screen that already sizes itself from the viewport — the touch
	cluster measures everything in fractions of the viewport height, so scaling
	it again would shrink the fire button twice on exactly the device it is for.
]]
function UIController.getScreenGui(name: string, displayOrder: number?, options: { unscaled: boolean? }?): ScreenGui?
	local existing = screens[name]
	if existing and existing.Parent then
		return existing
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

	if not (options and options.unscaled) then
		local uiScale = Instance.new("UIScale")
		uiScale.Scale = UIController.scale
		uiScale.Parent = screenGui
		table.insert(scales, uiScale)
	end

	screens[name] = screenGui
	return screenGui
end

function UIController.getScreen(name: string): ScreenGui?
	return screens[name]
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
	for index = #scales, 1, -1 do
		local uiScale = scales[index]
		if uiScale.Parent then
			uiScale.Scale = wanted
		else
			table.remove(scales, index)
		end
	end

	UIController.ScaleChanged:Fire(wanted)
end

local viewportTrove = Trove.new()

local function watchViewport()
	viewportTrove:Clean()

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	viewportTrove:Connect(camera:GetPropertyChangedSignal("ViewportSize"), function()
		applyScale()
		UIController.ViewportChanged:Fire(camera.ViewportSize)
	end)
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
