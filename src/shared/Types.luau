--!strict
--[[
	Types.luau
	Shared Luau type definitions. Requiring this module returns nil on purpose —
	it exists for `local Types = require(...)` type-only usage and for
	documentation of every payload crossing the network boundary.
]]

-- Plain data used by the pure modules (no Roblox constructors).
export type RGB = { r: number, g: number, b: number }
export type Vec3 = { x: number, y: number, z: number }

-- Persistence -------------------------------------------------------------

export type PlayerStats = {
	Kills: number,
	Deaths: number,
	Wins: number,
	MatchesPlayed: number,
	BestKillsInMatch: number,
}

export type SpinState = {
	LastFreeSpinAt: number, -- os.time() of the last free spin
	Pity: number, -- consecutive spins without a skin
	TotalSpins: number,
}

export type LaserTagData = {
	DataVersion: number,
	Coins: number,
	Stats: PlayerStats,
	OwnedSkins: { [string]: boolean },
	EquippedSkins: { [string]: string }, -- weaponId -> skinId
	Spin: SpinState,
}

-- Configuration -----------------------------------------------------------

export type WeaponKick = { pitch: number, yaw: number }

export type WeaponDef = {
	id: string,
	displayName: string,
	slot: number,
	automatic: boolean,
	damage: number,
	headshotMultiplier: number,
	fireRate: number, -- seconds between shots
	magSize: number,
	reloadTime: number,
	range: number, -- studs
	baseSpreadDeg: number,
	sprayResetTime: number,
	recoilRecovery: number, -- degrees per second
	beamWidth: number,
}

export type SkinDef = {
	id: string,
	displayName: string,
	price: number,
	rarity: string,
	color: RGB,
	accentColor: RGB,
	isDefault: boolean,
	pattern: string?, -- optional beam texture behaviour ("pulse", "galaxy", ...)
}

export type WheelSegment = {
	id: string,
	kind: string, -- "coins" | "skin"
	label: string,
	weight: number, -- disclosed percentage; all segments sum to 100
	coins: number?,
	skinId: string?,
}

-- Map definitions ---------------------------------------------------------

export type MapElement = {
	kind: string,
	[string]: any,
}

export type MapDef = {
	id: string,
	displayName: string,
	origin: Vec3,
	killY: number,
	palette: { [string]: RGB },
	elements: { MapElement },
}

-- Match -------------------------------------------------------------------

export type MatchPhase = "Idle" | "WaitingForPlayers" | "Countdown" | "InProgress" | "Results"

export type MatchScores = { A: number, B: number }

export type MatchStatePayload = {
	mapId: string,
	phase: MatchPhase,
	timeLeft: number?,
	scores: MatchScores?,
	winnerTeam: string?, -- nil on a draw
	rewards: { [string]: number }?,
}

-- Network payloads --------------------------------------------------------

export type ShotPayload = {
	weaponId: string,
	seq: number,
	origin: Vector3,
	direction: Vector3,
}

export type HitConfirmPayload = {
	victimUserId: number,
	damage: number,
	isHeadshot: boolean,
	hitPosition: Vector3,
	killed: boolean,
}

export type KillFeedPayload = {
	killerName: string?,
	killerTeam: string?,
	victimName: string,
	victimTeam: string,
	weaponId: string?,
	isHeadshot: boolean,
}

export type ShopResult = {
	ok: boolean,
	err: string?,
	coins: number?,
	skinId: string?,
}

export type SpinResult = {
	ok: boolean,
	err: string?,
	segmentId: string?,
	segmentIndex: number?,
	rewardKind: string?,
	rewardLabel: string?,
	coins: number?,
	nextFreeAt: number?,
	pity: number?,
}

return nil
