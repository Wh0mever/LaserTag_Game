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

--[[
	The name players see. Deliberately NOT the same string as anything stored:
	GameConfig.PROFILE_STORE_NAME, the DataStore key and the internal instance
	names all keep "LaserTag" for good, because renaming a DataStore key does not
	move the data — it points every player at an empty store, which reads as
	every coin and skin in the game vanishing at once.

	The Roblox experience title is set on the Creator Hub and cannot be written
	from a place file, so this constant does not control it; the two are kept in
	step by hand. It drives what is rendered inside the game — today the hub
	gateway sign, which is the only place a player is shown the name at all.
]]
Constants.GAME_NAME = "SKILLANDIA LASERTAG"

Constants.VERSION = "v1.0"

-- Character / combat baseline
Constants.MAX_HEALTH = 100
Constants.WALK_SPEED = 18
Constants.JUMP_POWER = 50
Constants.RESPAWN_SECONDS = 3
Constants.SPAWN_PROTECTION_SECONDS = 3
-- How long a player entering a match has to pick a side. The question is on
-- screen for this long, the server accepts a switch for this long (plus a
-- little for the round trip) and not after, and the player is protected for
-- this long on entry — they cannot shoot while the question is up, so without
-- that they would be a target that cannot answer back. Firing ends the
-- protection early, exactly as it does on a normal spawn.
Constants.SIDE_CHOICE_SECONDS = 10
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
	-- V for view. Also reachable from the settings panel; a shooter's camera is
	-- something players flip mid-fight, not something they open a menu for.
	Perspective = "V",
	MouseUnlock = "RightControl",
	Scoreboard = "Tab",
}

-- UI layering (higher renders on top).
Constants.DISPLAY_ORDER = {
	Background = 1,
	HUD = 10,
	KillFeed = 12,
	-- Above the HUD so a thumb never lands on a readout, below the menus so an
	-- open panel covers the controls rather than being shot through.
	TouchControls = 14,
	SideButtons = 15,
	Toast = 50,
	Menu = 80,
	Results = 90,
	Modal = 100,
}

--[[
	How the interface shrinks on small screens. See UIController.computeScale.

	The scale is the smaller of height / UI_REFERENCE_HEIGHT and
	width / UI_REFERENCE_WIDTH, clamped to [UI_MIN_SCALE, 1]. HEIGHT leads
	because a phone is held sideways: Roblox reports a typical one as about
	640x294, which is wide enough to pass for a small laptop and a third as tall
	as a monitor. The rule this replaced shrank the UI only below 600 wide, so
	it never fired on a real phone and every panel was drawn at monitor size
	on a screen 294 tall — the shop's buy buttons fell off the bottom and the
	settings header buttons slid across the title.
]]
Constants.UI_REFERENCE_HEIGHT = 360
Constants.UI_REFERENCE_WIDTH = 700
Constants.UI_MIN_SCALE = 0.7

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
