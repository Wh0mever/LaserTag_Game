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
local DataService = require(script.Parent.Parent.Services.DataService)
local EconomyConfig = require(Shared.Config.EconomyConfig)
local GameConfig = require(Shared.Config.GameConfig)
local IdleTracker = require(script.Parent.IdleTracker)
local LeaderboardService = require(script.Parent.Parent.Services.LeaderboardService)
local MatchStateMachine = require(script.Parent.MatchStateMachine)
local PlayerService = require(script.Parent.Parent.Services.PlayerService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local TeamService = require(script.Parent.Parent.Services.TeamService)

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

function MatchRuntime.new(mapId: string)
	return setmetatable({
		mapId = mapId,
		state = MatchStateMachine.new(FSM_CONFIG),
		queued = {} :: { Player }, -- standing on the pad, in arrival order
		roster = {} :: { [Player]: string }, -- playing right now -> team id
		kills = {} :: { [Player]: number }, -- kills this match, for BestKillsInMatch
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

function MatchRuntime:getPhase(): string
	return self.state.phase
end

function MatchRuntime:isInProgress(): boolean
	return self.state.phase == MatchStateMachine.States.InProgress
end

function MatchRuntime:isPlaying(player: Player): boolean
	return self.roster[player] ~= nil
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
	TeamService.assignToTeam(player, teamId)
	AnalyticsService.matchStarted(player, self.mapId)
	-- Where they stood before this match says nothing about whether they are
	-- playing it, and the idle clock starts now rather than at some earlier
	-- sighting.
	IdleTracker.reset(self.idle, player, workspace:GetServerTimeNow())
	task.spawn(PlayerService.spawnInMatch, player, self.mapId, teamId)
end

function MatchRuntime:_startMatch()
	local entrants = {}
	for _, player in self.queued do
		if isPresent(player) and #entrants < GameConfig.MAX_PLAYERS_PER_MATCH then
			table.insert(entrants, player)
		end
	end

	table.clear(self.queued)
	table.clear(self.roster)
	table.clear(self.kills)

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

	for player, teamId in self.roster do
		if isPresent(player) then
			local won = winnerTeam ~= nil and teamId == winnerTeam
			local amount = if winnerTeam == nil
				then EconomyConfig.REWARDS.MATCH_DRAW
				elseif won then EconomyConfig.REWARDS.MATCH_WIN
				else EconomyConfig.REWARDS.MATCH_PARTICIPATION
			local reason = if winnerTeam == nil
				then REWARD_REASONS.draw
				elseif won then REWARD_REASONS.win
				else REWARD_REASONS.played

			DataService.recordMatchResult(player, won, self.kills[player] or 0)
			if DataService.addCoins(player, amount, reason) then
				rewards[player.UserId] = amount
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
	})
end

function MatchRuntime:_returnToHub()
	local leaving = {}
	for player in self.roster do
		table.insert(leaving, player)
	end

	table.clear(self.roster)
	table.clear(self.kills)

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
	local a, b = self:_countTeams()
	local size = a + b
	local joined = false

	for _, player in candidates do
		if size >= GameConfig.MAX_PLAYERS_PER_MATCH then
			break
		end
		if not self.roster[player] and isPresent(player) and (player:GetAttribute("InMatch") or "") == "" then
			local teamId = TeamService.smallestTeamIn(self.roster)
			self.roster[player] = teamId
			self.kills[player] = 0
			size += 1
			joined = true

			self:_place(player, teamId)
			Remotes.fireClient(
				RemoteNames.MatchStateChanged,
				player,
				self.mapId,
				MatchStateMachine.States.InProgress,
				{ timeLeft = math.max(math.floor(self.state.timeLeft + 0.5), 0), scores = self:getScores() }
			)
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

	The kill feed is NOT published here — CombatService owns KillFeedEvent, and
	firing it from both sides would double every entry. The weapon and headshot
	flag are still accepted (and ignored) so the four-argument signature
	CombatService already calls against does not have to change when a scoring
	rule eventually needs them.
]]
function MatchRuntime:registerKill(victim: Player, killer: Player?, _weaponId: string?, _isHeadshot: boolean)
	if not victim then
		return
	end

	local victimTeam = self.roster[victim] or TeamService.getTeamId(victim)

	if killer and killer ~= victim then
		local killerTeam = self.roster[killer] or TeamService.getTeamId(killer)
		if killerTeam and killerTeam ~= victimTeam then
			self.kills[killer] = (self.kills[killer] or 0) + 1
			-- Counted, not sent: analytics is rate-limited and this fires
			-- hundreds of times an hour. It is reported once at match end.
			AnalyticsService.killScored(killer)
			self:_dispatch({ type = "kill", teamId = killerTeam })
		end
	end

	if self.roster[victim] then
		PlayerService.scheduleRespawn(victim, self.mapId, victimTeam, if killer then killer.UserId else nil)
	end
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
				`Двигайтесь или стреляйте — иначе через {seconds} с вернём в хаб`,
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
		self:_syncRoster()
	end
end

--[[
	Record that `player` did something only a present player does.

	Firing is the signal that keeps a marksman honest: the Arc Lance is designed
	to be played by holding a lane without moving, and position sampling alone
	would remove the player for playing the weapon the way it was built to be
	played.
]]
function MatchRuntime:markActivity(player: Player)
	if self.roster[player] then
		IdleTracker.markActive(self.idle, player, workspace:GetServerTimeNow())
	end
end

--[[
	End the match now, on the current scoreline. Exposed for shutdown handling and
	for an operator command; the match still pays out normally.
]]
function MatchRuntime:forceEnd()
	self:_dispatch({ type = "forceEnd" })
end

return MatchRuntime
