--!nonstrict
--[[
	SettingsService.luau
	Stores a player's sensitivity, volume and field of view on their profile.

	These are cosmetic client preferences, and every one of them is applied on
	the client the instant it moves — nothing here affects what the server
	believes about aim, damage or anything else a player could gain from. The
	server's only job is to remember them across sessions.

	That does not make the payload trustworthy. SettingsConfig.sanitize is TOTAL:
	it turns any input at all into a complete, in-range table, dropping unknown
	keys. Without that, a remote whose whole purpose is "write this table to my
	persisted profile" is free storage for anyone who cares to use it, and a
	profile that fails to serialise takes the player's coins and skins with it.

	The remote is an Event rather than a Function because the client never waits
	on the answer — it has already applied the value locally. A save that fails
	costs a preference, not a session.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local DataService = require(script.Parent.DataService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local SettingsConfig = require(Shared.Config.SettingsConfig)

local SettingsService = {}
-- After DataService (1), which owns the profile this writes into.
SettingsService.Priority = 8

-- Dragging a slider fires on release, not per frame, so this is generous. It
-- exists to bound a scripted client rather than to shape honest use.
local SAVE_RATE = 12
local SAVE_WINDOW = 10

--[[
	The payload must be a table and nothing else. Depth and contents are
	`sanitize`'s problem; this only rejects the shapes that are not worth
	handing on — and a non-table is the whole of that set.
]]
local function validateSave(_player: Player, settings: any): boolean
	return type(settings) == "table"
end

local function onSaveSettings(player: Player, settings: any)
	DataService.setSettings(player, SettingsConfig.sanitize(settings))
end

function SettingsService.init()
	Remotes.register({
		Name = RemoteNames.SaveSettingsRequest,
		Type = "Event",
		Handler = onSaveSettings,
		Validator = validateSave,
		RateLimit = SAVE_RATE,
		WindowSeconds = SAVE_WINDOW,
	})
end

return SettingsService
