--!nonstrict
--[[
	RemoteNames.luau
	Single source of truth for every remote name. The server creates the
	instances at boot (Net/Remotes.luau); the client only ever looks them up by
	these constants, so a rename can never desync the two sides.

	`Kind` documents how each remote is created:
	  Event      -> RemoteEvent
	  Function   -> RemoteFunction (client -> server only, never InvokeClient)
	  Unreliable -> UnreliableRemoteEvent (cosmetic, loss-tolerant traffic only)
]]

local RemoteNames = {}

-- Client -> Server
RemoteNames.ShootRequest = "ShootRequest"
RemoteNames.ReloadRequest = "ReloadRequest"
RemoteNames.EquipWeaponRequest = "EquipWeaponRequest"
RemoteNames.BuySkinRequest = "BuySkinRequest"
RemoteNames.EquipSkinRequest = "EquipSkinRequest"
RemoteNames.SpinRequest = "SpinRequest"
RemoteNames.GetFriendsRequest = "GetFriendsRequest"
RemoteNames.SaveSettingsRequest = "SaveSettingsRequest"

-- Server -> Client
RemoteNames.ProfileLoaded = "ProfileLoaded"
RemoteNames.CoinsChanged = "CoinsChanged"
RemoteNames.MatchStateChanged = "MatchStateChanged"
RemoteNames.MatchTick = "MatchTick"
RemoteNames.QueueUpdate = "QueueUpdate"
RemoteNames.ShotFired = "ShotFired"
RemoteNames.HitConfirmed = "HitConfirmed"
RemoteNames.DamageTaken = "DamageTaken"
RemoteNames.KillFeedEvent = "KillFeedEvent"
RemoteNames.DeathInfo = "DeathInfo"
RemoteNames.AmmoSync = "AmmoSync"
RemoteNames.Notice = "Notice"

-- Declarative manifest consumed by Net/Remotes.init().
RemoteNames.MANIFEST = {
	{ name = RemoteNames.ShootRequest, kind = "Event" },
	{ name = RemoteNames.ReloadRequest, kind = "Event" },
	{ name = RemoteNames.EquipWeaponRequest, kind = "Event" },
	{ name = RemoteNames.BuySkinRequest, kind = "Function" },
	{ name = RemoteNames.EquipSkinRequest, kind = "Function" },
	{ name = RemoteNames.SpinRequest, kind = "Function" },
	{ name = RemoteNames.GetFriendsRequest, kind = "Function" },
	-- An Event rather than a Function: the client applies a setting the moment
	-- it is dragged and never waits on the server, so there is nothing to return.
	{ name = RemoteNames.SaveSettingsRequest, kind = "Event" },

	{ name = RemoteNames.ProfileLoaded, kind = "Event" },
	{ name = RemoteNames.CoinsChanged, kind = "Event" },
	{ name = RemoteNames.MatchStateChanged, kind = "Event" },
	{ name = RemoteNames.MatchTick, kind = "Unreliable" },
	{ name = RemoteNames.QueueUpdate, kind = "Event" },
	{ name = RemoteNames.ShotFired, kind = "Unreliable" },
	{ name = RemoteNames.HitConfirmed, kind = "Event" },
	{ name = RemoteNames.DamageTaken, kind = "Event" },
	{ name = RemoteNames.KillFeedEvent, kind = "Event" },
	{ name = RemoteNames.DeathInfo, kind = "Event" },
	{ name = RemoteNames.AmmoSync, kind = "Event" },
	-- A short banner the player reads wherever they are. Reliable rather than
	-- unreliable: the one message it carries today explains why somebody is
	-- about to be taken out of a match, and a dropped packet would make that
	-- removal look arbitrary.
	{ name = RemoteNames.Notice, kind = "Event" },
}

return RemoteNames
