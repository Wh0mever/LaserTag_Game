--!nonstrict
local Constants = require("../src/shared/Constants")
local GameConfig = require("../src/shared/Config/GameConfig")
local MatchStateMachine = require("../src/server/Match/MatchStateMachine")

-- Short, distinct durations: every phase length below is unique so an assertion
-- about "the match ended" can never accidentally pass because two timers happen
-- to be the same number.
local CONFIG = {
	minPlayers = 2,
	countdownDuration = 3,
	matchDuration = 20,
	resultsDuration = 5,
	emptyTeamGrace = 6,
}

local function findEffect(effects, effectType: string)
	for _, effect in effects do
		if effect.type == effectType then
			return effect
		end
	end
	return nil
end

local function countEffects(effects, effectType: string): number
	local total = 0
	for _, effect in effects do
		if effect.type == effectType then
			total += 1
		end
	end
	return total
end

local function broadcastFor(effects, phase: string)
	for _, effect in effects do
		if effect.type == "broadcast" and effect.phase == phase then
			return effect
		end
	end
	return nil
end

-- Drive a state to InProgress with `count` players queued, discarding the
-- effects the ramp-up produces.
local function startedMatch(count: number)
	local state = MatchStateMachine.new(CONFIG)
	MatchStateMachine.handle(state, { type = "queueChanged", count = count })
	MatchStateMachine.handle(state, { type = "tick", dt = CONFIG.countdownDuration })
	return state
end

return function(t)
	-- The pure module cannot require the real config, so the two must be checked
	-- against each other or they will silently drift apart.
	t.equal(MatchStateMachine.DEFAULTS.minPlayers, GameConfig.MIN_PLAYERS, "DEFAULTS.minPlayers tracks GameConfig")
	t.equal(
		MatchStateMachine.DEFAULTS.countdownDuration,
		GameConfig.COUNTDOWN_DURATION,
		"DEFAULTS.countdownDuration tracks GameConfig"
	)
	t.equal(
		MatchStateMachine.DEFAULTS.matchDuration,
		GameConfig.MATCH_DURATION,
		"DEFAULTS.matchDuration tracks GameConfig"
	)
	t.equal(
		MatchStateMachine.DEFAULTS.resultsDuration,
		GameConfig.RESULTS_DURATION,
		"DEFAULTS.resultsDuration tracks GameConfig"
	)
	t.equal(
		MatchStateMachine.DEFAULTS.emptyTeamGrace,
		GameConfig.EMPTY_TEAM_GRACE,
		"DEFAULTS.emptyTeamGrace tracks GameConfig"
	)
	t.deepEqual(MatchStateMachine.TEAM_IDS, Constants.TEAM_IDS, "TEAM_IDS tracks Constants")

	-- A bad config must not produce a match that ends on its first tick.
	local defaulted = MatchStateMachine.new({ matchDuration = -5, resultsDuration = "soon" })
	t.equal(defaulted.config.matchDuration, GameConfig.MATCH_DURATION, "a negative duration falls back to the default")
	t.equal(defaulted.config.resultsDuration, GameConfig.RESULTS_DURATION, "a non-number falls back to the default")

	--------------------------------------------------------------------------
	-- Happy path: Idle -> WaitingForPlayers -> Countdown -> InProgress ->
	--             Results -> Idle
	--------------------------------------------------------------------------

	local state = MatchStateMachine.new(CONFIG)
	t.equal(state.phase, "Idle", "a new state starts Idle")

	local _, effects = MatchStateMachine.handle(state, { type = "queueChanged", count = 1 })
	t.equal(state.phase, "WaitingForPlayers", "one queued player leaves Idle")
	local waiting = broadcastFor(effects, "WaitingForPlayers")
	t.expect(waiting ~= nil, "entering WaitingForPlayers broadcasts")
	t.equal(waiting and waiting.data.queued, 1, "the WaitingForPlayers payload carries the queue count")
	t.equal(waiting and waiting.data.needed, CONFIG.minPlayers, "the WaitingForPlayers payload carries MIN_PLAYERS")

	_, effects = MatchStateMachine.handle(state, { type = "queueChanged", count = 2 })
	t.equal(state.phase, "Countdown", "reaching MIN_PLAYERS starts the countdown")
	local countdown = broadcastFor(effects, "Countdown")
	t.expect(countdown ~= nil, "entering Countdown broadcasts")
	t.equal(
		countdown and countdown.data.secondsLeft,
		CONFIG.countdownDuration,
		"the countdown starts at its full length"
	)

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = 1 })
	t.equal(state.phase, "Countdown", "the countdown is still running after one second")
	local ticked = broadcastFor(effects, "Countdown")
	t.equal(ticked and ticked.data.secondsLeft, 2, "each whole second of countdown is broadcast")

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = 0.25 })
	t.equal(#effects, 0, "a partial second inside the countdown broadcasts nothing")

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = 5 })
	t.equal(state.phase, "InProgress", "the countdown running out starts the match")
	local startMatch = findEffect(effects, "startMatch")
	t.expect(startMatch ~= nil, "starting the match emits startMatch")
	t.equal(startMatch and startMatch.queued, 2, "startMatch carries the queued head count")
	t.equal(state.queued, 0, "the queue count is consumed by the start")

	local inProgress = broadcastFor(effects, "InProgress")
	t.expect(inProgress ~= nil, "entering InProgress broadcasts")
	t.equal(inProgress and inProgress.data.timeLeft, CONFIG.matchDuration, "InProgress announces the full match length")
	t.equal(inProgress and inProgress.data.scores.A, 0, "InProgress announces a zeroed score")
	t.equal(effects[1].type, "startMatch", "startMatch is applied before the InProgress broadcast")

	MatchStateMachine.handle(state, { type = "playerLeft", remainingA = 1, remainingB = 1 })
	t.equal(state.remaining.A, 1, "the roster report is recorded")

	--------------------------------------------------------------------------
	-- Kills accumulate per team
	--------------------------------------------------------------------------

	for _ = 1, 3 do
		MatchStateMachine.handle(state, { type = "kill", teamId = "A" })
	end
	MatchStateMachine.handle(state, { type = "kill", teamId = "B" })
	MatchStateMachine.handle(state, { type = "kill", teamId = "Nonsense" })

	t.equal(state.scores.A, 3, "kills credited to A accumulate on A")
	t.equal(state.scores.B, 1, "kills credited to B accumulate on B")

	--------------------------------------------------------------------------
	-- Time expiry picks the leader, then Results returns everyone to the hub
	--------------------------------------------------------------------------

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = CONFIG.matchDuration })
	t.equal(state.phase, "Results", "the match clock running out ends the match")

	local ended = findEffect(effects, "endMatch")
	t.expect(ended ~= nil, "time expiry emits endMatch")
	t.equal(ended and ended.winnerTeam, "A", "the higher score wins")
	t.equal(ended and ended.scores.A, 3, "endMatch carries the final scores")
	t.equal(ended and ended.aborted, false, "a played-out match is not aborted")
	t.equal(
		broadcastFor(effects, "Results"),
		nil,
		"the Results broadcast is left to the runtime, which knows the rewards"
	)

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = 1 })
	t.equal(state.phase, "Results", "Results holds for its full duration")
	t.equal(#effects, 0, "no effects are produced while Results is still running")

	_, effects = MatchStateMachine.handle(state, { type = "tick", dt = CONFIG.resultsDuration })
	t.equal(state.phase, "Idle", "Results expiring returns to Idle")
	t.expect(broadcastFor(effects, "Idle") ~= nil, "returning to Idle broadcasts")
	t.expect(findEffect(effects, "returnToHub") ~= nil, "returning to Idle sends the roster to the hub")
	t.expect(findEffect(effects, "resetQueue") ~= nil, "returning to Idle drops the queue")
	t.equal(effects[1].type, "broadcast", "the Idle broadcast goes out before the roster is emptied")

	--------------------------------------------------------------------------
	-- Countdown aborts when the queue drops below MIN_PLAYERS
	--------------------------------------------------------------------------

	local aborting = MatchStateMachine.new(CONFIG)
	MatchStateMachine.handle(aborting, { type = "queueChanged", count = 2 })
	t.equal(aborting.phase, "Countdown", "the countdown is running before the drop")

	_, effects = MatchStateMachine.handle(aborting, { type = "queueChanged", count = 1 })
	t.equal(aborting.phase, "WaitingForPlayers", "dropping below MIN_PLAYERS cancels the countdown")
	t.expect(broadcastFor(effects, "WaitingForPlayers") ~= nil, "the cancelled countdown broadcasts the new phase")

	MatchStateMachine.handle(aborting, { type = "tick", dt = CONFIG.countdownDuration * 2 })
	t.equal(aborting.phase, "WaitingForPlayers", "a cancelled countdown does not keep counting down")

	MatchStateMachine.handle(aborting, { type = "queueChanged", count = 2 })
	t.equal(aborting.phase, "Countdown", "refilling the queue restarts the countdown")
	t.equal(aborting.timeLeft, CONFIG.countdownDuration, "the restarted countdown starts from the top")

	--------------------------------------------------------------------------
	-- Emptying the queue returns to Idle
	--------------------------------------------------------------------------

	_, effects = MatchStateMachine.handle(aborting, { type = "queueChanged", count = 0 })
	t.equal(aborting.phase, "Idle", "an empty queue returns to Idle")
	t.expect(broadcastFor(effects, "Idle") ~= nil, "returning to Idle from the queue broadcasts")

	_, effects = MatchStateMachine.handle(aborting, { type = "queueChanged", count = 0 })
	t.equal(#effects, 0, "an already-idle map does not re-broadcast Idle")

	--------------------------------------------------------------------------
	-- Level scores are a draw
	--------------------------------------------------------------------------

	local drawn = startedMatch(4)
	MatchStateMachine.handle(drawn, { type = "playerLeft", remainingA = 2, remainingB = 2 })
	MatchStateMachine.handle(drawn, { type = "kill", teamId = "A" })
	MatchStateMachine.handle(drawn, { type = "kill", teamId = "B" })

	_, effects = MatchStateMachine.handle(drawn, { type = "tick", dt = CONFIG.matchDuration })
	local drawEnd = findEffect(effects, "endMatch")
	t.expect(drawEnd ~= nil, "a drawn match still ends")
	t.equal(drawEnd and drawEnd.winnerTeam, nil, "equal scores produce no winner")
	t.equal(drawn.winnerTeam, nil, "the drawn state records no winner")
	t.equal(MatchStateMachine.winnerFromScores({ A = 5, B = 5 }), nil, "winnerFromScores calls a level score a draw")
	t.equal(MatchStateMachine.winnerFromScores({ A = 0, B = 1 }), "B", "winnerFromScores picks the leader")

	--------------------------------------------------------------------------
	-- One team emptied: the survivors win once the grace period expires
	--------------------------------------------------------------------------

	local deserted = startedMatch(4)
	MatchStateMachine.handle(deserted, { type = "playerLeft", remainingA = 2, remainingB = 2 })
	MatchStateMachine.handle(deserted, { type = "kill", teamId = "B" })

	_, effects = MatchStateMachine.handle(deserted, { type = "playerLeft", remainingA = 2, remainingB = 0 })
	t.equal(deserted.phase, "InProgress", "an emptied team does not end the match immediately")
	t.equal(deserted.emptyTeamTimeLeft, CONFIG.emptyTeamGrace, "an emptied team opens the grace timer")
	t.equal(#effects, 0, "opening the grace timer produces no effects")

	MatchStateMachine.handle(deserted, { type = "tick", dt = CONFIG.emptyTeamGrace - 1 })
	t.equal(deserted.phase, "InProgress", "the match survives until the grace period is up")

	-- A team that refills before the grace expires cancels the countdown to the
	-- early finish entirely.
	MatchStateMachine.handle(deserted, { type = "playerLeft", remainingA = 2, remainingB = 1 })
	t.equal(deserted.emptyTeamTimeLeft, nil, "a refilled team clears the grace timer")
	MatchStateMachine.handle(deserted, { type = "tick", dt = CONFIG.emptyTeamGrace })
	t.equal(deserted.phase, "InProgress", "a refilled team keeps the match alive")

	_, effects = MatchStateMachine.handle(deserted, { type = "playerLeft", remainingA = 2, remainingB = 0 })
	t.equal(deserted.emptyTeamTimeLeft, CONFIG.emptyTeamGrace, "emptying again reopens the grace timer")

	_, effects = MatchStateMachine.handle(deserted, { type = "tick", dt = CONFIG.emptyTeamGrace })
	t.equal(deserted.phase, "Results", "the grace period expiring ends the match")

	local desertedEnd = findEffect(effects, "endMatch")
	t.expect(desertedEnd ~= nil, "an emptied team emits endMatch")
	t.equal(desertedEnd and desertedEnd.winnerTeam, "A", "the side still standing wins even while behind on score")
	t.equal(desertedEnd and desertedEnd.aborted, false, "an early finish still pays out")

	--------------------------------------------------------------------------
	-- Emptied roster: abort straight to Idle, no rewards, no Results
	--------------------------------------------------------------------------

	local emptied = startedMatch(2)
	MatchStateMachine.handle(emptied, { type = "playerLeft", remainingA = 1, remainingB = 1 })
	MatchStateMachine.handle(emptied, { type = "kill", teamId = "A" })

	_, effects = MatchStateMachine.handle(emptied, { type = "playerLeft", remainingA = 0, remainingB = 0 })
	t.equal(emptied.phase, "Idle", "an emptied roster aborts straight to Idle")

	local aborted = findEffect(effects, "endMatch")
	t.expect(aborted ~= nil, "an abort still reports the match as ended")
	t.equal(aborted and aborted.aborted, true, "the abort is flagged so no rewards are paid")
	t.equal(aborted and aborted.winnerTeam, nil, "an aborted match has no winner")
	t.equal(broadcastFor(effects, "Results"), nil, "an aborted match never shows Results")
	t.expect(broadcastFor(effects, "Idle") ~= nil, "an aborted match broadcasts Idle")
	t.expect(findEffect(effects, "returnToHub") ~= nil, "an aborted match still returns the roster to the hub")
	t.expect(findEffect(effects, "resetQueue") ~= nil, "an aborted match drops the queue")
	t.equal(countEffects(effects, "endMatch"), 1, "an abort pays out exactly one endMatch")

	--------------------------------------------------------------------------
	-- Guards: events that must not move a phase
	--------------------------------------------------------------------------

	local guarded = startedMatch(2)
	MatchStateMachine.handle(guarded, { type = "playerLeft", remainingA = 1, remainingB = 1 })

	_, effects = MatchStateMachine.handle(guarded, { type = "queueChanged", count = 0 })
	t.equal(guarded.phase, "InProgress", "a pad emptying cannot end a live match")
	t.equal(#effects, 0, "a queue change during a match produces no effects")

	local idle = MatchStateMachine.new(CONFIG)
	MatchStateMachine.handle(idle, { type = "kill", teamId = "A" })
	t.equal(idle.scores.A, 0, "kills outside a match are not scored")

	_, effects = MatchStateMachine.handle(idle, { type = "tick", dt = 1000 })
	t.equal(#effects, 0, "ticking an idle map does nothing")

	_, effects = MatchStateMachine.handle(idle, { type = "somethingElse" })
	t.equal(#effects, 0, "an unknown event is ignored")

	--------------------------------------------------------------------------
	-- forceEnd
	--------------------------------------------------------------------------

	local forced = startedMatch(2)
	MatchStateMachine.handle(forced, { type = "playerLeft", remainingA = 1, remainingB = 1 })
	MatchStateMachine.handle(forced, { type = "kill", teamId = "B" })

	_, effects = MatchStateMachine.handle(forced, { type = "forceEnd" })
	t.equal(forced.phase, "Results", "forceEnd ends a live match")
	local forcedEnd = findEffect(effects, "endMatch")
	t.equal(forcedEnd and forcedEnd.winnerTeam, "B", "forceEnd awards the win on the current score")

	local forcedQueue = MatchStateMachine.new(CONFIG)
	MatchStateMachine.handle(forcedQueue, { type = "queueChanged", count = 2 })
	_, effects = MatchStateMachine.handle(forcedQueue, { type = "forceEnd" })
	t.equal(forcedQueue.phase, "Idle", "forceEnd during a countdown returns to Idle")
	t.expect(findEffect(effects, "resetQueue") ~= nil, "forceEnd during a countdown drops the queue")
	t.equal(findEffect(effects, "endMatch"), nil, "forceEnd before a match started pays nobody")
end
