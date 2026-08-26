--!nonstrict
--[[
	init.server.luau
	Server entry point (Rojo turns this folder into a single Script named
	"Server" under ServerScriptService).

	Boot order:
	  1. Create every RemoteEvent / RemoteFunction so clients can WaitForChild
	     them without racing the services that register handlers.
	  2. Load all Services (two-pass init/start via the shared Loader).
	  3. Hand player lifecycle events to PlayerService.
	  4. Register BindToClose so profiles and the leaderboard flush on shutdown.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local Loader = require(Shared.Loader)

local ServerRoot = ServerScriptService:WaitForChild("Server")
local Remotes = require(ServerRoot.Net.Remotes)

print(`[LaserTag] Server booting ({Constants.VERSION})`)

-- Step 1: remotes exist before anything else runs.
Remotes.init()

-- Step 2: load services.
local services = Loader.load(ServerRoot.Services)
Loader.init(services)
Loader.start(services)

local serviceMap = Loader.toMap(services)

-- Step 3: player lifecycle. PlayerService owns spawning and cleanup; the other
-- services expose cleanup hooks that it calls, so wiring lives in one place.
local PlayerService = serviceMap.PlayerService

Players.PlayerAdded:Connect(function(player)
	if PlayerService then
		PlayerService.onPlayerAdded(player)
	end
end)

Players.PlayerRemoving:Connect(function(player)
	if PlayerService then
		PlayerService.onPlayerRemoving(player)
	end
	Remotes.cleanupPlayer(player)
end)

-- Players who joined while the server was still booting.
for _, player in Players:GetPlayers() do
	task.spawn(function()
		if PlayerService then
			PlayerService.onPlayerAdded(player)
		end
	end)
end

-- Step 4: shutdown handling.
game:BindToClose(function()
	print("[LaserTag] Server shutting down")

	local leaderboard = serviceMap.LeaderboardService
	if leaderboard and leaderboard.flushAll then
		pcall(leaderboard.flushAll)
	end

	local data = serviceMap.DataService
	if data and data.releaseAll then
		pcall(data.releaseAll)
	end
end)

print(`[LaserTag] Server ready — {#services} services loaded`)
