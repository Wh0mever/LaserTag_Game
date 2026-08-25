--!nonstrict
--[[
	Validators.luau
	Argument checks shared by every remote handler. Everything arriving from a
	client is hostile until one of these functions has cleared it.

	The rule the whole file exists to enforce: a value that survives `typeof()`
	can still be poison. NaN and the infinities are numbers, a Vector3 can carry
	them component-wise, and a "direction" of magnitude 1e9 turns a raycast into a
	world-spanning ray. Every number that crosses the wire therefore goes through
	MathUtil.isFinite before any arithmetic touches it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local MathUtil = require(Shared.Util.MathUtil)

local Validators = {}

-- Client and server compute a look direction from different float paths, so an
-- exactly-unit vector is not reachable; this is the slack allowed on |v| == 1.
local DEFAULT_UNIT_TOLERANCE = 0.01

function Validators.isFiniteVector3(value: any): boolean
	if typeof(value) ~= "Vector3" then
		return false
	end
	return MathUtil.isFinite(value.X) and MathUtil.isFinite(value.Y) and MathUtil.isFinite(value.Z)
end

function Validators.isUnitVector(value: any, tolerance: number?): boolean
	if not Validators.isFiniteVector3(value) then
		return false
	end

	local magnitude = value.Magnitude
	if not MathUtil.isFinite(magnitude) then
		return false
	end

	return math.abs(magnitude - 1) <= (tolerance or DEFAULT_UNIT_TOLERANCE)
end

function Validators.isPositiveInteger(value: any): boolean
	return MathUtil.isFinite(value) and value > 0 and math.floor(value) == value
end

-- Schema entries whose typeof() name alone is not a sufficient check. Routing
-- numbers and vectors through here means no individual call site can forget the
-- finiteness test.
local EXTRA_CHECKS: { [string]: (any) -> boolean } = {
	number = function(value: any): boolean
		return MathUtil.isFinite(value)
	end,
	Vector3 = function(value: any): boolean
		return Validators.isFiniteVector3(value)
	end,
}

--[[
	Validate a positional argument list against a list of typeof() names.

	`schema` entries are typeof() names, optionally suffixed with "?" to mark the
	argument optional: {"string", "number", "Vector3?"}.

	`args` may be a plain array or the result of table.pack(...); when `args.n` is
	present it wins, which is what makes a trailing nil countable rather than
	invisible to `#`.

	Extra arguments are rejected as hard as wrong ones. A caller that sends more
	values than the schema declares is not a client of this game — it is probing
	for a handler that forwards varargs somewhere.
]]
function Validators.checkTypes(args: { any }, schema: { string }): (boolean, string?)
	local count = if type(args.n) == "number" then args.n else #args

	if count > #schema then
		return false, `expected at most {#schema} argument(s), got {count}`
	end

	for index, entry in ipairs(schema) do
		local optional = string.sub(entry, -1) == "?"
		local expected = if optional then string.sub(entry, 1, -2) else entry
		local value = args[index]

		if value == nil then
			if not optional then
				return false, `argument #{index} is missing (expected {expected})`
			end
			continue
		end

		local extra = EXTRA_CHECKS[expected]
		local ok = if extra then extra(value) else typeof(value) == expected

		if not ok then
			return false, `argument #{index} expected {expected}, got {typeof(value)}`
		end
	end

	return true, nil
end

function Validators.isAlive(player: any): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end

	local character = player.Character
	-- A character that has been parented away is mid-respawn: its Humanoid still
	-- reports full health for a frame or two.
	if not character or not character.Parent then
		return false
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

function Validators.getRootPart(player: any): BasePart?
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return nil
	end

	local character = player.Character
	if not character then
		return nil
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

--[[
	Where the server believes the player's eyes are. Derived from the root part
	rather than the Head so a client that deletes or detaches its own Head cannot
	move the reference point used to bound shot origins.
]]
function Validators.getHeadPosition(player: any): Vector3?
	local root = Validators.getRootPart(player)
	if not root then
		return nil
	end
	return root.Position + Vector3.new(0, Constants.HEAD_OFFSET_Y, 0)
end

return Validators
