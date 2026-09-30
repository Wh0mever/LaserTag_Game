--!nonstrict
--[[
	tests/harness/notice.luau
	The notice banner: the one line the server needs a player to read.

	It carries things like "you are about to be sent back to the hub", so it has
	to be readable on a phone with a menu open, and it has to sit where a thumb
	and the other controls are not. What it cannot be is a fixed-width strip that
	was drawn for a monitor: left-aligned against its own border, hidden under any
	open panel.

	Run:  lune run tests/harness/notice
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

local passed, failed = 0, 0
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

Env.setDevice("phone")
Env.enableClientRuntime()
Env.service("Workspace").CurrentCamera.ViewportSize = roblox.Vector2.new(640, 294)

local ClientState = Env.load("src/client/ClientState")
local Constants = Env.load("src/shared/Constants")
local NoticeScreen = Env.load("src/client/UI/Screens/NoticeScreen")
local UIController = Env.load("src/client/UI/UIController")

ClientState.init()
UIController.init()
NoticeScreen.init()

local order = Constants.DISPLAY_ORDER

--------------------------------------------------------------------------------
-- Layering
--
-- The banner used to share the toast layer, below every menu. A phone player who
-- had the shop open when the idle warning arrived never saw it, and the warning
-- is only worth anything before the removal it warns about.
--------------------------------------------------------------------------------

heading("Layering")

check(type(order.Notice) == "number", "there is a layer for notices")
if type(order.Notice) == "number" then
	check(order.Notice > order.Menu, "a notice is above the menus")
	check(order.Notice > order.Results, "and above the results screen")
	check(order.Notice < order.Modal, "but below a modal, which has to be answered first")
end
check(order.Toast == 50, "the toast layer itself is unchanged")

-- The layer belongs to the ScreenGui; the banner hangs from the scale host in it.
local screenGui = UIController.getScreen("Notice")
local gui = UIController.getScreenRoot("Notice")
check(screenGui ~= nil and gui ~= nil, "the notice screen exists")
if screenGui then
	check(screenGui.DisplayOrder == order.Notice, `and sits on the notice layer (order {screenGui.DisplayOrder})`)
end

--------------------------------------------------------------------------------
-- Shape
--------------------------------------------------------------------------------

heading("Shape")

local banner = gui and gui:FindFirstChild("Banner")
check(banner ~= nil, "there is a banner")

if banner then
	local message = banner:FindFirstChild("Message")
	check(message ~= nil, "with a message label")

	if message then
		check(message.TextXAlignment == roblox.Enum.TextXAlignment.Center, "the text is centred in the banner")
		check(message.TextWrapped, "and wraps rather than running off the end")
	end

	check(banner.AutomaticSize == roblox.Enum.AutomaticSize.Y, "the banner grows to fit a second line")
	check(
		math.abs(banner.Size.X.Scale - 0.6) < 1e-4 and banner.Size.X.Offset == 0,
		"and takes 60% of the width, not a fixed strip"
	)

	local limit = banner:FindFirstChildOfClass("UISizeConstraint")
	check(limit ~= nil and limit.MaxSize.X == 440, "up to 440 on a wide screen")

	local padding = banner:FindFirstChildOfClass("UIPadding")
	check(padding ~= nil and padding.PaddingLeft.Offset >= 10, "text does not touch the border")

	-- Left edge as drawn, in real pixels: the interface is scaled to the
	-- viewport, so the banner is measured in that scaled space.
	local viewportWidth = 640
	local virtualWidth = viewportWidth / UIController.scale
	local width =
		math.min(banner.Size.X.Scale * virtualWidth + banner.Size.X.Offset, limit and limit.MaxSize.X or math.huge)
	local left = (virtualWidth / 2 - width / 2) * UIController.scale
	check(left >= viewportWidth * 0.19, `it stays clear of the left-hand menu column ({math.floor(left)} px in)`)
end

--------------------------------------------------------------------------------
-- Behaviour that must survive the restyle
--------------------------------------------------------------------------------

heading("Showing")

do
	NoticeScreen.show("Первое", "warning")
	NoticeScreen.show("Второе", "no-such-severity")
	local message = banner and banner:FindFirstChild("Message")
	check(message ~= nil and message.Text == "Второе", "a second notice replaces the first")
	NoticeScreen.show(42, "info")
	NoticeScreen.show("", "info")
	check(message ~= nil and message.Text == "Второе", "a non-string or empty notice is ignored")
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} notice check(s) failed`, 0)
end
print("  All notice checks passed.")
