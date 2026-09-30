--!nonstrict
--[[
	init.client.luau
	Client entry point (Rojo turns this folder into a single LocalScript named
	"Client" under StarterPlayerScripts).

	Boot order:
	  1. Wait for the shared modules and the server-created Remotes folder.
	  2. Load Controllers (input, camera, weapons, VFX) — they own game feel.
	  3. Load UI screens once controllers exist, so screens can subscribe to
	     controller signals during their own init().

	ResetButton and ClientState sit beside this file rather than in a folder the
	Loader walks: they are required by whoever needs them, not run as modules.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Constants = require(Shared.Constants)
local Loader = require(Shared.Loader)

-- The server creates this folder during its own boot; a generous timeout keeps
-- the failure loud instead of hanging forever (sharp edge SE-11).
local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 30)
if not remotesFolder then
	error("[LaserTag] Remotes folder never replicated — server boot failed", 0)
end

print(`[LaserTag] Client booting ({Constants.VERSION})`)

-- Roblox default UI we replace with our own HUD.
pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	-- Our scoreboard replaces it. Left on, Roblox's list sat in the top-right
	-- corner over the kill feed, and Tab opened both at once.
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
end)

-- Roblox's own Reset Character option is a way out of a lost duel; it is off
-- for the length of a match. Started first so it is already following the
-- player when the first match begins.
local resetOk, resetErr = pcall(function()
	require(script.ResetButton).watch()
end)
if not resetOk then
	warn(`[LaserTag] Reset button control failed to start: {resetErr}`)
end

local clientRoot = script

local controllers = Loader.load(clientRoot.Controllers)
Loader.init(controllers)
Loader.start(controllers)

local screens = Loader.load(clientRoot.UI)
Loader.init(screens)
Loader.start(screens)

print(`[LaserTag] Client ready — {#controllers} controllers, {#screens} UI modules`)
