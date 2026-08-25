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
]]
function UIController.getScreenGui(name: string, displayOrder: number?): ScreenGui?
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

	local uiScale = Instance.new("UIScale")
	uiScale.Scale = UIController.scale
	uiScale.Parent = screenGui
	table.insert(scales, uiScale)

	screens[name] = screenGui
	return screenGui
end

function UIController.getScreen(name: string): ScreenGui?
	return screens[name]
end

--------------------------------------------------------------------------------
-- Responsive scale
--------------------------------------------------------------------------------

local function computeScale(): number
	local camera = workspace.CurrentCamera
	if not camera then
		return 1
	end

	local width = camera.ViewportSize.X
	if width > 0 and width < Constants.SMALL_SCREEN_WIDTH then
		return Constants.SMALL_SCREEN_UI_SCALE
	end
	return 1
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

	viewportTrove:Connect(camera:GetPropertyChangedSignal("ViewportSize"), applyScale)
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

	local ok, err = pcall(handle.close)
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

	-- Exclusivity: at most one menu is ever on screen.
	UIController.closeAll(name)

	local ok, err = pcall(handle.open)
	if not ok then
		warn(`[UIController] {name}.open() failed: {err}`)
		return
	end

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
