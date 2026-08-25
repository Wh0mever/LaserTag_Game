--!nonstrict
--[[
	MatchStateMachine.luau
	The whole match lifecycle as a pure function of (state, event).

	Idle -> WaitingForPlayers -> Countdown -> InProgress -> Results -> Idle

	Nothing here touches a Roblox API, a clock or a Player instance: `handle`
	returns a list of *effects* describing what should happen, and MatchRuntime is
	the only thing that performs them. That split is what makes the pacing rules
	(and every edge case around disconnects) testable off Roblox by
	tests/MatchStateMachine.spec.luau.

	Effect kinds, in the order the runtime must apply them:
	  broadcast    {phase, data}                     -> MatchStateChanged
	  startMatch   {queued}                          -> pick teams and spawn
	  endMatch     {winnerTeam, scores, aborted}     -> pay rewards, show Results
	  returnToHub  {}                                -> send the roster back
	  resetQueue   {}                                -> drop the pad queue

	Effect ORDER carries meaning and is not incidental: `startMatch` precedes the
	InProgress broadcast because the roster has to exist before it can be
	addressed, and the Idle broadcast precedes `returnToHub` because emptying the
	roster also empties the audience for that broadcast.

	This module cannot require GameConfig or Constants — a Roblox require path
	would stop the off-Roblox runner loading it — so the defaults below are
	duplicated and the spec asserts they still match the real config.
]]

local MatchStateMachine = {}

MatchStateMachine.States = {
	Idle = "Idle",
	WaitingForPlayers = "WaitingForPlayers",
	Countdown = "Countdown",
	InProgress = "InProgress",
	Results = "Results",
}

local States = MatchStateMachine.States

-- Mirrors GameConfig.MIN_PLAYERS / COUNTDOWN_DURATION / MATCH_DURATION /
-- RESULTS_DURATION / EMPTY_TEAM_GRACE.
MatchStateMachine.DEFAULTS = {
	minPlayers = 2,
	countdownDuration = 10,
	matchDuration = 600,
	resultsDuration = 10,
	emptyTeamGrace = 30,
}

-- Mirrors Constants.TEAM_IDS.
MatchStateMachine.TEAM_IDS = { "A", "B" }

export type Config = {
	minPlayers: number,
	countdownDuration: number,
	matchDuration: number,
	resultsDuration: number,
	emptyTeamGrace: number,
}

export type Effect = { [string]: any }

export type State = {
	phase: string,
	config: Config,
	queued: number,
	timeLeft: number,
	scores: { A: number, B: number },
	remaining: { A: number, B: number },
	emptyTeamTimeLeft: number?,
	winnerTeam: string?,
}

--------------------------------------------------------------------------------
-- Effect helpers
--------------------------------------------------------------------------------

local function emit(effects: { Effect }, effect: Effect)
	table.insert(effects, effect)
end

local function broadcast(effects: { Effect }, phase: string, data: { [string]: any })
	emit(effects, { type = "broadcast", phase = phase, data = data })
end

local function copyScores(state: State): { A: number, B: number }
	return { A = state.scores.A, B = state.scores.B }
end

--[[
	Winner by score, or nil when the two sides are level — a draw is the absence
	of a winner rather than a third team id, so every consumer that asks "did my
	team win" gets the right answer without a special case.
]]
function MatchStateMachine.winnerFromScores(scores: { A: number, B: number }): string?
	if scores.A > scores.B then
		return "A"
	elseif scores.B > scores.A then
		return "B"
	end
	return nil
end

--------------------------------------------------------------------------------
-- Phase entry
--------------------------------------------------------------------------------

local function enterIdle(state: State, effects: { Effect })
	state.phase = States.Idle
	state.timeLeft = 0
	state.emptyTeamTimeLeft = nil
	state.remaining.A, state.remaining.B = 0, 0
	broadcast(effects, States.Idle, {})
end

local function enterWaiting(state: State, effects: { Effect })
	state.phase = States.WaitingForPlayers
	state.timeLeft = 0
	broadcast(effects, States.WaitingForPlayers, { queued = state.queued, needed = state.config.minPlayers })
end

local function enterCountdown(state: State, effects: { Effect })
	state.phase = States.Countdown
	state.timeLeft = state.config.countdownDuration
	broadcast(effects, States.Countdown, { secondsLeft = math.ceil(state.timeLeft) })
end

local function enterInProgress(state: State, effects: { Effect })
	local queued = state.queued

	state.phase = States.InProgress
	state.timeLeft = state.config.matchDuration
	state.scores.A, state.scores.B = 0, 0
	state.remaining.A, state.remaining.B = 0, 0
	state.emptyTeamTimeLeft = nil
	state.winnerTeam = nil
	state.queued = 0

	emit(effects, { type = "startMatch", queued = queued })
	broadcast(effects, States.InProgress, { timeLeft = state.timeLeft, scores = copyScores(state) })
end

--[[
	Finish a played-out match. The Results broadcast is deliberately NOT emitted
	here: its payload carries the per-player coin rewards, which only the runtime
	knows once it has actually paid them.
]]
local function enterResults(state: State, effects: { Effect }, winnerTeam: string?)
	state.phase = States.Results
	state.timeLeft = state.config.resultsDuration
	state.emptyTeamTimeLeft = nil
	state.winnerTeam = winnerTeam

	emit(effects, {
		type = "endMatch",
		winnerTeam = winnerTeam,
		scores = copyScores(state),
		aborted = false,
	})
end

local function leaveResults(state: State, effects: { Effect })
	enterIdle(state, effects)
	emit(effects, { type = "returnToHub" })
	emit(effects, { type = "resetQueue" })
end

--[[
	Everybody left. There is no result to show and nobody to show it to, so the
	match is thrown away: `aborted` tells the runtime to pay nothing, and the
	Results phase is skipped entirely.
]]
local function abortMatch(state: State, effects: { Effect })
	state.winnerTeam = nil
	state.queued = 0

	emit(effects, {
		type = "endMatch",
		winnerTeam = nil,
		scores = copyScores(state),
		aborted = true,
	})
	enterIdle(state, effects)
	emit(effects, { type = "returnToHub" })
	emit(effects, { type = "resetQueue" })
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function applyQueue(state: State, count: number, effects: { Effect })
	-- Once a match is live the roster owns who is playing; a pad standing count
	-- can no longer move the phase, and mid-match joiners are the runtime's job.
	if state.phase == States.InProgress or state.phase == States.Results then
		return
	end

	count = math.max(math.floor(count), 0)
	local changed = count ~= state.queued
	state.queued = count

	if count <= 0 then
		if state.phase ~= States.Idle then
			enterIdle(state, effects)
		end
		return
	end

	local justEntered = false
	if state.phase == States.Idle then
		enterWaiting(state, effects)
		justEntered = true
	end

	if count >= state.config.minPlayers then
		if state.phase ~= States.Countdown then
			enterCountdown(state, effects)
		end
	elseif state.phase == States.Countdown or (changed and not justEntered) then
		-- Either somebody stepped off the pad mid-countdown, in which case the
		-- start is called off and the timer restarts from scratch if they come
		-- back, or the phase is unchanged but `queued` moved and it is part of
		-- the WaitingForPlayers payload.
		enterWaiting(state, effects)
	end
end

local function applyTick(state: State, dt: number, effects: { Effect })
	dt = math.max(dt, 0)

	if state.phase == States.Countdown then
		local before = math.ceil(state.timeLeft)
		state.timeLeft -= dt

		if state.timeLeft <= 0 then
			enterInProgress(state, effects)
		else
			local secondsLeft = math.ceil(state.timeLeft)
			if secondsLeft ~= before then
				broadcast(effects, States.Countdown, { secondsLeft = secondsLeft })
			end
		end
	elseif state.phase == States.InProgress then
		state.timeLeft = math.max(state.timeLeft - dt, 0)

		if state.emptyTeamTimeLeft then
			state.emptyTeamTimeLeft -= dt
			if state.emptyTeamTimeLeft <= 0 then
				-- Grace expired with a side still empty: whoever is left standing
				-- takes the win regardless of the scoreline.
				local survivor = if state.remaining.A > 0 then "A" elseif state.remaining.B > 0 then "B" else nil
				enterResults(state, effects, survivor)
				return
			end
		end

		if state.timeLeft <= 0 then
			enterResults(state, effects, MatchStateMachine.winnerFromScores(state.scores))
		end
	elseif state.phase == States.Results then
		state.timeLeft -= dt
		if state.timeLeft <= 0 then
			leaveResults(state, effects)
		end
	end
end

local function applyKill(state: State, teamId: any)
	if state.phase ~= States.InProgress then
		return
	end
	if type(teamId) == "string" and state.scores[teamId] then
		state.scores[teamId] += 1
	end
end

--[[
	The roster changed. `playerLeft` carries the CURRENT per-team head counts
	rather than a delta, so the runtime can report a disconnect, a mid-match join
	and the initial split through one event without the two sides ever drifting.
]]
local function applyRoster(state: State, remainingA: number, remainingB: number, effects: { Effect })
	state.remaining.A = math.max(math.floor(remainingA), 0)
	state.remaining.B = math.max(math.floor(remainingB), 0)

	if state.phase ~= States.InProgress then
		return
	end

	if state.remaining.A <= 0 and state.remaining.B <= 0 then
		abortMatch(state, effects)
	elseif state.remaining.A <= 0 or state.remaining.B <= 0 then
		-- Do not restart a grace period that is already running, or a side that
		-- keeps losing its last player would never actually run out of time.
		if not state.emptyTeamTimeLeft then
			state.emptyTeamTimeLeft = state.config.emptyTeamGrace
		end
	else
		state.emptyTeamTimeLeft = nil
	end
end

local function applyForceEnd(state: State, effects: { Effect })
	if state.phase == States.InProgress then
		enterResults(state, effects, MatchStateMachine.winnerFromScores(state.scores))
	elseif state.phase == States.Results then
		leaveResults(state, effects)
	elseif state.phase ~= States.Idle then
		state.queued = 0
		enterIdle(state, effects)
		emit(effects, { type = "resetQueue" })
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	A fresh Idle state. `config` may override any of DEFAULTS; non-numeric or
	non-positive overrides fall back so a bad config cannot produce a match that
	ends instantly.
]]
function MatchStateMachine.new(config: { [string]: any }?): State
	local resolved = {}
	for key, fallback in MatchStateMachine.DEFAULTS do
		local override = config and config[key]
		resolved[key] = if type(override) == "number" and override > 0 then override else fallback
	end

	return {
		phase = States.Idle,
		config = resolved,
		queued = 0,
		timeLeft = 0,
		scores = { A = 0, B = 0 },
		remaining = { A = 0, B = 0 },
		emptyTeamTimeLeft = nil,
		winnerTeam = nil,
	}
end

--[[
	Apply one event.

	Events:
	  {type = "queueChanged", count = n}
	  {type = "tick", dt = n}
	  {type = "kill", teamId = "A"|"B"}
	  {type = "playerLeft", remainingA = n, remainingB = n}
	  {type = "forceEnd"}

	`state` is updated in place and returned, so callers may either keep their own
	reference or reassign from the result. An unknown event is ignored rather than
	raised: the runtime feeds this from network-triggered code paths and a typo
	must not take a live match down.
]]
function MatchStateMachine.handle(state: State, event: { [string]: any }): (State, { Effect })
	local effects: { Effect } = {}

	if type(state) ~= "table" or type(event) ~= "table" then
		return state, effects
	end

	local kind = event.type
	if kind == "queueChanged" then
		applyQueue(state, tonumber(event.count) or 0, effects)
	elseif kind == "tick" then
		applyTick(state, tonumber(event.dt) or 0, effects)
	elseif kind == "kill" then
		applyKill(state, event.teamId)
	elseif kind == "playerLeft" then
		applyRoster(state, tonumber(event.remainingA) or 0, tonumber(event.remainingB) or 0, effects)
	elseif kind == "forceEnd" then
		applyForceEnd(state, effects)
	end

	return state, effects
end

function MatchStateMachine.isInProgress(state: State): boolean
	return state.phase == States.InProgress
end

return MatchStateMachine
