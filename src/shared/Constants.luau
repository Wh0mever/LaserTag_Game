--!nonstrict
--[[
	Constants.luau
	Values shared by the server and the client. Anything the client is allowed
	to know lives here; secrets (drop rates that must not be readable, internal
	anti-cheat thresholds) stay on the server.

	Colours are plain {r, g, b} tables (0-255) so this module stays free of
	Roblox constructors and can be required by the off-Roblox test runner.
]]

local Constants = {}

Constants.VERSION = "v1.0"

-- Character / combat baseline
Constants.MAX_HEALTH = 100
Constants.WALK_SPEED = 18
Constants.JUMP_POWER = 50
Constants.RESPAWN_SECONDS = 3
Constants.SPAWN_PROTECTION_SECONDS = 3
Constants.HEAD_OFFSET_Y = 1.5 -- eye height above HumanoidRootPart

-- Teams. Team A is green, Team B is magenta/pink (matches the HUD score chips).
Constants.TEAMS = {
	A = { id = "A", name = "Альфа", color = { r = 45, g = 216, b = 129 }, brickColor = "Bright green" },
	B = { id = "B", name = "Браво", color = { r = 235, g = 87, b = 158 }, brickColor = "Hot pink" },
	LOBBY = {
		id = "LOBBY",
		name = "Лобби",
		color = { r = 160, g = 160, b = 170 },
		brickColor = "Medium stone grey",
	},
}

Constants.TEAM_IDS = { "A", "B" }

-- Weapon slots. Slot 1 is the rifle (primary), slot 2 the pistol (secondary),
-- slot 3 the long-range lance.
Constants.SLOTS = {
	[1] = "Rifle",
	[2] = "Pistol",
	[3] = "Lance",
}
Constants.DEFAULT_SLOT = 1

-- Maps. Ids are used as folder names, match keys and portal targets.
Constants.MAPS = { "Dust", "Mirage", "Nexus" }
Constants.HUB_ID = "Hub"

-- Keybinds (PC). Mobile uses ContextActionService buttons instead.
Constants.KEYBINDS = {
	Reload = "R",
	Slot1 = "One",
	Slot2 = "Two",
	Slot3 = "Three",
	Equip = "E",
	Shop = "Q",
	Friends = "F",
	Spin = "P",
	-- O for options. Escape is not available: Roblox reserves it for its own
	-- menu and a game cannot take it.
	Settings = "O",
	MouseUnlock = "RightControl",
	Scoreboard = "Tab",
}

-- UI layering (higher renders on top).
Constants.DISPLAY_ORDER = {
	Background = 1,
	HUD = 10,
	KillFeed = 12,
	SideButtons = 15,
	Toast = 50,
	Menu = 80,
	Results = 90,
	Modal = 100,
}

-- Viewport width below which the UI scales down for phones.
Constants.SMALL_SCREEN_WIDTH = 600
Constants.SMALL_SCREEN_UI_SCALE = 0.8

-- Default remote rate limiting. Individual remotes override these.
Constants.REMOTE_DEFAULTS = {
	maxRequests = 20,
	windowSeconds = 5,
	cooldownSeconds = 2,
	kickAfterViolations = 5,
	kickMessage = "Too many requests. Please rejoin.",
}

-- Kill feed / damage display tuning.
Constants.KILL_FEED_DURATION = 6
Constants.DAMAGE_NUMBER_DURATION = 0.9
Constants.HITMARKER_DURATION = 0.2

return Constants
