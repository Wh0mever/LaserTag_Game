--!nonstrict
--[[
	tests/harness/uiscale.luau
	What the small-screen UIScale does to the tree, and what the phone chrome
	does with the room it is left.

	THE QUESTION THIS EXISTS FOR. UIController shrinks the UI on a phone with a
	UIScale, and every screen's root is sized in Scale (`fromScale(1, 1)`). Where
	that UIScale lives decides whether such a root still covers the screen. Under
	a ScreenGui the engine may multiply the Scale part of its children as well as
	the offsets, drawing a "full screen" root at 82% of the screen; nothing here
	can run the engine, and the renderer used to assume the kinder answer, so
	both reported clean while the answer was unknown.

	So the tree is built to be right under either answer: the UIScale sits on a
	full-screen host Frame sized 1/scale, which is exactly the screen whichever
	way the scale part is treated. These checks pin that shape, and pin the
	self-calibration that catches an engine that does neither.

	Run:  lune run tests/harness/uiscale
]]

local Env = require("./env")
local fs = require("@lune/fs")
local roblox = require("@lune/roblox")

local passed = 0
local failed = 0
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

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 1e-6)
end

--------------------------------------------------------------------------------
-- Boot the whole client as a phone, the way init.client does
--------------------------------------------------------------------------------

heading("Booting a phone at 640x294")

Env.setDevice("phone")
Env.enableClientRuntime()

local camera = Env.service("Workspace").CurrentCamera
camera.ViewportSize = roblox.Vector2.new(640, 294)

local player = Env.service("Players").LocalPlayer

local function collect(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collect(full, out)
		elseif entry:match("%.luau$") then
			table.insert(out, (full:gsub("%.luau$", "")))
		end
	end
	return out
end

local function boot(root: string)
	local loaded = {}
	for _, path in collect(root, {}) do
		local ok, value = pcall(Env.load, path)
		check(ok, `{path} loads{if ok then "" else ": " .. tostring(value)}`)
		if ok and type(value) == "table" then
			table.insert(loaded, {
				name = path:match("([^/]+)$"),
				value = value,
				priority = if type(value.Priority) == "number" then value.Priority else 100,
			})
		end
	end
	table.sort(loaded, function(a, b)
		if a.priority == b.priority then
			return a.name < b.name
		end
		return a.priority < b.priority
	end)
	for _, entry in loaded do
		if type(entry.value.init) == "function" then
			local ok, err = pcall(entry.value.init)
			check(ok, `{entry.name}.init(){if ok then "" else " -> " .. tostring(err)}`)
		end
	end
	for _, entry in loaded do
		if type(entry.value.start) == "function" then
			Env.spawn(function()
				local ok, err = pcall(entry.value.start)
				check(ok, `{entry.name}.start(){if ok then "" else " -> " .. tostring(err)}`)
			end)
		end
	end
end

boot("src/client/Controllers")
boot("src/client/UI")

local UIController = Env.load("src/client/UI/UIController")
local playerGui = player.PlayerGui

--------------------------------------------------------------------------------
-- The shape: a host Frame carries the UIScale
--------------------------------------------------------------------------------

heading("Scaled screens have a host")

check(near(UIController.scale, 0.82), `a 640x294 phone is scaled to 0.82 (got {UIController.scale})`)

local function screenGuis(): { any }
	local out = {}
	for _, child in playerGui:GetChildren() do
		if child.ClassName == "ScreenGui" then
			table.insert(out, child)
		end
	end
	return out
end

-- The one screen that measures itself in fractions of the viewport height and
-- so opts out of the scale.
local UNSCALED = { TouchControls = true }

local function hostOf(gui: any): any
	return gui:FindFirstChild("Scaled")
end

local function uiScaleOf(instance: any): any
	return instance:FindFirstChildOfClass("UIScale")
end

local guis = screenGuis()
check(#guis >= 15, `the client built its screens ({#guis} ScreenGuis)`)

-- Counted once, so the later passes cannot quietly check fewer screens.
local scaledCount = 0
for _, gui in guis do
	if not UNSCALED[gui.Name] then
		scaledCount += 1
	end
end

for _, gui in guis do
	if UNSCALED[gui.Name] then
		continue
	end

	local host = hostOf(gui)
	check(host ~= nil and host.ClassName == "Frame", `{gui.Name}: the content parent is a host Frame`)
	if not host then
		continue
	end

	-- THE POINT: the scale is on the host, never directly under the ScreenGui,
	-- where the engine's treatment of a child's Scale part is the unknown.
	check(uiScaleOf(gui) == nil, `{gui.Name}: no UIScale sits directly under the ScreenGui`)

	local scale = uiScaleOf(host)
	check(scale ~= nil, `{gui.Name}: the host carries the UIScale`)
	if scale then
		check(
			near(scale.Scale, UIController.scale),
			`{gui.Name}: the UIScale is {UIController.scale} (got {scale.Scale})`
		)
	end

	-- 1/scale, so that host (1/scale of the screen) x UIScale (scale) is exactly
	-- the screen, and every child's Scale part fills it.
	check(
		near(host.Size.X.Scale, 1 / UIController.scale) and near(host.Size.Y.Scale, 1 / UIController.scale),
		`{gui.Name}: the host is sized 1/scale (got {host.Size.X.Scale}, {host.Size.Y.Scale})`
	)
	check(host.Size.X.Offset == 0 and host.Size.Y.Offset == 0, `{gui.Name}: the host size has no pixel part`)
	check(
		host.Position == roblox.UDim2.new() and host.AnchorPoint == roblox.Vector2.new(0, 0),
		`{gui.Name}: the host sits at the top left corner`
	)

	-- It must not become a click sink or a picture of its own.
	check(host.BackgroundTransparency == 1, `{gui.Name}: the host is invisible`)
	check(host.BorderSizePixel == 0, `{gui.Name}: the host has no border`)
	check(host.Active == false, `{gui.Name}: the host does not swallow input`)
	check(host.ClipsDescendants == false, `{gui.Name}: the host does not clip`)

	-- Everything the screen builds lives in the host: a stray child of the
	-- ScreenGui would be laid out against the unscaled screen.
	check(#gui:GetChildren() == 1, `{gui.Name}: the host is the only child of the ScreenGui ({#gui:GetChildren()})`)

	-- What the screens are handed to parent to, and what the registry still
	-- reports.
	check(UIController.getScreenGui(gui.Name) == host, `{gui.Name}: getScreenGui hands out the host`)
	check(UIController.getScreen(gui.Name) == gui, `{gui.Name}: getScreen still returns the ScreenGui`)
end

heading("Unscaled screens have no host")

local touchGui = playerGui:FindFirstChild("TouchControls")
check(touchGui ~= nil, "the touch cluster has its ScreenGui")
if touchGui then
	check(hostOf(touchGui) == nil, "an unscaled screen has no host")
	check(uiScaleOf(touchGui) == nil, "an unscaled screen has no UIScale")
	check(UIController.getScreenGui("TouchControls") == touchGui, "an unscaled screen's parent is the ScreenGui itself")
end

--------------------------------------------------------------------------------
-- The scale follows the viewport
--------------------------------------------------------------------------------

heading("A viewport change moves the host and the scale together")

local scaleEvents = 0
local viewportEvents = 0
UIController.ScaleChanged:Connect(function()
	scaleEvents += 1
end)
UIController.ViewportChanged:Connect(function()
	viewportEvents += 1
end)

local function assertHostsMatch(label: string)
	local checked = 0
	for _, gui in screenGuis() do
		if UNSCALED[gui.Name] then
			continue
		end
		local host = hostOf(gui)
		local scale = host and uiScaleOf(host)
		if host and scale then
			checked += 1
			check(near(scale.Scale, UIController.scale), `{label}: {gui.Name} UIScale follows ({scale.Scale})`)
			check(
				near(host.Size.X.Scale, 1 / UIController.scale) and near(host.Size.Y.Scale, 1 / UIController.scale),
				`{label}: {gui.Name} host follows ({host.Size.X.Scale})`
			)
		end
	end
	check(checked == scaledCount, `{label}: {checked} of {scaledCount} hosts were checked`)
end

check(type(UIController.refreshViewport) == "function", "UIController.refreshViewport() exists for the harness")
if type(UIController.refreshViewport) == "function" then
	camera.ViewportSize = roblox.Vector2.new(1024, 768)
	UIController.refreshViewport()
	check(UIController.scale == 1, `a tablet is not scaled (got {UIController.scale})`)
	check(scaleEvents == 1 and viewportEvents == 1, "one ScaleChanged and one ViewportChanged for the tablet")
	assertHostsMatch("tablet")

	camera.ViewportSize = roblox.Vector2.new(568, 320)
	UIController.refreshViewport()
	check(near(UIController.scale, 0.81), `a 568x320 phone is scaled to 0.81 (got {UIController.scale})`)
	assertHostsMatch("small phone")

	-- A resize that leaves the scale alone still announces itself, and leaves
	-- the hosts as they were.
	local before = scaleEvents
	camera.ViewportSize = roblox.Vector2.new(570, 320)
	UIController.refreshViewport()
	check(scaleEvents == before, "a resize that keeps the scale does not announce a scale change")
	check(viewportEvents == 3, "but every resize is announced as a viewport change")
	assertHostsMatch("same scale")

	camera.ViewportSize = roblox.Vector2.new(640, 294)
	UIController.refreshViewport()
	check(near(UIController.scale, 0.82), "back to the owner's phone")
	assertHostsMatch("back")
end

--------------------------------------------------------------------------------
-- Self-calibration
--
-- If the engine sizes the host at anything other than the screen, the host is
-- corrected from what it measures. Lune has no layout engine, so the sizes are
-- written the way the engine would report them.
--------------------------------------------------------------------------------

heading("Self-calibration")

local hudGui = UIController.getScreen("HUD")
local hudHost = hudGui and hostOf(hudGui)
check(hudGui ~= nil and hudHost ~= nil, "the HUD screen has a host to calibrate")

check(type(UIController.calibrate) == "function", "UIController.calibrate() exists")
if hudGui and hudHost and type(UIController.calibrate) == "function" then
	local scale = UIController.scale
	local nominal = 1 / scale

	-- No layout yet (Lune raises on an unset AbsoluteSize; a real screen reports
	-- zero before its first pass): nothing to measure, nothing to change.
	local ok = pcall(UIController.calibrate)
	check(ok, "calibrating before any layout is harmless")
	check(near(hudHost.Size.X.Scale, nominal), "and leaves the host alone")

	-- The kind engine: the host comes out as the screen.
	Env.placeGui(hudGui, 0, 0, 640, 294)
	Env.placeGui(hudHost, 0, 0, 640, 294)
	UIController.calibrate()
	check(
		near(hudHost.Size.X.Scale, nominal) and near(hudHost.Size.Y.Scale, nominal),
		"a host that fills the screen is left alone"
	)

	-- Within a percent counts as filling it: the scale is rounded to hundredths
	-- and the sizes to pixels.
	Env.placeGui(hudHost, 0, 0, 637, 292)
	UIController.calibrate()
	check(near(hudHost.Size.X.Scale, nominal), "half a percent of rounding is not chased")

	-- The unkind engine: the host is drawn at 82% of the screen (the scale part
	-- is scaled twice). It is grown by the ratio it fell short by.
	Env.placeGui(hudHost, 0, 0, 640 * 0.82, 294 * 0.82)
	UIController.calibrate()
	check(
		near(hudHost.Size.X.Scale, nominal / 0.82, 1e-4) and near(hudHost.Size.Y.Scale, nominal / 0.82, 1e-4),
		`a host at 82% of the screen is grown by 1/0.82 (got {hudHost.Size.X.Scale}, {hudHost.Size.Y.Scale})`
	)

	-- The engine has not laid the new size out yet, so the measurement is the
	-- same one: correcting again would grow the host twice for one problem.
	local corrected = hudHost.Size.X.Scale
	UIController.calibrate()
	UIController.calibrate()
	check(near(hudHost.Size.X.Scale, corrected), "a measurement already acted on is not acted on again")

	-- ...and once it has been laid out the right size, it stays.
	Env.placeGui(hudHost, 0, 0, 640, 294)
	UIController.calibrate()
	check(near(hudHost.Size.X.Scale, corrected), "a corrected host is then left alone")

	-- A host that only ever falls short on one axis is corrected on that axis.
	Env.placeGui(hudHost, 0, 0, 640, 147)
	UIController.calibrate()
	check(
		near(hudHost.Size.X.Scale, corrected) and near(hudHost.Size.Y.Scale, nominal / 0.82 * 2, 1e-4),
		`only the short axis is corrected (got {hudHost.Size.X.Scale}, {hudHost.Size.Y.Scale})`
	)

	-- A zero size is "not laid out", never "infinitely small".
	local beforeX = hudHost.Size.X.Scale
	Env.placeGui(hudHost, 0, 0, 0, 0)
	UIController.calibrate()
	check(hudHost.Size.X.Scale == beforeX, "a zero-sized host is ignored")
	Env.placeGui(hudHost, 0, 0, 640, 294)
	Env.placeGui(hudGui, 0, 0, 0, 0)
	UIController.calibrate()
	check(hudHost.Size.X.Scale == beforeX, "a zero-sized screen is ignored")

	-- An engine that keeps disagreeing however it is corrected must not be
	-- chased forever. A new resize starts a new round of corrections.
	UIController.refreshViewport()
	Env.placeGui(hudGui, 0, 0, 640, 294)
	local sizes = {}
	for step = 1, 12 do
		Env.placeGui(hudHost, 0, 0, 100 + step, 100 + step)
		UIController.calibrate()
		sizes[hudHost.Size.X.Scale] = true
	end
	local distinct = 0
	for _ in sizes do
		distinct += 1
	end
	check(distinct <= 5, `an engine that never settles is given up on ({distinct} corrections)`)

	-- A new scale starts again from the nominal size: the quirk a scale of 0.82
	-- had says nothing about a scale of 1.
	camera.ViewportSize = roblox.Vector2.new(1024, 768)
	UIController.refreshViewport()
	check(
		near(hudHost.Size.X.Scale, 1) and near(hudHost.Size.Y.Scale, 1),
		`a new scale resets the host to 1/scale (got {hudHost.Size.X.Scale})`
	)
	camera.ViewportSize = roblox.Vector2.new(640, 294)
	UIController.refreshViewport()
end

--------------------------------------------------------------------------------
-- Roblox's top bar is measured in real pixels
--
-- GuiService reports the bar in real pixels, and pixel offsets inside a host are
-- multiplied by the scale. Added as-is, "36 + 8" landed at 0.82 x 44 = 36 real
-- pixels on a phone: the bar's own height, so the coin chip sat under it.
--------------------------------------------------------------------------------

heading("Chrome under the top bar")

local guiService = Env.service("GuiService")

local function realTop(instance: any): number
	return instance.Position.Y.Offset * UIController.scale
end

local function chromeTops(): { [string]: any }
	local sideRoot = UIController.getScreenRoot("SideButtons")
	local queueRoot = UIController.getScreenRoot("Queue")
	local rootFrame = sideRoot and sideRoot:FindFirstChild("Root")
	return {
		coins = rootFrame and rootFrame:FindFirstChild("Coins"),
		menu = rootFrame and rootFrame:FindFirstChild("Menu"),
		queue = queueRoot and queueRoot:FindFirstChild("QueueChip"),
	}
end

-- Where each sits below the bar, in the units the screen's own margins use.
local BELOW_BAR = { coins = 8, menu = 56, queue = 8 }

local function assertBelowBar(label: string)
	local inset = guiService:GetGuiInset().Y
	local tops = chromeTops()
	for name, extra in BELOW_BAR do
		local instance = tops[name]
		check(instance ~= nil, `{label}: the {name} element exists`)
		if instance then
			local real = realTop(instance)
			check(
				real >= inset - 0.01,
				`{label}: {name} starts at {string.format("%.1f", real)} real px, below the {inset} px bar`
			)
			-- A UDim offset is a whole number, so the bar's share is rounded up
			-- by less than one canvas unit: never into the bar, never far off.
			check(
				near(real, inset + extra * UIController.scale, UIController.scale),
				`{label}: {name} keeps its {extra}-unit margin under the bar ({string.format("%.1f", real)} px)`
			)
		end
	end
end

assertBelowBar("phone")

-- The bar can change with the viewport (rotation, a different device
-- profile); the screens read it again when it does.
local realGetInset = guiService.GetGuiInset
guiService.GetGuiInset = function()
	return roblox.Vector2.new(0, 58), roblox.Vector2.new(0, 0)
end
camera.ViewportSize = roblox.Vector2.new(1024, 768)
UIController.refreshViewport()
assertBelowBar("tablet with a 58 px bar")

camera.ViewportSize = roblox.Vector2.new(640, 294)
UIController.refreshViewport()
assertBelowBar("phone with a 58 px bar")

guiService.GetGuiInset = realGetInset
UIController.refreshViewport()
assertBelowBar("phone, bar back to 36")

--------------------------------------------------------------------------------
-- The touch menu row fits the screen it is on
--
-- On a touchscreen the five menu buttons open sideways from the hamburger, a
-- row 1122 units long with labels. It used to shrink to icons only when the UI
-- was being scaled down, i.e. on the smallest phones; on a tablet or any phone
-- with a viewport past 700x360 nothing shrank it, and НАСТРОЙКИ and КОЛЕСО ran
-- off the right edge with no other way to reach them on a touchscreen.
--------------------------------------------------------------------------------

heading("The menu row on touch screens")

local SideButtons = Env.load("src/client/UI/Screens/SideButtonsScreen")

local function menuRow(): (any, any, any)
	local rootFrame = UIController.getScreenRoot("SideButtons"):FindFirstChild("Root")
	local menu = rootFrame:FindFirstChild("Menu")
	return menu, menu:FindFirstChild("MenuToggle"), menu:FindFirstChild("Buttons")
end

-- Right edge of the row in canvas units, from the sizes the screen declared:
-- Lune lays nothing out, and these are what the engine would be given.
local function rowRightEdge(): number
	local menu, toggle, list = menuRow()
	local gap = menu:FindFirstChildOfClass("UIListLayout").Padding.Offset
	return menu.Position.X.Offset + toggle.Size.X.Offset + gap + list.Size.X.Offset
end

local function labelOf(name: string): string
	local _, _, list = menuRow()
	return list:FindFirstChild(name).Content.Label.Text
end

SideButtons.setExpanded(true)

for _, viewport in
	{
		{ 640, 294, "the owner's phone" },
		{ 844, 390, "a 844x390 phone" },
		{ 852, 393, "a 852x393 phone" },
		{ 1024, 768, "a 1024x768 tablet" },
		{ 1100, 820, "a 1100x820 tablet" },
		{ 1280, 800, "a 1280x800 tablet" },
		{ 1920, 1080, "a large touch monitor" },
	}
do
	camera.ViewportSize = roblox.Vector2.new(viewport[1], viewport[2])
	UIController.refreshViewport()

	local canvas = viewport[1] / UIController.scale
	local right = rowRightEdge()
	check(
		right <= canvas,
		`{viewport[3]}: the menu row ends at {right}, inside the {string.format("%.0f", canvas)} unit canvas`
	)

	-- Whichever way it fits, all five buttons are still there and pressable.
	local _, _, list = menuRow()
	for _, name in { "Equip", "Shop", "Friends", "Spin", "Settings" } do
		check(list:FindFirstChild(name) ~= nil, `{viewport[3]}: the {name} button exists`)
	end
end

-- Compact where the labels do not fit, labelled where they do: a large screen
-- keeps the words rather than five bare glyphs.
camera.ViewportSize = roblox.Vector2.new(1024, 768)
UIController.refreshViewport()
check(labelOf("Settings") == "", "a 1024 tablet cannot fit the labelled row, so the labels go")
camera.ViewportSize = roblox.Vector2.new(1280, 800)
UIController.refreshViewport()
check(labelOf("Settings") == "НАСТРОЙКИ", "a 1280 tablet has room for the words")
camera.ViewportSize = roblox.Vector2.new(852, 393)
UIController.refreshViewport()
check(labelOf("Settings") == "", "a phone that is not scaled down is compact all the same")
camera.ViewportSize = roblox.Vector2.new(640, 294)
UIController.refreshViewport()
check(labelOf("Settings") == "", "the owner's phone is compact")

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
	error(`{failed} uiscale check(s) failed`, 0)
end
print("  All uiscale checks passed.")
