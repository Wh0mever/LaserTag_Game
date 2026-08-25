--!nonstrict
--[[
	Remotes.luau
	Creates ReplicatedStorage.Remotes and every instance in RemoteNames.MANIFEST,
	then wires handlers behind one shared security pipeline:

		rate limit  ->  cooldown  ->  validator  ->  handler

	init() runs before any service loads so a client can WaitForChild every remote
	without racing the service that eventually registers a handler for it.

	A request that fails any stage is dropped in silence — no error is raised back
	across the wire and no value is returned. Telling a client which stage
	rejected it turns the pipeline into an oracle: an exploiter can binary-search
	the accepted payload shape from the error messages alone. The server console
	still gets a warning, because the operator does need to see it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local RateLimiter = require(script.Parent.RateLimiter)
local RemoteNames = require(Shared.RemoteNames)

local Remotes = {}

export type RegisterConfig = {
	Name: string,
	Type: string?, -- "Event" (default), "Function" or "Unreliable"
	Handler: (Player, ...any) -> ...any,
	Validator: ((Player, ...any) -> (boolean, string?))?,
	RateLimit: number?, -- accepted requests per WindowSeconds
	WindowSeconds: number?,
	Cooldown: number?, -- minimum seconds between two accepted requests
	KickAfterViolations: number?,
}

local FOLDER_NAME = "Remotes"

local CLASS_BY_KIND: { [string]: string } = {
	Event = "RemoteEvent",
	Function = "RemoteFunction",
	Unreliable = "UnreliableRemoteEvent",
}

local remotesFolder: Folder? = nil
local cache: { [string]: Instance } = {}
local connections: { [string]: RBXScriptConnection } = {}
local registered: { [string]: boolean } = {}
local cooldowns: { [Player]: { [string]: number } } = {}

local function ensureFolder(): Folder
	if remotesFolder and remotesFolder.Parent then
		return remotesFolder
	end

	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		remotesFolder = existing
	else
		local folder = Instance.new("Folder")
		folder.Name = FOLDER_NAME
		folder.Parent = ReplicatedStorage
		remotesFolder = folder
	end

	return remotesFolder
end

local function createRemote(name: string, kind: string): Instance
	local cached = cache[name]
	if cached and cached.Parent then
		return cached
	end

	local folder = ensureFolder()
	local existing = folder:FindFirstChild(name)
	if existing then
		cache[name] = existing
		return existing
	end

	local remote = Instance.new(CLASS_BY_KIND[kind] or CLASS_BY_KIND.Event)
	remote.Name = name
	remote.Parent = folder
	cache[name] = remote
	return remote
end

--[[
	Create ReplicatedStorage.Remotes and every manifest entry. Idempotent, so a
	second call after a hot reload reuses whatever already exists.
]]
function Remotes.init()
	ensureFolder()

	for _, entry in RemoteNames.MANIFEST do
		createRemote(entry.name, entry.kind)
	end
end

function Remotes.get(name: string): Instance?
	local cached = cache[name]
	if cached and cached.Parent then
		return cached
	end

	local folder = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	local remote = folder and folder:FindFirstChild(name)
	if remote then
		cache[name] = remote
		return remote
	end

	return nil
end

--[[
	Minimum spacing between two accepted requests, tracked separately from the
	sliding window: the window caps sustained throughput, this caps burst timing.
]]
local function passesCooldown(player: Player, name: string, seconds: number): boolean
	if seconds <= 0 then
		return true
	end

	local perPlayer = cooldowns[player]
	if not perPlayer then
		perPlayer = {}
		cooldowns[player] = perPlayer
	end

	local now = os.clock()
	local last = perPlayer[name]
	if last and now - last < seconds then
		return false
	end

	perPlayer[name] = now
	return true
end

--[[
	Run one request through the pipeline. Returns a packed result list on success
	(so a RemoteFunction can return every value the handler produced) and nil on
	any rejection.
]]
local function runPipeline(config: RegisterConfig, limits, cooldownSeconds: number, player: Player, ...): { any }?
	if not RateLimiter.check(player, config.Name, limits) then
		return nil
	end

	if not passesCooldown(player, config.Name, cooldownSeconds) then
		return nil
	end

	if config.Validator then
		-- A validator that throws counts as a rejection. Letting the error escape
		-- would surface it to the client on a RemoteFunction, which is exactly the
		-- feedback this pipeline exists to withhold.
		local ran, ok, reason = pcall(config.Validator, player, ...)
		if not ran then
			warn(`[Remotes] Validator for "{config.Name}" errored: {tostring(ok)}`)
			return nil
		end
		if not ok then
			warn(`[Remotes] {player.Name} failed validation on "{config.Name}": {reason or "unspecified"}`)
			return nil
		end
	end

	local packed = table.pack(pcall(config.Handler, player, ...))
	if packed[1] ~= true then
		warn(`[Remotes] Handler for "{config.Name}" errored: {tostring(packed[2])}`)
		return nil
	end

	-- Re-pack without the pcall success flag. table.remove is not usable here: it
	-- works off `#`, and a handler is allowed to return a nil among its results.
	return table.pack(table.unpack(packed, 2, packed.n))
end

--[[
	Attach a handler to a remote, creating the instance if the manifest did not.
	See RegisterConfig above for the accepted fields.
]]
function Remotes.register(config: RegisterConfig)
	assert(type(config.Name) == "string", "Remotes.register requires a Name")
	assert(type(config.Handler) == "function", `Remotes.register requires a Handler for "{config.Name}"`)

	local kind = config.Type or "Event"
	local remote = createRemote(config.Name, kind)

	if registered[config.Name] then
		warn(`[Remotes] "{config.Name}" was registered twice; the newer handler wins`)
	end
	registered[config.Name] = true

	local defaults = Constants.REMOTE_DEFAULTS
	local limits = {
		maxRequests = config.RateLimit or defaults.maxRequests,
		windowSeconds = config.WindowSeconds or defaults.windowSeconds,
		cooldownSeconds = defaults.cooldownSeconds,
		kickAfterViolations = config.KickAfterViolations or defaults.kickAfterViolations,
		kickMessage = defaults.kickMessage,
	}
	local cooldownSeconds = config.Cooldown or 0

	if kind == "Function" then
		local remoteFunction = remote :: RemoteFunction

		remoteFunction.OnServerInvoke = function(player: Player, ...)
			local results = runPipeline(config, limits, cooldownSeconds, player, ...)
			if not results then
				return nil
			end
			return table.unpack(results, 1, results.n)
		end
	else
		local previous = connections[config.Name]
		if previous then
			previous:Disconnect()
		end

		connections[config.Name] = remote.OnServerEvent:Connect(function(player: Player, ...)
			runPipeline(config, limits, cooldownSeconds, player, ...)
		end)
	end
end

local function fireableRemote(name: string): Instance?
	local remote = Remotes.get(name)
	if remote and (remote:IsA("RemoteEvent") or remote:IsA("UnreliableRemoteEvent")) then
		return remote
	end

	warn(`[Remotes] "{name}" is not a fireable remote`)
	return nil
end

function Remotes.fireClient(name: string, player: Player, ...)
	local remote = fireableRemote(name)
	if remote then
		remote:FireClient(player, ...)
	end
end

function Remotes.fireAllClients(name: string, ...)
	local remote = fireableRemote(name)
	if remote then
		remote:FireAllClients(...)
	end
end

function Remotes.fireAllClientsExcept(name: string, excludedPlayer: Player, ...)
	local remote = fireableRemote(name)
	if not remote then
		return
	end

	for _, player in Players:GetPlayers() do
		if player ~= excludedPlayer then
			remote:FireClient(player, ...)
		end
	end
end

function Remotes.cleanupPlayer(player: Player)
	cooldowns[player] = nil
	RateLimiter.cleanupPlayer(player)
end

return Remotes
