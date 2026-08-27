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

--[[
	What an average player is assumed to score in a full match.

	A design assumption, not a measurement — there is nothing to measure until
	the game is live. It is stated here rather than buried in a test because
	several unrelated decisions lean on it: the coin prices are set so a skin
	costs a known number of matches, and the score limit below is set above it so
	it stays a mercy rule. If those two disagreed about the pace of a match, the
	shop would be tuned for a game the match rules do not produce.

	AnalyticsService already reports kills per match, so this is the number to
	replace with real data first.
]]
GameConfig.ASSUMED_KILLS_PER_PLAYER = 15

--[[
	Kills per player on a side that end the match early. The target is this times
	the size of the larger team, so it scales with the pace: a fixed number that
	gives an 8v8 a real race would be reached in the first minute of a 1v1.

	This is a mercy rule, not the normal way a match ends. Without it the match
	ran the full ten minutes whatever the scoreline, so a side 80-20 down at the
	halfway mark played five more minutes with nothing left to play for. The
	value sits above what an even match reaches — the economy model's average
	player takes 15 kills in a full match, so an even side finishes near
	15 x teamSize — which means a competitive game still ends on the clock and
	only a side running away with it ends early.
]]
GameConfig.SCORE_LIMIT_PER_PLAYER = 18

-- Broadcast cadence for the HUD timer/score (unreliable, 1 Hz).
GameConfig.TICK_INTERVAL = 1

--[[
	Idle removal. A player who has neither moved nor fired for this long is
	warned, then returned to the hub.

	An idle player in a team mode costs more than their own experience: they are
	free kills, they make it seven against eight, they raise the kill target for
	both sides (it scales off the larger roster and never falls once raised), and
	they take the end-of-match payout for standing still — which breaks the
	economy's assumption that coins come from playing.

	The thresholds are generous on purpose. Firing counts as activity, so a
	marksman holding a lane with the Arc Lance is not caught; being caught needs
	both hands off for over a minute of a ten-minute match.
]]
GameConfig.IDLE_WARN_SECONDS = 45
GameConfig.IDLE_REMOVE_SECONDS = 75

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
