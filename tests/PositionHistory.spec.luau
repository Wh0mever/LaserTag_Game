--!nonstrict
local PositionHistory = require("../src/server/Combat/PositionHistory")

-- Samples every 1/60 s along a straight line at 18 studs/s, x = 18 * t.
local function line(count: number, capacity: number?)
	local history = PositionHistory.new(capacity or 120)
	for index = 0, count - 1 do
		local time = index / 60
		PositionHistory.record(history, time, 18 * time, 3, -2 * time)
	end
	return history
end

return function(t)
	-- Nothing recorded, nothing to say.
	local empty = PositionHistory.new(10)
	local x = PositionHistory.at(empty, 5)
	t.equal(x, nil, "an empty history has no position")

	-- Exactly on a sample.
	local history = line(61)
	local ax, ay, az = PositionHistory.at(history, 0.5)
	t.near(ax, 9, 1e-9, "at a sample time the position is the sample's (x)")
	t.near(ay, 3, 1e-9, "at a sample time the position is the sample's (y)")
	t.near(az, -1, 1e-9, "at a sample time the position is the sample's (z)")

	-- Between two samples it is interpolated, on every axis.
	local bx, _, bz = PositionHistory.at(history, 0.5 + 1 / 120)
	t.near(bx, 18 * (0.5 + 1 / 120), 1e-9, "half way between two samples the position is half way (x)")
	t.near(bz, -2 * (0.5 + 1 / 120), 1e-9, "half way between two samples the position is half way (z)")

	-- The ends of the memory answer with the end, not with nothing.
	local newest = PositionHistory.at(history, 100)
	t.near(newest, 18, 1e-9, "later than the newest sample gives the newest")
	local oldest = PositionHistory.at(history, -100)
	t.near(oldest, 0, 1e-9, "earlier than the oldest sample gives the oldest")

	-- A ring: the oldest samples are overwritten, and what is left still lines up.
	local ring = line(300, 60)
	local now = 299 / 60
	local recent = PositionHistory.at(ring, now - 0.25)
	t.near(recent, 18 * (now - 0.25), 1e-9, "after wrapping, a recent time is still interpolated correctly")
	local tooOld = PositionHistory.at(ring, 0)
	t.near(tooOld, 18 * (now - 59 / 60), 1e-9, "and a time older than the ring gives the oldest sample it still holds")

	-- A sample that is not newer replaces the newest rather than stacking a
	-- zero-length interval that interpolation would divide by.
	local dup = PositionHistory.new(10)
	PositionHistory.record(dup, 1, 0, 0, 0)
	PositionHistory.record(dup, 2, 10, 0, 0)
	PositionHistory.record(dup, 2, 12, 0, 0)
	PositionHistory.record(dup, 1.5, 99, 0, 0)
	local dupX = PositionHistory.at(dup, 2)
	t.near(dupX, 99, 1e-9, "a sample no newer than the newest overwrites it")
	local midX = PositionHistory.at(dup, 1.5)
	t.expect(midX == midX and midX ~= math.huge, "and interpolation never divides by a zero interval")

	-- Clearing forgets everything, and recording works again afterwards.
	PositionHistory.clear(history)
	t.equal(PositionHistory.at(history, 0.5), nil, "a cleared history is empty")
	PositionHistory.record(history, 10, 1, 2, 3)
	local cx, cy, cz = PositionHistory.at(history, 10)
	t.equal(cx + cy + cz, 6, "and starts again from the next sample")

	-- How far back to look.
	t.near(PositionHistory.rewindSeconds(0.05, 0.1, 0.3), 0.15, 1e-9, "latency plus interpolation")
	t.near(PositionHistory.rewindSeconds(0, 0.1, 0.3), 0.1, 1e-9, "interpolation alone with no latency")
	t.near(PositionHistory.rewindSeconds(0.5, 0.1, 0.3), 0.3, 1e-9, "capped at the maximum")
	t.near(PositionHistory.rewindSeconds(1e9, 0.1, 0.3), 0.3, 1e-9, "an absurd latency is capped too")
	t.near(PositionHistory.rewindSeconds(nil, 0.1, 0.3), 0.1, 1e-9, "no latency reading counts as none")
	t.near(PositionHistory.rewindSeconds(-1, 0.1, 0.3), 0.1, 1e-9, "a negative latency counts as none")
	t.near(PositionHistory.rewindSeconds(0 / 0, 0.1, 0.3), 0.1, 1e-9, "NaN counts as none")
	t.near(
		PositionHistory.rewindSeconds(math.huge, 0.1, 0.3),
		0.1,
		1e-9,
		"infinity counts as none, not as a licence to look back"
	)
end
