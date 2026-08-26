--!nonstrict
--[[
	GameConfig.luau
	Match pacing, queue rules and world coordinates. Pure data.
]]

local GameConfig = {}

-- Match pacing ------------------------------------------------------------

GameConfig.MATCH_DURATION = 600 -- 10 minutes of team deathmatch
GameConfig.COUNTDOWN_DURATION = 10
GameConfig.RESULTS_DURATION = 10
GameConfig.MIN_PLAYERS = 2
GameConfig.MAX_PLAYERS_PER_MATCH = 16

-- If one team is emptied by disconnects, the other side wins after this grace
-- period rather than the match dragging on against nobody.
GameConfig.EMPTY_TEAM_GRACE = 30

-- Broadcast cadence for the HUD timer/score (unreliable, 1 Hz).
GameConfig.TICK_INTERVAL = 1

-- Queue ------------------------------------------------------------------

-- How often the server samples the portal pads for players standing on them.
GameConfig.QUEUE_POLL_INTERVAL = 0.5

-- World layout ------------------------------------------------------------
-- Everything lives in one place; maps are simply far apart in Workspace and
-- players are moved with PivotTo. Keeping them >=1500 studs apart means no
-- stray raycast or explosion can ever reach across maps.

GameConfig.MAP_ORIGINS = {
	Hub = { x = 0, y = 0, z = 0 },
	Dust = { x = 2000, y = 0, z = 0 },
	Mirage = { x = 4000, y = 0, z = 0 },
	Nexus = { x = 6000, y = 0, z = 0 },
}

GameConfig.MIN_MAP_SEPARATION = 1500

-- Absolute Y below which a character dies (per map, relative to its origin).
GameConfig.DEFAULT_KILL_Y = -60

-- How often the kill-plane watchdog samples characters.
GameConfig.KILL_PLANE_INTERVAL = 0.5

-- Persistence -------------------------------------------------------------

GameConfig.PROFILE_STORE_NAME = "LaserTagProfile_v1"
GameConfig.LEADERBOARD_STORE_NAME = "TopKills_v1"
GameConfig.LEADERBOARD_SIZE = 100
GameConfig.LEADERBOARD_UPDATE_INTERVAL = 120

-- Friends panel cache lifetime.
GameConfig.FRIENDS_CACHE_SECONDS = 30

return GameConfig
