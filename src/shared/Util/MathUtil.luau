--!nonstrict
--[[
	MathUtil.luau
	Numeric helpers, including the spread-cone maths used by the server when it
	re-simulates a shot. Vectors are plain {x, y, z} tables so the module stays
	Roblox-free and testable; callers convert at the edge.
]]

local MathUtil = {}

function MathUtil.clamp(value: number, minimum: number, maximum: number): number
	if value < minimum then
		return minimum
	elseif value > maximum then
		return maximum
	end
	return value
end

function MathUtil.lerp(a: number, b: number, alpha: number): number
	return a + (b - a) * alpha
end

function MathUtil.round(value: number): number
	return math.floor(value + 0.5)
end

--[[
	True when the value is a usable finite number. Rejects NaN (which is the
	only value not equal to itself) and both infinities — both are classic
	remote-payload attacks.
]]
function MathUtil.isFinite(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Vector helpers on {x, y, z} tables --------------------------------------

function MathUtil.magnitude(v: { x: number, y: number, z: number }): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function MathUtil.normalize(v: { x: number, y: number, z: number })
	local length = MathUtil.magnitude(v)
	if length == 0 then
		return { x = 0, y = 0, z = 0 }
	end
	return { x = v.x / length, y = v.y / length, z = v.z / length }
end

function MathUtil.cross(a: { x: number, y: number, z: number }, b: { x: number, y: number, z: number })
	return {
		x = a.y * b.z - a.z * b.y,
		y = a.z * b.x - a.x * b.z,
		z = a.x * b.y - a.y * b.x,
	}
end

function MathUtil.dot(a: { x: number, y: number, z: number }, b: { x: number, y: number, z: number }): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function MathUtil.distance(a: { x: number, y: number, z: number }, b: { x: number, y: number, z: number }): number
	return MathUtil.magnitude({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
end

--[[
	Rotate `direction` by a random offset inside a cone of `spreadDegrees`.

	`rng` must be a function returning a float in [0, 1). Injecting it keeps the
	function deterministic under test and lets the server use its own RNG.

	Builds an orthonormal basis around the direction, picks a uniformly random
	angle around the axis and a random magnitude within the cone.
]]
function MathUtil.applySpread(
	direction: { x: number, y: number, z: number },
	spreadDegrees: number,
	rng: () -> number
): { x: number, y: number, z: number }
	if spreadDegrees <= 0 then
		return MathUtil.normalize(direction)
	end

	local forward = MathUtil.normalize(direction)

	-- Pick any axis that is not parallel to forward to seed the basis.
	local reference = if math.abs(forward.y) > 0.99 then { x = 1, y = 0, z = 0 } else { x = 0, y = 1, z = 0 }

	local right = MathUtil.normalize(MathUtil.cross(forward, reference))
	local up = MathUtil.normalize(MathUtil.cross(right, forward))

	local angle = rng() * 2 * math.pi
	-- sqrt keeps the distribution uniform across the cone's area instead of
	-- clustering shots in the middle.
	local radius = math.tan(math.rad(spreadDegrees)) * math.sqrt(rng())

	local offsetX = math.cos(angle) * radius
	local offsetY = math.sin(angle) * radius

	return MathUtil.normalize({
		x = forward.x + right.x * offsetX + up.x * offsetY,
		y = forward.y + right.y * offsetX + up.y * offsetY,
		z = forward.z + right.z * offsetX + up.z * offsetY,
	})
end

--[[
	Deterministic linear congruential generator. Used where a reproducible
	sequence matters (tests, replayable spin results).
]]
function MathUtil.createRng(seed: number): () -> number
	local state = math.floor(seed) % 2147483647
	if state <= 0 then
		state += 2147483646
	end

	return function(): number
		state = (state * 16807) % 2147483647
		return (state - 1) / 2147483646
	end
end

return MathUtil
