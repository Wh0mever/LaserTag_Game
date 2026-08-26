--!nonstrict
--[[
	MatchService.luau
	Owns one MatchRuntime per playable map and drives them all from a single
	heartbeat loop.

	Priority 5 — after PlayerService (4), because starting a match means spawning
	characters, and alongside QueueService, which feeds it.

	One loop, not one per map: a `while true do task.wait(1) end` per map drifts
	independently and each one costs a scheduler slot, whereas an accumulator on
	Heartbeat steps every map from the same measured delta. The delta is passed
	through to the runtimes rather than assumed, so a frame hitch shortens the
	match by the time it really took rather than by a nominal second.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local GameConfig = require(Shared.Config.GameConfig)
local MatchRuntime = require(script.Parent.Parent.Match.MatchRuntime)
local MatchStateMachine = require(script.Parent.Parent.Match.MatchStateMachine)
local Trove = require(Shared.Util.Trove)

local MatchService = {}
MatchService.Priority = 5

local runtimes: { [string]: any } = {}
local trove = Trove.new()
local accumulator = 0

function MatchService.init()
	for _, mapId in Constants.MAPS do
		runtimes[mapId] = MatchRuntime.new(mapId)
	end
end

function MatchService.start()
	trove:Connect(RunService.Heartbeat, function(dt: number)
		accumulator += dt
		if accumulator < GameConfig.TICK_INTERVAL then
			return
		end

		local step = accumulator
		accumulator = 0

		for _, mapId in Constants.MAPS do
			local runtime = runtimes[mapId]
			if runtime then
				local ok, err = pcall(runtime.tick, runtime, step)
				if not ok then
					warn(`[MatchService] {mapId} tick failed: {err}`)
				end
			end
		end
	end)
end

function MatchService.getRuntime(mapId: string)
	return runtimes[mapId]
end

--[[
	Which runtime a player belongs to. The InMatch attribute is the fast path;
	the roster scan behind it covers the window between a runtime adding somebody
	and the attribute replicating, which is exactly when a kill is most likely to
	arrive.
]]
local function runtimeForPlayer(player: Player?)
	if not player then
		return nil
	end

	local mapId = player:GetAttribute("InMatch")
	if type(mapId) == "string" and runtimes[mapId] then
		return runtimes[mapId]
	end

	for _, runtime in runtimes do
		if runtime:isPlaying(player) then
			return runtime
		end
	end

	return nil
end

--[[
	Called by QueueService with everyone standing on `mapId`'s portal pad.
	Queueing is not a remote: a pad sample cannot be spoofed by a client.
]]
function MatchService.onQueueChanged(mapId: string, players: { Player })
	local runtime = runtimes[mapId]
	if not runtime then
		warn(`[MatchService] queue change for unknown map "{tostring(mapId)}"`)
		return
	end
	runtime:onQueueChanged(players or {})
end

--[[
	Called by CombatService once a kill is final. Routing is by the victim, then
	the killer: the victim is always in the match the kill happened in, whereas a
	killer could in principle have already left it.
]]
function MatchService.registerKill(victim: Player, killer: Player?, weaponId: string?, isHeadshot: boolean)
	local runtime = runtimeForPlayer(victim) or runtimeForPlayer(killer)
	if not runtime then
		return
	end
	runtime:registerKill(victim, killer, weaponId, isHeadshot == true)
end

function MatchService.getPhase(mapId: string): string
	local runtime = runtimes[mapId]
	return if runtime then runtime:getPhase() else MatchStateMachine.States.Idle
end

function MatchService.isInProgress(mapId: string): boolean
	local runtime = runtimes[mapId]
	return runtime ~= nil and runtime:isInProgress()
end

--[[
	Whole seconds left before `mapId` starts, or nil when no countdown is running.
	QueueService paints this onto the portal signs.
]]
function MatchService.getCountdown(mapId: string): number?
	local runtime = runtimes[mapId]
	return if runtime then runtime:getCountdown() else nil
end

function MatchService.getQueueCount(mapId: string): number
	local runtime = runtimes[mapId]
	return if runtime then runtime:getQueueCount() else 0
end

function MatchService.getScores(mapId: string): { A: number, B: number }
	local runtime = runtimes[mapId]
	return if runtime then runtime:getScores() else { A = 0, B = 0 }
end

--[[
	Which map a player is playing on, or nil in the hub. Other services use this
	instead of reading the InMatch attribute directly so the roster stays the
	single source of truth.
]]
function MatchService.getMapFor(player: Player): string?
	for mapId, runtime in runtimes do
		if runtime:isPlaying(player) then
			return mapId
		end
	end
	return nil
end

--[[
	Every runtime is told, not just the one holding the player: a leaver can be
	queued on one map's pad while playing on none, and the queue has to shrink
	either way.
]]
function MatchService.onPlayerRemoving(player: Player)
	for mapId, runtime in runtimes do
		local ok, err = pcall(runtime.onPlayerRemoving, runtime, player)
		if not ok then
			warn(`[MatchService] {mapId} could not release {player.Name}: {err}`)
		end
	end
end

function MatchService.forceEnd(mapId: string)
	local runtime = runtimes[mapId]
	if runtime then
		runtime:forceEnd()
	end
end

return MatchService
