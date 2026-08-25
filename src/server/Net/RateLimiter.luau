--!nonstrict
--[[
	RateLimiter.luau
	Player-keyed wrapper around RateLimiterCore: supplies the clock, keeps one
	State per player and escalates repeat offenders to a kick.

	Per-player state is dropped by cleanupPlayer(), which Net/Remotes.luau calls
	from the server bootstrap's PlayerRemoving handler. Nothing here connects to
	Players itself, so this module owns no connections to leak.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local RateLimiterCore = require(script.Parent.RateLimiterCore)

local RateLimiter = {}

export type Config = {
	maxRequests: number?,
	windowSeconds: number?,
	cooldownSeconds: number?,
	kickAfterViolations: number?,
	kickMessage: string?,
}

local DEFAULTS = Constants.REMOTE_DEFAULTS

local states: { [Player]: RateLimiterCore.State } = {}

local function stateFor(player: Player): RateLimiterCore.State
	local state = states[player]
	if not state then
		state = RateLimiterCore.newState()
		states[player] = state
	end
	return state
end

--[[
	Returns true when `player` may perform `action` right now. Anything omitted
	from `config` falls back to Constants.REMOTE_DEFAULTS.
]]
function RateLimiter.check(player: Player, action: string, config: Config?): boolean
	local settings: Config = config or {}
	local state = stateFor(player)

	local allowed, violation = RateLimiterCore.check(state, action, os.clock(), {
		maxRequests = settings.maxRequests or DEFAULTS.maxRequests,
		windowSeconds = settings.windowSeconds or DEFAULTS.windowSeconds,
		cooldownSeconds = settings.cooldownSeconds or DEFAULTS.cooldownSeconds,
	})

	if violation then
		local count = RateLimiterCore.violations(state, action)
		local threshold = settings.kickAfterViolations or DEFAULTS.kickAfterViolations

		if threshold and threshold > 0 and count >= threshold then
			warn(`[RateLimiter] Kicking {player.Name}: {count} violations on "{action}"`)
			-- Deferred because the kick runs while a remote handler is still on
			-- the stack; unwinding it there would surface as an error to the
			-- caller instead of a clean disconnect.
			task.defer(function()
				if player.Parent then
					player:Kick(settings.kickMessage or DEFAULTS.kickMessage)
				end
			end)
		else
			warn(`[RateLimiter] {player.Name} rate limited on "{action}" (violation #{count})`)
		end
	end

	return allowed
end

function RateLimiter.violations(player: Player, action: string): number
	local state = states[player]
	return if state then RateLimiterCore.violations(state, action) else 0
end

--[[
	Clear one action's window for a player. Used when a legitimate state change
	makes the recorded history meaningless (for example a match ending).
]]
function RateLimiter.reset(player: Player, action: string)
	local state = states[player]
	if state then
		RateLimiterCore.reset(state, action)
	end
end

function RateLimiter.cleanupPlayer(player: Player)
	states[player] = nil
end

return RateLimiter
