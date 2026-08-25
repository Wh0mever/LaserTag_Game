--!nonstrict
local MathUtil = require("../src/shared/Util/MathUtil")

return function(t)
	t.equal(MathUtil.clamp(5, 0, 3), 3, "clamp caps at the maximum")
	t.equal(MathUtil.clamp(-5, 0, 3), 0, "clamp raises to the minimum")
	t.equal(MathUtil.lerp(0, 10, 0.25), 2.5, "lerp interpolates")
	t.equal(MathUtil.round(2.5), 3, "round goes up at .5")
	t.equal(MathUtil.round(2.4), 2, "round goes down below .5")

	-- isFinite is the guard against NaN/inf remote payloads.
	t.expect(MathUtil.isFinite(1.5), "isFinite accepts a normal number")
	t.expect(not MathUtil.isFinite(0 / 0), "isFinite rejects NaN")
	t.expect(not MathUtil.isFinite(math.huge), "isFinite rejects +inf")
	t.expect(not MathUtil.isFinite(-math.huge), "isFinite rejects -inf")
	t.expect(not MathUtil.isFinite("3"), "isFinite rejects strings")
	t.expect(not MathUtil.isFinite(nil), "isFinite rejects nil")

	-- Vector maths
	t.equal(MathUtil.magnitude({ x = 3, y = 4, z = 0 }), 5, "magnitude is euclidean")

	local unit = MathUtil.normalize({ x = 0, y = 0, z = -7 })
	t.near(MathUtil.magnitude(unit), 1, 1e-6, "normalize produces a unit vector")
	t.equal(unit.z, -1, "normalize preserves direction")

	local zero = MathUtil.normalize({ x = 0, y = 0, z = 0 })
	t.equal(zero.x, 0, "normalizing a zero vector is safe")

	t.equal(MathUtil.dot({ x = 1, y = 0, z = 0 }, { x = 1, y = 0, z = 0 }), 1, "dot of equal unit vectors is 1")
	t.equal(MathUtil.dot({ x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 }), 0, "dot of perpendicular vectors is 0")

	local crossed = MathUtil.cross({ x = 1, y = 0, z = 0 }, { x = 0, y = 1, z = 0 })
	t.equal(crossed.z, 1, "cross of x and y is z")

	t.equal(MathUtil.distance({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 10 }), 10, "distance measures separation")

	-- Spread stays inside the requested cone and remains a unit vector.
	local forward = { x = 0, y = 0, z = -1 }
	local rng = MathUtil.createRng(12345)

	local zeroSpread = MathUtil.applySpread(forward, 0, rng)
	t.equal(zeroSpread.z, -1, "zero spread returns the original direction")

	local maxAngleSeen = 0
	for _ = 1, 200 do
		local spread = MathUtil.applySpread(forward, 2, rng)
		t.near(MathUtil.magnitude(spread), 1, 1e-6, "spread result stays normalized")

		local angle = math.deg(math.acos(MathUtil.clamp(MathUtil.dot(spread, forward), -1, 1)))
		if angle > maxAngleSeen then
			maxAngleSeen = angle
		end
	end
	t.expect(maxAngleSeen <= 2.0001, `spread never exceeds the cone (saw {maxAngleSeen})`)
	t.expect(maxAngleSeen > 0.5, "spread actually deviates from centre")

	-- Seeded RNG is reproducible and in range.
	local a = MathUtil.createRng(42)
	local b = MathUtil.createRng(42)
	for _ = 1, 10 do
		local va, vb = a(), b()
		t.equal(va, vb, "createRng is deterministic for a fixed seed")
		t.expect(va >= 0 and va < 1, "createRng stays in [0, 1)")
	end
end
