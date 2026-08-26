--!nonstrict
--[[
	AnalyticsService.luau
	Reports what players actually do, so the game can be improved from evidence.

	Without this, a live game is opaque. Retention says players leave but not
	where; the shop shows revenue but not which skins nobody looks at; the reward
	wheel could be paying out twice what it should and nothing would say so. Each
	of those is a decision someone will otherwise make from a hunch.

	Everything here goes through Roblox's own AnalyticsService, so the numbers
	land on the Creator Dashboard rather than in a store this game would have to
	build and pay for.

	Two rules shape what is sent:

	  * Nothing per shot or per kill. Roblox rate-limits analytics, and a
	    sixteen-player match produces hundreds of kills an hour; the useful
	    figure is kills per match, so kills are counted here and reported once
	    when the match ends.
	  * Every call is wrapped. Analytics is a reporting side channel — if it is
	    throttled, disabled in Studio, or changes shape in a future engine
	    release, that must never take a match down with it.
]]

local AnalyticsService = {}
AnalyticsService.Priority = 8

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local RobloxAnalytics = game:GetService("AnalyticsService")

local FUNNEL_NAME = "MatchFunnel"

-- Reported to the dashboard as the progression "level" for a match. This game
-- has no levels, so every match is the same one and the interesting dimension
-- is the map, carried in the statistics table instead.
local PROGRESSION_LEVEL = 1

local available = true
local matchSessions: { [Player]: { id: string, mapId: string, kills: number, startedAt: number } } = {}

--------------------------------------------------------------------------------
-- Safety
--------------------------------------------------------------------------------

--[[
	Call an AnalyticsService method, swallowing anything it throws.

	After the first failure the whole service is switched off for the rest of the
	server's life: if it is unavailable it will stay unavailable, and retrying
	every event would turn one broken dependency into a warning per kill.
]]
local function report(methodName: string, ...): boolean
	if not available then
		return false
	end

	local method = (RobloxAnalytics :: any)[methodName]
	if type(method) ~= "function" then
		available = false
		warn(`[Analytics] AnalyticsService has no {methodName}; analytics disabled for this server`)
		return false
	end

	local ok, err = pcall(method, RobloxAnalytics, ...)
	if not ok then
		available = false
		warn(`[Analytics] {methodName} failed, analytics disabled for this server: {err}`)
	end
	return ok
end

--------------------------------------------------------------------------------
-- Economy
--------------------------------------------------------------------------------

--[[
	Coins entering a player's balance.

	`reason` is the same string the award itself carries ("Kill", "Headshot",
	"Win", "Spin"), so the dashboard breaks earnings down by where they came
	from without a second vocabulary to keep in sync.
]]
function AnalyticsService.coinsEarned(player: Player, amount: number, endingBalance: number, reason: string)
	report(
		"LogEconomyEvent",
		player,
		Enum.AnalyticsEconomyFlowType.Source,
		"Coins",
		amount,
		endingBalance,
		Enum.AnalyticsEconomyTransactionType.Gameplay.Name,
		reason
	)
end

--[[
	Coins leaving a player's balance. `sku` names what they bought, which is what
	makes "which skins are dead stock" answerable.
]]
function AnalyticsService.coinsSpent(player: Player, amount: number, endingBalance: number, sku: string)
	report(
		"LogEconomyEvent",
		player,
		Enum.AnalyticsEconomyFlowType.Sink,
		"Coins",
		amount,
		endingBalance,
		Enum.AnalyticsEconomyTransactionType.Shop.Name,
		sku
	)
end

--------------------------------------------------------------------------------
-- Match funnel
--
-- The funnel is where players are lost. Queued but never played means the
-- countdown is too slow or the minimum too high; played but never finished
-- means matches are boring or one-sided.
--------------------------------------------------------------------------------

function AnalyticsService.matchQueued(player: Player, mapId: string)
	local session = HttpService:GenerateGUID(false)
	matchSessions[player] = { id = session, mapId = mapId, kills = 0, startedAt = os.clock() }
	report("LogFunnelStepEvent", player, FUNNEL_NAME, session, 1, "Queued")
end

function AnalyticsService.matchStarted(player: Player, mapId: string)
	local session = matchSessions[player]
	if not session then
		-- Joined mid-match: there was no queue step, so the funnel starts here.
		AnalyticsService.matchQueued(player, mapId)
		session = matchSessions[player]
	end

	session.mapId = mapId
	session.kills = 0
	session.startedAt = os.clock()
	report("LogFunnelStepEvent", player, FUNNEL_NAME, session.id, 2, "Playing")
end

--[[
	One kill. Counted, not sent — see the note at the top of this file.
]]
function AnalyticsService.killScored(player: Player)
	local session = matchSessions[player]
	if session then
		session.kills += 1
	end
end

--[[
	The end of a match for one player, and the only place a match reports.
]]
function AnalyticsService.matchFinished(player: Player, won: boolean, teamScore: number, enemyScore: number)
	local session = matchSessions[player]
	if not session then
		return
	end

	matchSessions[player] = nil

	report("LogFunnelStepEvent", player, FUNNEL_NAME, session.id, 3, "Finished")

	report(
		"LogProgressionEvent",
		player,
		session.mapId,
		if won then Enum.AnalyticsProgressionType.Complete else Enum.AnalyticsProgressionType.Fail,
		{
			Kills = session.kills,
			TeamScore = teamScore,
			EnemyScore = enemyScore,
			-- Whole seconds: a player who leaves early is the signal, and
			-- sub-second precision would only spread the buckets thinner.
			DurationSeconds = math.floor(os.clock() - session.startedAt),
		},
		PROGRESSION_LEVEL
	)
end

--------------------------------------------------------------------------------
-- Rewards
--------------------------------------------------------------------------------

--[[
	One spin of the reward wheel. Sent per spin rather than aggregated: spins are
	rare, and the whole point is to be able to check that what the wheel pays out
	matches the odds it advertises.
]]
function AnalyticsService.spinResolved(player: Player, segmentIndex: number, rewardKind: string, paidCoins: number)
	report("LogCustomEvent", player, "SpinResolved", 1, {
		segment = tostring(segmentIndex),
		reward = rewardKind,
		paid = tostring(paidCoins),
	})
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function AnalyticsService.cleanupPlayer(player: Player)
	matchSessions[player] = nil
end

function AnalyticsService.isAvailable(): boolean
	return available
end

function AnalyticsService.init()
	-- Nothing to set up: AnalyticsService is stateless from our side, and the
	-- per-player state above is created when a player first queues.
end

function AnalyticsService.start()
	Players.PlayerRemoving:Connect(AnalyticsService.cleanupPlayer)
end

return AnalyticsService
