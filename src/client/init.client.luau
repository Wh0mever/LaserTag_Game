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
end)

local clientRoot = script

local controllers = Loader.load(clientRoot.Controllers)
Loader.init(controllers)
Loader.start(controllers)

local screens = Loader.load(clientRoot.UI)
Loader.init(screens)
Loader.start(screens)

print(`[LaserTag] Client ready — {#controllers} controllers, {#screens} UI modules`)
