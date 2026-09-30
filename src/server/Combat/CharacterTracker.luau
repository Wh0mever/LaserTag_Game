--!nonstrict
--[[
	CharacterTracker.luau
	What the server remembers about where each character is, and where it has
	been. Two things are built on it, and both exist for the same reason: a
	character belongs to its client, so its position is a claim, not a fact.

	  * WHERE A SHOT COMES FROM. The server keeps a second position per player
	    that follows the real one but may not outrun a player (MovementBudget).
	    Shots are resolved from that. An honest player is never told apart from
	    their shadow; a client that jumps its character across the map and fires
	    in the same frame fires from where it could actually have got to.

	  * WHERE A TARGET WAS. Every character's position is remembered for a short
	    while (PositionHistory) so a shot can be tested against the world the
	    shooter was looking at, not the one that exists by the time the shot
	    arrives.

	Nothing here moves a character or refuses a shot. It answers questions;
	ShotResolver and ShootValidation decide what to do with the answers.

	Sampling runs on Heartbeat (CombatService connects it), once per frame for
	every tracked character: a few table writes each, no allocation.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local MathUtil = require(Shared.Util.MathUtil)
local MovementBudget = require(script.Parent.MovementBudget)
local PositionHistory = require(script.Parent.PositionHistory)

local CharacterTracker = {}

--[[
	Movement is allowed to cost twice walking speed. That is not generosity for
	its own sake: climbing counts as well as running (see MovementBudget), so a
	player who strafes and jumps at once spends around 1.7x, and the limit exists
	to stop crossing a map in a frame, not to police the last few studs an hour.
	One second of it can be banked, which is how a phone that freezes and then
	delivers its last second of running in one packet fits. A teleport is
	therefore limited to about a second's worth of walking, and the shadow catches
	up at twice walking speed after that.
]]
local MOVE_RATE = Constants.WALK_SPEED * 2
local CREDIT_CAP = MOVE_RATE * 1

-- A full second of samples at 60 Hz with room to spare for a faster server.
local HISTORY_SAMPLES = 120

-- Roughly how far behind the present other players are drawn on a client, over
-- and above the trip the shot itself takes: Roblox interpolates remote
-- characters between the updates it receives.
local INTERPOLATION_SECONDS = 0.1

-- The most a shot may be rewound. Every second of it is a second in which a
-- target who has already run behind cover can still be hit, so it is bounded
-- whatever the shooter's connection says.
local MAX_REWIND_SECONDS = 0.3

type Tracked = {
	character: Model,
	root: BasePart?,
	history: PositionHistory.History,
	-- nil until the server has placed the character (see rebaseline).
	movement: MovementBudget.State?,
}

local tracked: { [Player]: Tracked } = {}

local function rootOf(entry: Tracked): BasePart?
	local root = entry.root
	if root and root.Parent then
		return root
	end

	local found = entry.character:FindFirstChild("HumanoidRootPart")
	root = if found and found:IsA("BasePart") then found else nil
	entry.root = root
	return root
end

local function isFiniteVector(at: Vector3): boolean
	return MathUtil.isFinite(at.X) and MathUtil.isFinite(at.Y) and MathUtil.isFinite(at.Z)
end

--[[
	Start following a new life. Everything about the last one is dropped: its
	history ends wherever it died, and rewinding into it would put a respawned
	player where they no longer are.

	The shadow is not started here. A character is created at the default spawn
	and only then moved to its team's room, so its position now is not where the
	server will place it; see rebaseline.
]]
function CharacterTracker.begin(player: Player, character: Model)
	tracked[player] = {
		character = character,
		root = nil,
		history = PositionHistory.new(HISTORY_SAMPLES),
		movement = nil,
	}
end

function CharacterTracker.forget(player: Player)
	tracked[player] = nil
end

--[[
	The server has just put the character somewhere on purpose: take that as the
	place it stands. Starts the shadow there with a full bank, and forgets the
	history, which describes wherever the character was before it was moved.

	Until this has happened the shadow does not exist, and the character's live
	position is used as it stands -- the same as before the shadow existed. That
	is deliberate. A shadow started too early (at creation, before the move to
	the spawn room) would hold every shot of an honest player back at the default
	spawn, which is worse than the exploit it guards against.

	CombatService calls this when PlayerService stamps the new life's spawn
	protection, which it does straight after placing the character. A server
	feature that moves a living character has to call it as well.
]]
function CharacterTracker.rebaseline(player: Player, now: number)
	local entry = tracked[player]
	local root = entry and rootOf(entry)
	if not entry or not root then
		return
	end

	local at = root.Position
	if not isFiniteVector(at) then
		return
	end

	PositionHistory.clear(entry.history)
	PositionHistory.record(entry.history, now, at.X, at.Y, at.Z)
	entry.movement = MovementBudget.new(at.X, at.Y, at.Z, now, CREDIT_CAP)
end

--[[
	One frame: remember where everyone is and let every shadow follow.
]]
function CharacterTracker.step(now: number)
	for _, entry in tracked do
		local root = rootOf(entry)
		if not root then
			continue
		end

		local at = root.Position
		if not isFiniteVector(at) then
			continue
		end

		PositionHistory.record(entry.history, now, at.X, at.Y, at.Z)

		local movement = entry.movement
		if movement then
			MovementBudget.step(movement, at.X, at.Y, at.Z, now, MOVE_RATE, CREDIT_CAP)
		end
	end
end

--[[
	The position the server will resolve this player's shots from: the shadow,
	or the live root if the character has not been placed yet or is not being
	followed at all. Nil when there is no character to shoot from.
]]
function CharacterTracker.rootPosition(player: Player): Vector3?
	local character = player.Character
	local entry = tracked[player]

	if entry and entry.character == character then
		local root = rootOf(entry)
		if not root then
			return nil
		end

		local movement = entry.movement
		if movement then
			return Vector3.new(movement.x, movement.y, movement.z)
		end
		return root.Position
	end

	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

-- Where the server believes the player's eyes are; shots leave from here.
function CharacterTracker.eyePosition(player: Player): Vector3?
	local at = CharacterTracker.rootPosition(player)
	if not at then
		return nil
	end
	return at + Vector3.new(0, Constants.HEAD_OFFSET_Y, 0)
end

--[[
	How far back to judge a shot by this player, in seconds. The engine reports
	each player's network latency; it is counted once here, which is right if it
	is the round trip and short by one trip if it is one way. Falling short only
	means a little less compensation, never a hit on somebody who was not there.
]]
function CharacterTracker.rewindSeconds(player: Player): number
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return PositionHistory.rewindSeconds(if ok then ping else nil, INTERPOLATION_SECONDS, MAX_REWIND_SECONDS)
end

--[[
	Where the player's root was `secondsAgo` before `now`, or nil if nothing is
	remembered of this life (it began too recently to have a history).
]]
function CharacterTracker.rootPositionAgo(player: Player, secondsAgo: number, now: number): Vector3?
	local entry = tracked[player]
	if not entry or entry.character ~= player.Character then
		return nil
	end

	local x, y, z = PositionHistory.at(entry.history, now - secondsAgo)
	if not x then
		return nil
	end
	return Vector3.new(x, y, z)
end

return CharacterTracker
