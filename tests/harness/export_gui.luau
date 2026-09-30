--!nonstrict
--[[
	tests/harness/export_gui.luau
	Boots the whole client the way init.client does and dumps the GUI it built
	to JSON, so tools/render_gui.py can draw it.

	Nothing in this project could show what a screen LOOKS like without opening
	Roblox on the device. Every layout bug on a phone — a button under the jump
	button, a cluster in the middle of the screen, text clipped in a panel — was
	found by the owner holding a phone, then described in words, then fixed from
	the description. This closes that loop: the tree dumped here is the one the
	real modules construct, at the viewport the real device reports.

	Run:  lune run tests/harness/export_gui <device> <scenario> [menu] > gui.json
	      device:   phone | widephone | tablet | widetablet | desktop
	      scenario: hub | queue | match | dead | results
	      menu:     optional menu name to open (Shop, Equip, Spin, Friends,
	                Settings, Welcome, Side)
]]

local Env = require("./env")
local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")

local device = process.args[1] or "phone"
local scenario = process.args[2] or "match"
local menu = process.args[3]

local VIEWPORTS = {
	-- What a landscape phone's Roblox viewport reports, NOT its pixel count.
	phone = { 640, 294 },
	-- A current phone on its side (852x393 is an iPhone Pro Max): tall enough
	-- and wide enough that no UIScale applies, which is exactly the size the
	-- phone layouts were never drawn at.
	widephone = { 852, 393 },
	tablet = { 1024, 768 },
	-- A large tablet, or a touchscreen with room to spare.
	widetablet = { 1280, 800 },
	desktop = { 1920, 1080 },
}
local viewport = VIEWPORTS[device] or VIEWPORTS.phone

Env.setDevice(if device == "desktop" then "desktop" else "phone")
Env.enableClientRuntime()

--[[
	Tweens land on their end values at once. The shared sandbox's TweenService
	does nothing at all, which is right for the behavioural checks (they must
	not depend on an animation finishing) but wrong for a picture: every panel
	would be drawn at its 0.92 "closed" scale behind a fully transparent
	overlay — the frame before the animation, not the screen a player sees.
	Completed fires after the goals are applied, as it would when a real tween
	runs out, so a close that hides its panel on completion still hides it.
]]
local tweenService = Env.service("TweenService")
tweenService.Create = function(_self, instance, _info, goals)
	local completed = Env.liveSignal()
	return {
		Play = function()
			for property, value in goals do
				pcall(function()
					(instance :: any)[property] = value
				end)
			end
			completed:Fire(roblox.Enum.PlaybackState.Completed)
		end,
		Cancel = function() end,
		Pause = function() end,
		Completed = completed,
	}
end

local camera = Env.service("Workspace").CurrentCamera
camera.ViewportSize = roblox.Vector2.new(viewport[1], viewport[2])

local player = Env.service("Players").LocalPlayer

-- Chatter from the modules goes to stderr so stdout stays pure JSON.
local function quiet(fn)
	local ok, err = pcall(fn)
	if not ok then
		stdio.ewrite(`[export_gui] {err}\n`)
	end
	return ok
end

--------------------------------------------------------------------------------
-- Boot, exactly as the Loader does: every module under a root (recursing into
-- plain folders), sorted by Priority then name, init() all, then start() all.
--------------------------------------------------------------------------------

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
		if ok and type(value) == "table" then
			table.insert(loaded, {
				name = path:match("([^/]+)$"),
				value = value,
				priority = if type(value.Priority) == "number" then value.Priority else 100,
			})
		elseif not ok then
			stdio.ewrite(`[export_gui] load {path}: {value}\n`)
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
			quiet(entry.value.init)
		end
	end
	for _, entry in loaded do
		if type(entry.value.start) == "function" then
			Env.spawn(function()
				quiet(entry.value.start)
			end)
		end
	end
end

boot("src/client/Controllers")
boot("src/client/UI")

local ClientState = Env.load("src/client/ClientState")
local UIController = Env.load("src/client/UI/UIController")

--------------------------------------------------------------------------------
-- Put the client in the state the scenario describes, through the same
-- attributes and signals the server would drive.
--------------------------------------------------------------------------------

player:SetAttribute("Loaded", true)
player:SetAttribute("Coins", 1250)
ClientState.coins = 1250
ClientState.stats = { MatchesPlayed = 7, Kills = 41, Deaths = 30, Wins = 4 }
-- A player a few matches in: two skins bought, one of them on the rifle, so
-- the skin screens show real rows instead of a lone default.
ClientState.ownedSkins = { crimson = true, arctic = true }
ClientState.equippedSkins = { Rifle = "crimson", Pistol = "default", Lance = "default" }
ClientState.CoinsChanged:Fire(1250, 0, "boot")
ClientState.ProfileChanged:Fire({ stats = ClientState.stats })

if scenario == "queue" then
	ClientState.queue = { mapId = "Dust", count = 1, needed = 2 }
	ClientState.QueueChanged:Fire("Dust", 1, 2, nil)
end

if scenario ~= "hub" and scenario ~= "queue" then
	player:SetAttribute("TeamId", "A")
	player:SetAttribute("CurrentWeapon", "Rifle")
	player:SetAttribute("SessionKills", 6)
	player:SetAttribute("InMatch", "Dust")

	ClientState.match.mapId = "Dust"
	ClientState.match.phase = if scenario == "results" then "Results" else "InProgress"
	ClientState.match.timeLeft = 437
	ClientState.match.scores = { A = 23, B = 19 }
	ClientState.match.data = {
		timeLeft = 437,
		scores = { A = 23, B = 19 },
		-- Field names as MatchRuntime broadcasts them for Results.
		winnerTeam = if scenario == "results" then "A" else nil,
		rewards = if scenario == "results" then { [tostring(player.UserId)] = 325 } else nil,
	}
	ClientState.MatchChanged:Fire(ClientState.match)

	ClientState.ammo = { weaponId = "Rifle", mag = 17, magSize = 30, reloading = false, ackSeq = 0 }
	ClientState.AmmoChanged:Fire(ClientState.ammo)

	-- The side question opens on entering a match; answer it so the scenario
	-- shows the match, not the question. Ask for it by name to see it.
	if menu ~= "Side" then
		UIController.closeMenu("Side")
	end

	for index, line in
		{
			{ "Nurik", "A", "Viper_22", "B", "Rifle", true },
			{ "Kotik", "B", "Nurik", "A", "Pistol", false },
			{ "Dima007", "A", "xXShadowXx", "B", "Rifle", false },
			-- Display names run to 20 characters; the feed has to survive two.
			{ "xX_ProSniperKing_Xx", "B", "Super_Long_Name_2011", "A", "Lance", true },
		}
	do
		ClientState.KillFeed:Fire({
			killerName = line[1],
			killerTeam = line[2],
			victimName = line[3],
			victimTeam = line[4],
			weaponId = line[5],
			isHeadshot = line[6],
			at = index,
		})
	end
end

if scenario == "dead" then
	ClientState.isDead = true
	ClientState.Died:Fire(nil, 3)
end

-- "SideMenu" is not a panel: it is the side-button stack folded open, which is
-- what a phone player sees after tapping the ☰ toggle.
if menu == "SideMenu" then
	Env.load("src/client/UI/Screens/SideButtonsScreen").setExpanded(true)
elseif menu and menu ~= "" then
	UIController.openMenu(menu)
end

-- Let anything scheduled (delayed opens, countdown first ticks) run.
Env.advance(0.5)

--------------------------------------------------------------------------------
-- Dump
--------------------------------------------------------------------------------

local function rgb(color): { number }?
	if typeof(color) ~= "Color3" then
		return nil
	end
	return { math.round(color.R * 255), math.round(color.G * 255), math.round(color.B * 255) }
end

local function udim2(value): { number }?
	if typeof(value) ~= "UDim2" then
		return nil
	end
	return { value.X.Scale, value.X.Offset, value.Y.Scale, value.Y.Offset }
end

local function udim(value): { number }?
	if typeof(value) ~= "UDim" then
		return nil
	end
	return { value.Scale, value.Offset }
end

local function vec2(value): { number }?
	if typeof(value) ~= "Vector2" then
		return nil
	end
	return { value.X, value.Y }
end

local function enumName(value): string?
	if typeof(value) == "EnumItem" then
		return value.Name
	end
	return nil
end

local function read(instance: Instance, property: string): any
	local ok, value = pcall(function()
		return (instance :: any)[property]
	end)
	return if ok then value else nil
end

local GUI_OBJECTS = {
	Frame = true,
	TextLabel = true,
	TextButton = true,
	TextBox = true,
	ImageLabel = true,
	ImageButton = true,
	ScrollingFrame = true,
	CanvasGroup = true,
	ViewportFrame = true,
}

local function dumpModifier(child: Instance): any?
	local class = child.ClassName
	if class == "UIListLayout" then
		return {
			class = class,
			fill = enumName(read(child, "FillDirection")),
			h = enumName(read(child, "HorizontalAlignment")),
			v = enumName(read(child, "VerticalAlignment")),
			sort = enumName(read(child, "SortOrder")),
			padding = udim(read(child, "Padding")),
			wraps = read(child, "Wraps"),
		}
	elseif class == "UIGridLayout" then
		return {
			class = class,
			cellSize = udim2(read(child, "CellSize")),
			cellPadding = udim2(read(child, "CellPadding")),
			fill = enumName(read(child, "FillDirection")),
			h = enumName(read(child, "HorizontalAlignment")),
			v = enumName(read(child, "VerticalAlignment")),
			sort = enumName(read(child, "SortOrder")),
		}
	elseif class == "UIPadding" then
		return {
			class = class,
			left = udim(read(child, "PaddingLeft")),
			right = udim(read(child, "PaddingRight")),
			top = udim(read(child, "PaddingTop")),
			bottom = udim(read(child, "PaddingBottom")),
		}
	elseif class == "UIScale" then
		return { class = class, scale = read(child, "Scale") }
	elseif class == "UICorner" then
		return { class = class, radius = udim(read(child, "CornerRadius")) }
	elseif class == "UIStroke" then
		return {
			class = class,
			color = rgb(read(child, "Color")),
			thickness = read(child, "Thickness"),
			transparency = read(child, "Transparency"),
			mode = enumName(read(child, "ApplyStrokeMode")),
			enabled = read(child, "Enabled"),
		}
	elseif class == "UISizeConstraint" then
		return { class = class, min = vec2(read(child, "MinSize")), max = vec2(read(child, "MaxSize")) }
	elseif class == "UIAspectRatioConstraint" then
		return {
			class = class,
			ratio = read(child, "AspectRatio"),
			dominant = enumName(read(child, "DominantAxis")),
			aspectType = enumName(read(child, "AspectType")),
		}
	elseif class == "UITextSizeConstraint" then
		return { class = class, min = read(child, "MinTextSize"), max = read(child, "MaxTextSize") }
	elseif class == "UIGradient" then
		local sequence = read(child, "Color")
		local stops = {}
		if typeof(sequence) == "ColorSequence" then
			for _, keypoint in sequence.Keypoints do
				table.insert(stops, { keypoint.Time, rgb(keypoint.Value) })
			end
		end
		local transparency = read(child, "Transparency")
		local tstops = {}
		if typeof(transparency) == "NumberSequence" then
			for _, keypoint in transparency.Keypoints do
				table.insert(tstops, { keypoint.Time, keypoint.Value })
			end
		end
		return {
			class = class,
			stops = stops,
			transparency = tstops,
			rotation = read(child, "Rotation"),
			enabled = read(child, "Enabled"),
		}
	end
	return nil
end

local function dump(instance: Instance): any?
	local class = instance.ClassName
	if not GUI_OBJECTS[class] then
		return nil
	end

	local node: any = {
		class = class,
		name = instance.Name,
		position = udim2(read(instance, "Position")),
		size = udim2(read(instance, "Size")),
		anchor = vec2(read(instance, "AnchorPoint")),
		visible = read(instance, "Visible"),
		z = read(instance, "ZIndex"),
		order = read(instance, "LayoutOrder"),
		bg = rgb(read(instance, "BackgroundColor3")),
		bgT = read(instance, "BackgroundTransparency"),
		rotation = read(instance, "Rotation"),
		clips = read(instance, "ClipsDescendants"),
		autoSize = enumName(read(instance, "AutomaticSize")),
		modifiers = {},
		children = {},
	}

	if class == "TextLabel" or class == "TextButton" or class == "TextBox" then
		node.text = read(instance, "Text")
		node.textColor = rgb(read(instance, "TextColor3"))
		node.textT = read(instance, "TextTransparency")
		node.textSize = read(instance, "TextSize")
		node.textScaled = read(instance, "TextScaled")
		node.textWrapped = read(instance, "TextWrapped")
		node.font = enumName(read(instance, "Font"))
		node.xAlign = enumName(read(instance, "TextXAlignment"))
		node.yAlign = enumName(read(instance, "TextYAlignment"))
		node.strokeT = read(instance, "TextStrokeTransparency")
		node.strokeColor = rgb(read(instance, "TextStrokeColor3"))
		node.rich = read(instance, "RichText")
		node.truncate = enumName(read(instance, "TextTruncate"))
		node.lineHeight = read(instance, "LineHeight")
	end
	if class == "ImageLabel" or class == "ImageButton" then
		node.image = read(instance, "Image")
		node.imageColor = rgb(read(instance, "ImageColor3"))
		node.imageT = read(instance, "ImageTransparency")
	end
	if class == "CanvasGroup" then
		node.groupT = read(instance, "GroupTransparency")
	end
	if class == "ScrollingFrame" then
		node.canvas = udim2(read(instance, "CanvasSize"))
		node.autoCanvas = enumName(read(instance, "AutomaticCanvasSize"))
	end

	for _, child in instance:GetChildren() do
		local modifier = dumpModifier(child)
		if modifier then
			table.insert(node.modifiers, modifier)
		else
			local sub = dump(child)
			if sub then
				table.insert(node.children, sub)
			end
		end
	end

	return node
end

local screens = {}
for _, gui in player.PlayerGui:GetChildren() do
	if gui.ClassName ~= "ScreenGui" then
		continue
	end
	local entry: any = {
		name = gui.Name,
		enabled = read(gui, "Enabled"),
		order = read(gui, "DisplayOrder"),
		ignoreInset = read(gui, "IgnoreGuiInset"),
		modifiers = {},
		children = {},
	}
	for _, child in gui:GetChildren() do
		local modifier = dumpModifier(child)
		if modifier then
			table.insert(entry.modifiers, modifier)
		else
			local sub = dump(child)
			if sub then
				table.insert(entry.children, sub)
			end
		end
	end
	table.insert(screens, entry)
end

print(serde.encode("json", {
	device = device,
	scenario = scenario,
	menu = menu,
	viewport = viewport,
	-- Roblox's own chrome the game draws around: the top bar strip, and on a
	-- phone the thumbstick and jump button. Drawn by the renderer as guides so
	-- overlaps with them are visible.
	touch = device ~= "desktop",
	screens = screens,
}, false))
