--!nonstrict
--[[
	Pacing.spec.luau
	Match rhythm: how long a death costs, how a match ends, and whether the parts
	that set the tempo agree with each other.

	MatchStateMachine.spec.luau covers the state machine's behaviour — the phases,
	the transitions, the score limit firing. This file is about whether the
	numbers those rules run on produce a match worth playing:

	  * A deathmatch needs a score to race to. Without one the match ran its full
	    ten minutes whatever the scoreline, so a side well behind at halfway
	    played the rest with nothing left to play for. The target has to sit
	    ABOVE what an even match reaches, or it stops being a mercy rule and
	    becomes the normal way matches end — which would quietly retire the
	    ten-minute limit the game is designed around.

	  * Dying has to cost something without costing the match. Respawn plus the
	    walk back is dead time, and it is paid every death.

	  * Spawn protection has to be shorter than the walk into a fight. Three
	    seconds of invulnerability that lasts until the shooting starts is not
	    protection, it is a free first trade — which is why firing gives it up.

	Distances come from the map defs so the walk times are the real ones rather
	than a guess about map scale.
]]

local Constants = require("../src/shared/Constants")
local DustDef = require("../src/shared/MapDefs/DustDef")
local GameConfig = require("../src/shared/Config/GameConfig")
local MatchStateMachine = require("../src/server/Match/MatchStateMachine")
local MirageDef = require("../src/shared/MapDefs/MirageDef")
local NexusDef = require("../src/shared/MapDefs/NexusDef")

--[[
	Studs from a spawn room's door to the middle of the map — the distance a
	player walks to get back into the fight.
]]
local function spawnToCentre(def): number
	for _, element in def.elements do
		if element.kind == "spawnRoom" then
			local centre = math.sqrt(element.center.x ^ 2 + element.center.z ^ 2)
			return centre - element.size.x / 2
		end
	end
	return 0
end

local function floorArea(def): number
	for _, element in def.elements do
		if element.kind == "floor" then
			return element.size.x * element.size.z
		end
	end
	return 0
end

return function(t)
	local maps = {
		{ name = "Dust", def = DustDef },
		{ name = "Mirage", def = MirageDef },
		{ name = "Nexus", def = NexusDef },
	}

	-- The cost of dying ------------------------------------------------------

	local worstDowntime = 0

	for _, entry in maps do
		local distance = spawnToCentre(entry.def)
		t.expect(distance > 0, `{entry.name} has a measurable walk from spawn to the middle`)

		local walk = distance / Constants.WALK_SPEED
		local downtime = Constants.RESPAWN_SECONDS + walk
		worstDowntime = math.max(worstDowntime, downtime)

		-- Long enough that a death is a real setback...
		t.expect(downtime >= 4, `{entry.name} makes dying cost something ({downtime}s)`)
		-- ...and short enough that it is not a punishment. Past about fifteen
		-- seconds a player spends more of the match walking than fighting.
		t.expect(downtime <= 15, `{entry.name} does not strand a dead player ({downtime}s)`)
	end

	-- Over a whole match, an average player's deaths must still leave most of
	-- the match playable.
	local deathsPerMatch = GameConfig.ASSUMED_KILLS_PER_PLAYER
	local totalDowntime = deathsPerMatch * worstDowntime
	t.expect(
		totalDowntime / GameConfig.MATCH_DURATION <= 0.35,
		`downtime stays under a third of a match ({totalDowntime}s of {GameConfig.MATCH_DURATION}s)`
	)

	-- Spawn protection -------------------------------------------------------

	t.expect(Constants.SPAWN_PROTECTION_SECONDS > 0, "a fresh spawn is protected at all")

	-- It must expire well before a player can walk into a fight, or it covers
	-- the approach rather than the spawn. CombatService also clears it on the
	-- shooter's first shot, which is the part that stops it being carried into
	-- a duel; this bounds the passive case.
	local shortestApproach = math.huge
	for _, entry in maps do
		shortestApproach = math.min(shortestApproach, spawnToCentre(entry.def) / Constants.WALK_SPEED)
	end
	t.expect(
		Constants.SPAWN_PROTECTION_SECONDS < shortestApproach,
		`spawn protection ends before a player reaches the fight ({Constants.SPAWN_PROTECTION_SECONDS}s vs {shortestApproach}s)`
	)

	-- The score limit is a mercy rule ----------------------------------------

	t.expect(GameConfig.SCORE_LIMIT_PER_PLAYER > 0, "a match has a score to race to")

	--[[
		THE CHECK THIS FILE EXISTS FOR.

		An even side finishes a full match near ASSUMED_KILLS_PER_PLAYER x its
		size. If the target sat at or below that, the ordinary end of an ordinary
		match would be the score limit rather than the clock, and the ten-minute
		match the game is designed around would quietly become something shorter
		and variable.
	]]
	t.expect(
		GameConfig.SCORE_LIMIT_PER_PLAYER > GameConfig.ASSUMED_KILLS_PER_PLAYER,
		`the target is above an even match's finishing score ({GameConfig.SCORE_LIMIT_PER_PLAYER} vs {GameConfig.ASSUMED_KILLS_PER_PLAYER})`
	)

	-- ...but not so far above that a genuine slaughter still runs the full time.
	-- A side taking two thirds of the kills reaches the target at this fraction
	-- of a match; past about 95% the rule would never actually fire.
	local evenPaceTotal = GameConfig.ASSUMED_KILLS_PER_PLAYER * 2
	local blowoutShare = 2 / 3
	local fractionWhenBlowoutEnds = GameConfig.SCORE_LIMIT_PER_PLAYER / (evenPaceTotal * blowoutShare)
	t.expect(
		fractionWhenBlowoutEnds <= 0.95,
		`a two-to-one blowout ends early ({fractionWhenBlowoutEnds} of the match)`
	)
	t.expect(
		fractionWhenBlowoutEnds >= 0.5,
		`the target does not cut a match in half ({fractionWhenBlowoutEnds} of the match)`
	)

	-- The target scales, so the same rule works at every lobby size.
	local duel = MatchStateMachine.scoreLimitFor(1, GameConfig.SCORE_LIMIT_PER_PLAYER)
	local full =
		MatchStateMachine.scoreLimitFor(GameConfig.MAX_PLAYERS_PER_MATCH / 2, GameConfig.SCORE_LIMIT_PER_PLAYER)
	t.expect(full > duel, `a full lobby races to a bigger number than a duel ({full} vs {duel})`)
	t.equal(full / duel, GameConfig.MAX_PLAYERS_PER_MATCH / 2, "the target scales in proportion to team size")

	-- Match shape ------------------------------------------------------------

	t.expect(GameConfig.MATCH_DURATION >= 300, "a match is long enough to be worth queueing for")
	t.expect(GameConfig.COUNTDOWN_DURATION > 0, "there is a countdown to get ready in")
	t.expect(GameConfig.RESULTS_DURATION > 0, "the result is shown for long enough to read")

	-- Time spent not playing, per cycle, before any hub time.
	local overhead = GameConfig.COUNTDOWN_DURATION + GameConfig.RESULTS_DURATION
	t.expect(
		overhead / (GameConfig.MATCH_DURATION + overhead) <= 0.1,
		`the countdown and results are a small part of a cycle ({overhead}s)`
	)

	t.expect(GameConfig.MIN_PLAYERS >= 2, "a match needs someone to fight")
	t.expect(GameConfig.MAX_PLAYERS_PER_MATCH % 2 == 0, "a full lobby splits evenly into two teams")
	t.expect(GameConfig.MAX_PLAYERS_PER_MATCH >= GameConfig.MIN_PLAYERS, "the maximum is not below the minimum")

	-- A disconnect-emptied team should not end the match instantly (a brief
	-- reconnect would be punished) nor hold everyone else hostage.
	t.expect(GameConfig.EMPTY_TEAM_GRACE >= 10, "an emptied team gets a grace period")
	t.expect(GameConfig.EMPTY_TEAM_GRACE <= GameConfig.MATCH_DURATION / 4, "an emptied team does not stall the match")

	-- Arena density ----------------------------------------------------------
	-- Too much space per player and a match is a walking simulator. For scale,
	-- CS2's Dust2 is roughly 12,700 studs^2 per player at ten players.

	for _, entry in maps do
		local perPlayer = floorArea(entry.def) / GameConfig.MAX_PLAYERS_PER_MATCH
		t.expect(perPlayer > 0, `{entry.name} has floor area`)
		t.expect(perPlayer <= 12000, `{entry.name} is dense enough at a full lobby ({perPlayer} studs^2 per player)`)
		-- ...and not so tight that a full lobby has nowhere to stand.
		t.expect(perPlayer >= 800, `{entry.name} is not overcrowded at a full lobby ({perPlayer})`)
	end
end
