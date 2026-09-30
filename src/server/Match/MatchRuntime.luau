--!nonstrict
--[[
	MatchRuntime.luau
	One live match on one map: the roster, the team split, spawning, the 1 Hz HUD
	tick, the payout and every remote the match phase produces.

	MatchStateMachine decides *what* should happen; this file is the only place
	that makes any of it real. The two talk through effects, so a rule change goes
	in the state machine (and its spec) and a Roblox change goes here.

	Remote ownership (do not duplicate these elsewhere): MatchStateChanged, fired
	on every phase transition, and MatchTick, fired once a second while a match is
	InProgress. KillFeedEvent belongs to CombatService and is not touched here.

	Every remote is addressed to the map's own audience rather than
	FireAllClients: two matches run side by side and ClientState keys its match
	view on whatever arrives last, so a Mirage broadcast landing on a Dust player
	would visibly corrupt their HUD.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local AnalyticsService = require(script.Parent.Parent.Services.AnalyticsService)
local Constants = require(Shared.Constants)
local DataService = require(script.Parent.Parent.Services.DataService)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local GameConfig = require(Shared.Config.GameConfig)
local IdleTracker = require(script.Parent.IdleTracker)
local LeaderboardService = require(script.Parent.Parent.Services.LeaderboardService)
local MatchStateMachine = require(script.Parent.MatchStateMachine)
local PairLimiter = require(script.Parent.PairLimiter)
local Payout = require(script.Parent.Payout)
local PlayerService = require(script.Parent.Parent.Services.PlayerService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local SideAssignment = require(script.Parent.SideAssignment)
local TeamService = require(script.Parent.Parent.Services.TeamService)
local Validators = require(script.Parent.Parent.Net.Validators)

local MatchRuntime = {}
MatchRuntime.__index = MatchRuntime

local FSM_CONFIG = {
	minPlayers = GameConfig.MIN_PLAYERS,
	countdownDuration = GameConfig.COUNTDOWN_DURATION,
	matchDuration = GameConfig.MATCH_DURATION,
	resultsDuration = GameConfig.RESULTS_DURATION,
	emptyTeamGrace = GameConfig.EMPTY_TEAM_GRACE,
	scoreLimitPerPlayer = GameConfig.SCORE_LIMIT_PER_PLAYER,
}

local REWARD_REASONS = { win = "Match win", draw = "Match draw", played = "Match played" }

-- Seconds past the side question's own countdown that a switch is still taken,
-- for the round trip of the answer.
local SIDE_CHOICE_GRACE = 2

function MatchRuntime.new(mapId: string)
	return setmetatable({
		mapId = mapId,
		state = MatchStateMachine.new(FSM_CONFIG),
		queued = {} :: { Player }, -- standing on the pad, in arrival order
		roster = {} :: { [Player]: string }, -- playing right now -> team id
		kills = {} :: { [Player]: number }, -- kills this match, for BestKillsInMatch
		-- Until when each player may still change sides (os.clock()). Set on
		-- placement, cleared by the one switch a player is allowed.
		sideDeadline = {} :: { [Player]: number },
		-- Seconds of the match that had passed when each player was seated: 0 for
		-- everyone dealt in at the start. The end-of-match payout is scaled by
		-- how long they were actually there.
		placedAt = {} :: { [Player]: number },
		-- Kills per killer and victim, for the ones that stop paying. Keyed by
		-- UserId: a player who leaves and comes back is a new Player object.
		killPairs = PairLimiter.new(EconomyConfig.MAX_PAID_KILLS_PER_PAIR),
		pending = {} :: { { [string]: any } }, -- events raised while one is dispatching
		dispatching = false,
		idle = IdleTracker.new({
			warnAfter = GameConfig.IDLE_WARN_SECONDS,
			removeAfter = GameConfig.IDLE_REMOVE_SECONDS,
		}),
	}, MatchRuntime)
end

--------------------------------------------------------------------------------
-- Roster helpers
--------------------------------------------------------------------------------

local function isPresent(player: Player): boolean
	return player ~= nil and player:IsDescendantOf(Players)
end

--[[
	Whether a player is dead or waiting on a respawn. The pad sample is up to a
	poll old and only ever counts living characters, so such a player is a leftover
	of it and not somebody standing there. They are dealt in on a later pass if
	they are back on the pad; seating them now would put a character into the
	match while the respawn they are waiting on is still pending.
]]
local function isDown(player: Player): boolean
	if PlayerService.isRespawning(player) then
		return true
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health <= 0
end

function MatchRuntime:getPhase(): string
	return self.state.phase
end

function MatchRuntime:isInProgress(): boolean
	return self.state.phase == MatchStateMachine.States.InProgress
end

function MatchRuntime:isPlaying(player: Player): boolean
	return self.roster[player] ~= nil
end

--[[
	Whether a player standing on the pad would be seated right now. False in the
	last minute of a match (see GameConfig.LATE_JOIN_CUTOFF_SECONDS), which is
	also what lets the portal sign say the match is closing instead of that it is
	still going.
]]
function MatchRuntime:acceptsJoiners(): boolean
	return self:isInProgress() and self.state.timeLeft >= GameConfig.LATE_JOIN_CUTOFF_SECONDS
end

function MatchRuntime:getQueueCount(): number
	return #self.queued
end

--[[
	Whole seconds left on the countdown, or nil when one is not running. The
	portal signs read this, so it is rounded up: "0" on a sign that has not
	started the match yet reads as broken.
]]
function MatchRuntime:getCountdown(): number?
	if self.state.phase ~= MatchStateMachine.States.Countdown then
		return nil
	end
	return math.max(math.ceil(self.state.timeLeft), 0)
end

function MatchRuntime:getScores(): { A: number, B: number }
	return { A = self.state.scores.A, B = self.state.scores.B }
end

function MatchRuntime:getRoster(): { [Player]: string }
	return table.clone(self.roster)
end

function MatchRuntime:_countTeams(): (number, number)
	local a, b = 0, 0
	for player, teamId in self.roster do
		if isPresent(player) then
			if teamId == "A" then
				a += 1
			elseif teamId == "B" then
				b += 1
			end
		end
	end
	return a, b
end

--[[
	Everyone this map's remotes may address: the roster plus whoever is waiting on
	the pad. Both are needed — a queued player has to see the countdown, a playing
	player has to see the score.
]]
function MatchRuntime:_audience(): { Player }
	local list, seen = {}, {}

	local function append(player: Player)
		if isPresent(player) and not seen[player] then
			seen[player] = true
			table.insert(list, player)
		end
	end

	for player in self.roster do
		append(player)
	end
	for _, player in self.queued do
		append(player)
	end

	return list
end

-- A banner for everyone playing right now. The players on the pad are not told:
-- what happens inside the match is not their business until they are in it.
function MatchRuntime:_notifyRoster(message: string, severity: string)
	for player in self.roster do
		if isPresent(player) then
			Remotes.fireClient(RemoteNames.Notice, player, message, severity)
		end
	end
end

function MatchRuntime:_broadcast(phase: string, data: { [string]: any })
	for _, player in self:_audience() do
		Remotes.fireClient(RemoteNames.MatchStateChanged, player, self.mapId, phase, data)
	end
end

--------------------------------------------------------------------------------
-- Effects
--------------------------------------------------------------------------------

--[[
	Feed one event to the state machine and perform whatever it asks for.

	Effects re-enter this method (spawning a player reports a new roster count, a
	disconnect during a payout ends the match), so events raised while a dispatch
	is in flight are queued and drained afterwards instead of nesting. Without
	that, a state machine transition could observe a state half-way through its
	own effects.
]]
function MatchRuntime:_dispatch(event: { [string]: any })
	table.insert(self.pending, event)
	if self.dispatching then
		return
	end
	self.dispatching = true

	while #self.pending > 0 do
		local queuedEvent = table.remove(self.pending, 1)
		local ok, state, effects = pcall(MatchStateMachine.handle, self.state, queuedEvent)

		if ok then
			self.state = state
			for _, effect in effects do
				local applied, err = pcall(self._apply, self, effect)
				if not applied then
					warn(`[MatchRuntime] {self.mapId}: effect "{tostring(effect.type)}" failed: {err}`)
				end
			end
		else
			warn(`[MatchRuntime] {self.mapId}: state machine rejected "{tostring(queuedEvent.type)}": {state}`)
		end
	end

	self.dispatching = false
end

function MatchRuntime:_apply(effect: { [string]: any })
	local kind = effect.type

	if kind == "broadcast" then
		self:_broadcast(effect.phase, effect.data)
	elseif kind == "startMatch" then
		self:_startMatch()
	elseif kind == "endMatch" then
		self:_endMatch(effect)
	elseif kind == "returnToHub" then
		self:_returnToHub()
	elseif kind == "resetQueue" then
		table.clear(self.queued)
	elseif kind == "graceStarted" then
		self:_notifyRoster(
			`Команда соперника пуста — победа через {effect.seconds} с, если никто не зайдёт`,
			"warning"
		)
	elseif kind == "graceCancelled" then
		self:_notifyRoster(
			"В матч зашли новые игроки — игра продолжается",
			"info"
		)
	else
		warn(`[MatchRuntime] {self.mapId}: unknown effect "{tostring(kind)}"`)
	end
end

--[[
	Put a player into the match. The attribute and team are set synchronously so
	QueueService's next poll already sees them as playing; the character load
	yields, so it runs in its own task rather than stalling the tick loop that got
	us here.
]]
function MatchRuntime:_place(player: Player, teamId: string)
	player:SetAttribute("InMatch", self.mapId)
	-- This match's kills, for the scoreboard. SessionKills counts the whole
	-- visit, so a player 20 kills into their evening topped every board they
	-- joined, beside a team total that said 0.
	player:SetAttribute("MatchKills", 0)
	TeamService.assignToTeam(player, teamId)
	self.placedAt[player] = MatchStateMachine.elapsed(self.state)
	AnalyticsService.matchStarted(player, self.mapId)
	-- Where they stood before this match says nothing about whether they are
	-- playing it, and the idle clock starts now rather than at some earlier
	-- sighting.
	IdleTracker.reset(self.idle, player, workspace:GetServerTimeNow())
	-- A little over the question's own countdown, for the round trip.
	self.sideDeadline[player] = os.clock() + Constants.SIDE_CHOICE_SECONDS + SIDE_CHOICE_GRACE
	task.spawn(function()
		PlayerService.spawnInMatch(player, self.mapId, teamId)
		-- The side question is on screen now and the player cannot shoot
		-- through it; the ordinary three seconds would leave them a target
		-- for the other seven. Their first shot ends this, as on any spawn.
		PlayerService.extendSpawnProtection(player, Constants.SIDE_CHOICE_SECONDS)
	end)
end

--[[
	Move a player to the side they asked for.

	Returns (moved, reason); the reason is a SideAssignment constant either way,
	so the client can say WHY a refusal happened instead of showing a button that
	does nothing.

	Deliberately not _place: that one sets the InMatch attribute, resets the idle
	clock and tells analytics a match started. None of those is true of changing
	sides, and the analytics call in particular would count one match twice.
]]
--[[
	How many players are on each side right now, as {[teamId] = n}.

	Read off the roster rather than counted from Teams: the roster is what
	switchSide checks against, so a number shown to a player and the number the
	rule uses can never disagree.
]]
function MatchRuntime:getCounts(): { [string]: number }
	return SideAssignment.countTeams(self.roster, Constants.TEAM_IDS)
end

function MatchRuntime:switchSide(player: Player, teamId: string): (boolean, string)
	local from = self.roster[player]
	if not from or not self:isInProgress() then
		return false, SideAssignment.NOT_PLAYING
	end

	--[[
		WHEN, before WHO. A switch respawns the player at full health in their
		new spawn room, and nothing used to limit when it could be asked for:
		a client could call it mid-fight to escape any losing duel, every
		couple of seconds, or in the last second of a match to be paid as the
		winning side. It is the answer to the question asked on entry, so it
		is accepted only while that question is open, only from a player who
		is alive and not waiting on a respawn, and only once.
	]]
	local deadline = self.sideDeadline[player]
	if not deadline or os.clock() > deadline then
		return false, SideAssignment.TOO_LATE
	end
	if not Validators.isAlive(player) or PlayerService.isRespawning(player) then
		return false, SideAssignment.NOT_ALIVE
	end

	local counts = SideAssignment.countTeams(self.roster, Constants.TEAM_IDS)

	local allowed, reason = SideAssignment.evaluate(counts, from, teamId, Constants.TEAM_IDS)
	if not allowed then
		return false, reason
	end

	self.roster[player] = teamId
	self.sideDeadline[player] = nil
	TeamService.assignToTeam(player, teamId)

	-- Respawned rather than teleported: they are standing in what is now the
	-- enemy half, holding whatever health the old side left them with.
	task.spawn(PlayerService.spawnInMatch, player, self.mapId, teamId)

	self:_syncRoster()
	return true, reason
end

--[[
	Even out the teams as a player comes back from a death.

	Players who leave are never replaced on their own side, and the side picker
	only exists at join, so a match that lost three players from one team stayed
	lopsided until the last second. A death is the one moment a player can change
	side without it being a teleport in the middle of a fight, so it is the moment
	this asks: the player about to respawn is moved to the smaller side when their
	own is two or more ahead.

	Called by PlayerService when a respawn timer fires, so it covers every kind of
	death, and BEFORE the team is read for the spawn. Not at the moment of the
	kill: the kill feed is written just after the kill is registered, and would
	show the victim in their new colours.

	Never fills a side that is empty. That is a forfeit running its grace, and
	dragging a teammate across would turn the win into a fight nobody asked for.

	Not in the last minute (the cutoff for seating a joiner). The payout follows
	the side a player finishes on, whatever they did on the other, so a move that
	late is either a way onto the winning side or a win taken from someone who
	played for it.

	Returns the new team id if the player was moved.
]]
function MatchRuntime:rebalanceOnRespawn(player: Player): string?
	local from = self.roster[player]
	if not from or not self:isInProgress() then
		return nil
	end
	if self.state.timeLeft < GameConfig.LATE_JOIN_CUTOFF_SECONDS then
		return nil
	end

	local a, b = self:_countTeams()
	local counts = { A = a, B = b }

	local to = nil
	for _, teamId in Constants.TEAM_IDS do
		if teamId ~= from then
			to = teamId
		end
	end
	if not to or counts[to] < 1 or counts[from] - counts[to] < 2 then
		return nil
	end

	self.roster[player] = to
	TeamService.assignToTeam(player, to)
	Remotes.fireClient(
		RemoteNames.Notice,
		player,
		`Вы переведены в команду {Constants.TEAMS[to].name} для баланса`,
		"info"
	)

	self:_syncRoster()
	return to
end

function MatchRuntime:_startMatch()
	local entrants = {}
	for _, player in self.queued do
		if isPresent(player) and not isDown(player) and #entrants < GameConfig.MAX_PLAYERS_PER_MATCH then
			table.insert(entrants, player)
		end
	end

	table.clear(self.queued)
	table.clear(self.roster)
	table.clear(self.kills)
	table.clear(self.sideDeadline)
	table.clear(self.placedAt)
	PairLimiter.reset(self.killPairs)

	for player, teamId in TeamService.balanceAssign(entrants) do
		self.roster[player] = teamId
		self.kills[player] = 0
	end

	for _, player in entrants do
		self:_place(player, self.roster[player])
	end

	self:_syncRoster()
end

--[[
	Pay the match out and publish the Results screen.

	The state machine cannot emit the Results broadcast itself: its payload
	carries the per-player coin awards, which only exist once DataService has
	accepted them. An aborted match (everybody disconnected) pays nothing and
	shows nothing.
]]
function MatchRuntime:_endMatch(effect: { [string]: any })
	if effect.aborted then
		return
	end

	local rewards = {}
	local winnerTeam = effect.winnerTeam
	local elapsed = effect.elapsed or 0

	for player, teamId in self.roster do
		if isPresent(player) then
			-- What the scoreline says is not all that decides the award: a player
			-- has to have been there for the result (see Payout).
			local result = Payout.compute({
				winnerTeam = winnerTeam,
				teamId = teamId,
				reason = effect.reason,
				playedSeconds = elapsed - (self.placedAt[player] or 0),
				matchSeconds = elapsed,
				matchDuration = FSM_CONFIG.matchDuration,
				rewards = EconomyConfig.REWARDS,
				minSeconds = EconomyConfig.MATCH_BONUS_MIN_SECONDS,
			})
			local won = result.won
			local amount = result.amount
			local reason = REWARD_REASONS[result.outcome]

			DataService.recordMatchResult(player, won, self.kills[player] or 0)
			-- Keyed by the UserId as a STRING. A table keyed by large numbers is
			-- not an array, and a RemoteEvent does not carry it as one: the
			-- numeric keys do not arrive as numbers, so the client's lookup by
			-- player.UserId found nothing and every player, paid or not, read
			-- "Монет не начислено" under the result.
			if DataService.addCoins(player, amount, reason) then
				rewards[tostring(player.UserId)] = amount
			end

			-- The only place a match reports. Where players stop appearing in
			-- this funnel is where the match loop is losing them.
			local ownScore = if teamId == "A" then effect.scores.A else effect.scores.B
			local enemyScore = if teamId == "A" then effect.scores.B else effect.scores.A
			AnalyticsService.matchFinished(player, won, ownScore, enemyScore)

			-- Writes to an OrderedDataStore, so it must not block the payout loop.
			task.spawn(LeaderboardService.flush, player)
		end
	end

	self:_broadcast(MatchStateMachine.States.Results, {
		scores = { A = effect.scores.A, B = effect.scores.B },
		winnerTeam = winnerTeam,
		rewards = rewards,
		-- Why the match ended when the scoreline does not say: "forfeit" is a
		-- win handed to the side that stayed, and the Results screen has to
		-- explain it or it reads as a bug.
		reason = effect.reason,
	})
end

function MatchRuntime:_returnToHub()
	local leaving = {}
	for player in self.roster do
		table.insert(leaving, player)
	end

	table.clear(self.roster)
	table.clear(self.kills)
	table.clear(self.sideDeadline)
	table.clear(self.placedAt)
	-- Nothing of a finished match is carried into the next one, whichever way
	-- that one starts.
	PairLimiter.reset(self.killPairs)

	for _, player in leaving do
		if isPresent(player) then
			player:SetAttribute("InMatch", "")
			TeamService.moveToLobby(player)
			task.spawn(PlayerService.spawnInHub, player)
		end
	end
end

function MatchRuntime:_syncRoster()
	local a, b = self:_countTeams()
	self:_dispatch({ type = "playerLeft", remainingA = a, remainingB = b })
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	The players currently standing on this map's portal pad, in arrival order.
	While a match is live the same list is treated as a queue of late joiners
	instead of a lobby.
]]
function MatchRuntime:onQueueChanged(players: { Player })
	if self:isInProgress() then
		self:_joinMidMatch(players)
		return
	end

	-- Results is a hold: the roster is still on the map, so nobody may be dealt
	-- into a new one until they have been sent back to the hub.
	if self.state.phase == MatchStateMachine.States.Results then
		return
	end

	local list = {}
	for _, player in players do
		if isPresent(player) and #list < GameConfig.MAX_PLAYERS_PER_MATCH then
			table.insert(list, player)
		end
	end

	-- The first funnel step, and only for players who were not already queued:
	-- the pad roster is re-sent on every poll, so reporting the whole list each
	-- time would restart the funnel for people standing still. A player who
	-- queues and never reaches Playing is one the countdown lost.
	local wasQueued = {}
	for _, player in self.queued do
		wasQueued[player] = true
	end
	for _, player in list do
		if not wasQueued[player] then
			AnalyticsService.matchQueued(player, self.mapId)
		end
	end

	self.queued = list
	self:_dispatch({ type = "queueChanged", count = #list })
end

--[[
	Late joiners always land on the smaller side, so a match that lost three
	players from one team repairs itself instead of staying lopsided.
]]
function MatchRuntime:_joinMidMatch(candidates: { Player })
	-- Not in the last minute: someone seated then could not play long enough to
	-- share in the result, and is only dropped into the end of somebody else's
	-- game. They stay on the pad and are dealt into the next match.
	if not self:acceptsJoiners() then
		return
	end

	local a, b = self:_countTeams()
	local size = a + b
	local joined = false

	for _, player in candidates do
		if size >= GameConfig.MAX_PLAYERS_PER_MATCH then
			break
		end
		if
			not self.roster[player]
			and isPresent(player)
			and not isDown(player)
			and (player:GetAttribute("InMatch") or "") == ""
		then
			local teamId = TeamService.smallestTeamIn(self.roster)
			self.roster[player] = teamId
			self.kills[player] = 0
			size += 1
			joined = true

			self:_place(player, teamId)
			Remotes.fireClient(RemoteNames.MatchStateChanged, player, self.mapId, MatchStateMachine.States.InProgress, {
				timeLeft = math.max(math.floor(self.state.timeLeft + 0.5), 0),
				scores = self:getScores(),
				-- The phase broadcast everyone else got carried the kill
				-- target; without it here a late joiner's HUD never showed
				-- "ДО N УБИЙСТВ" for the rest of the match.
				scoreLimit = self.state.scoreLimit,
			})
		end
	end

	if joined then
		self:_syncRoster()
	end
end

--[[
	Score a kill and start the victim's respawn.

	Only cross-team kills score. A self-kill (the void, a fall) and a team kill
	both leave the scoreline alone, so neither can be farmed for a win.

	Returns whether the kill should PAY: false for a kill that does not score
	(a self-kill, a team kill) and for one of a victim the killer has already
	killed the paid number of times this match while there were other enemies to
	take instead. The caller that pays coins (CombatService, through
	DataService.recordKill) skips the payout on false.

	The kill feed is NOT published here — CombatService owns KillFeedEvent, and
	firing it from both sides would double every entry. The weapon and headshot
	flag are still accepted (and ignored) so the four-argument signature
	CombatService already calls against does not have to change when a scoring
	rule eventually needs them.
]]
function MatchRuntime:registerKill(victim: Player, killer: Player?, _weaponId: string?, _isHeadshot: boolean): boolean
	if not victim then
		return false
	end

	local victimTeam = self.roster[victim] or TeamService.getTeamId(victim)
	local paid = false

	if killer and killer ~= victim then
		local killerTeam = self.roster[killer] or TeamService.getTeamId(killer)
		if killerTeam and killerTeam ~= victimTeam then
			self.kills[killer] = (self.kills[killer] or 0) + 1
			killer:SetAttribute("MatchKills", self.kills[killer])
			-- Counted, not sent: analytics is rate-limited and this fires
			-- hundreds of times an hour. It is reported once at match end.
			AnalyticsService.killScored(killer)
			-- The kill scores whatever this says; it only decides whether the
			-- killer is paid for it. See PairLimiter, which also says why a
			-- killer facing a single enemy is always paid. The enemies are
			-- counted off the roster as it is now, the victim included.
			local a, b = self:_countTeams()
			local enemies = if victimTeam == "A" then a elseif victimTeam == "B" then b else nil
			paid = PairLimiter.record(self.killPairs, killer.UserId, victim.UserId, enemies)
			self:_dispatch({ type = "kill", teamId = killerTeam })
		end
	end

	if self.roster[victim] then
		PlayerService.scheduleRespawn(victim, self.mapId, victimTeam, if killer then killer.UserId else nil)
	end

	return paid
end

--[[
	One step of the match clock. MatchService drives this from a single heartbeat
	loop, so `dt` is whatever really elapsed rather than a nominal interval.
]]
function MatchRuntime:tick(dt: number)
	self:_dispatch({ type = "tick", dt = dt })

	if self:isInProgress() then
		local timeLeft = math.max(math.floor(self.state.timeLeft + 0.5), 0)
		local scores = self.state.scores
		for player in self.roster do
			if isPresent(player) then
				Remotes.fireClient(RemoteNames.MatchTick, player, self.mapId, timeLeft, scores.A, scores.B)
			end
		end

		self:_stepIdle()
	end
end

--[[
	Sample every player's position and act on whoever has stopped playing.

	Only while a match is in progress: standing still in the hub is not idling,
	it is reading the shop.
]]
function MatchRuntime:_stepIdle()
	local now = workspace:GetServerTimeNow()

	for player in self.roster do
		local character = isPresent(player) and player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local position = nil
		if root and root:IsA("BasePart") then
			local at = root.Position
			position = { x = at.X, y = at.Y, z = at.Z }
		end

		IdleTracker.observe(self.idle, player, position, now)
	end

	for _, action in IdleTracker.step(self.idle, now) do
		local player = action.id
		if not self.roster[player] then
			-- Left the match between the sample and now.
			IdleTracker.forget(self.idle, player)
			continue
		end

		if action.action == IdleTracker.Actions.Warn then
			local seconds = math.ceil(IdleTracker.secondsUntilRemoval(self.idle, player, now))
			Remotes.fireClient(
				RemoteNames.Notice,
				player,
				`Двигайтесь или ведите бой — иначе через {seconds} с вернём в хаб`,
				"warning"
			)
		elseif action.action == IdleTracker.Actions.Remove then
			self:_removeIdle(player)
		end
	end
end

--[[
	Take one idle player out of the match and put them back in the hub.

	Not a kick: they keep their session and can walk onto a pad again, which
	takes being present. Dropping them from the roster before the payout loop is
	the point — an idle player collecting the end-of-match award is what breaks
	the economy's assumption that coins come from playing.
]]
function MatchRuntime:_removeIdle(player: Player)
	self.roster[player] = nil
	self.kills[player] = nil
	self.sideDeadline[player] = nil
	self.placedAt[player] = nil
	IdleTracker.forget(self.idle, player)

	if isPresent(player) then
		player:SetAttribute("InMatch", "")
		TeamService.moveToLobby(player)
		Remotes.fireClient(
			RemoteNames.Notice,
			player,
			"Возвращены в хаб — вы не двигались. Встаньте на площадку, чтобы играть снова.",
			"error"
		)
		task.spawn(PlayerService.spawnInHub, player)
	end

	-- The roster shrank, which may have emptied a team: the state machine owns
	-- what that means, so it has to hear about it.
	self:_syncRoster()
end

function MatchRuntime:onPlayerRemoving(player: Player)
	local index = table.find(self.queued, player)
	if index then
		table.remove(self.queued, index)
		self:_dispatch({ type = "queueChanged", count = #self.queued })
	end

	IdleTracker.forget(self.idle, player)

	if self.roster[player] then
		self.roster[player] = nil
		self.kills[player] = nil
		self.sideDeadline[player] = nil
		self.placedAt[player] = nil
		self:_syncRoster()
	end
end

--[[
	Record that `player` did something only a present player does.

	Firing is the signal that keeps a marksman honest: the Arc Lance is designed
	to be played by holding a lane without moving, and position sampling alone
	would remove the player for playing the weapon the way it was built to be
	played.

	But a shot is proof of presence only when somebody is aiming it. Holding the
	trigger with a weighted mouse button (or an autoclicker) fires at one fixed
	direction forever, and used to keep an absent player in the match for good. So
	a caller that has the details passes them:

	  shot = { damaged = boolean, sprayIndex = number, direction = Vector3 }

	and IdleTracker.markShot counts only a shot that hurt an enemy or a new burst
	aimed somewhere new. A call with no shot is counted outright, as before.
]]
function MatchRuntime:markActivity(player: Player, shot: { [string]: any }?)
	if not self.roster[player] then
		return
	end

	local now = workspace:GetServerTimeNow()
	if shot == nil then
		IdleTracker.markActive(self.idle, player, now)
		return
	end

	-- A Vector3 answers to .X, a plain {x, y, z} table to .x.
	local aim = shot.direction
	local direction = nil
	if type(aim) == "table" or typeof(aim) == "Vector3" then
		direction = { x = aim.X or aim.x, y = aim.Y or aim.y, z = aim.Z or aim.z }
	end

	IdleTracker.markShot(self.idle, player, now, {
		damaged = shot.damaged == true,
		sprayIndex = shot.sprayIndex,
		direction = direction,
	})
end

--[[
	End the match now, on the current scoreline. Exposed for shutdown handling and
	for an operator command; the match still pays out normally.
]]
function MatchRuntime:forceEnd()
	self:_dispatch({ type = "forceEnd" })
end

return MatchRuntime
