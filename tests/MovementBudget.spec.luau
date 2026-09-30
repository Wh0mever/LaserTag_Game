--!nonstrict
local MovementBudget = require("../src/server/Combat/MovementBudget")

local RATE = 36 -- studs per second earned
local CAP = 36 -- studs that can be banked

local function stepTo(state, x, y, z, now)
	MovementBudget.step(state, x, y, z, now, RATE, CAP)
end

return function(t)
	-- An honest run: eighteen studs a second, sampled every frame for ten
	-- seconds. The shadow is the real position at every one of them.
	local run = MovementBudget.new(0, 3, 0, 0, CAP)
	local worst = 0
	for frame = 1, 600 do
		local time = frame / 60
		stepTo(run, 18 * time, 3, 0, time)
		worst = math.max(worst, math.abs(run.x - 18 * time))
	end
	t.equal(worst, 0, "a player running at walking speed is never held back")

	-- Running and jumping at once: the climb costs, and it still fits in the rate.
	local hop = MovementBudget.new(0, 3, 0, 0, CAP)
	local hopWorst = 0
	for frame = 1, 300 do
		local time = frame / 60
		-- A 6.4 stud jump every half second on top of the run.
		local phase = (time % 0.5) / 0.5
		local height = 3 + 6.4 * 4 * phase * (1 - phase)
		stepTo(hop, 18 * time, height, 0, time)
		hopWorst = math.max(hopWorst, math.abs(hop.y - height))
	end
	t.equal(hopWorst, 0, "and so is one who bunny-hops flat out")

	-- A connection that stalls for a second and delivers it all at once. The
	-- bank covers that.
	local stall = MovementBudget.new(0, 3, 0, 0, CAP)
	stepTo(stall, 0, 3, 0, 0.5)
	stepTo(stall, 0, 3, 0, 1.5)
	stepTo(stall, 18, 3, 0, 1.5 + 1 / 60)
	t.equal(stall.x, 18, "a second of running arriving in one packet is followed at once")

	-- A jump across the map.
	local jump = MovementBudget.new(0, 3, 0, 0, CAP)
	stepTo(jump, 0, 3, 0, 1)
	stepTo(jump, 150, 3, 0, 1 + 1 / 60)
	t.expect(jump.x < 40, `a 150 stud jump is not followed (shadow at {jump.x})`)
	t.expect(jump.x > 30, "but the shadow does go as far as the allowance reaches")
	t.equal(jump.credit, 0, "which empties the bank")

	-- The shadow then walks after it at the earned rate and gets there.
	local before = jump.x
	stepTo(jump, 150, 3, 0, 1 + 1 / 60 + 1)
	t.near(jump.x - before, RATE, 1e-9, "a second later it has moved exactly one second's allowance")
	for frame = 1, 600 do
		stepTo(jump, 150, 3, 0, 2 + frame / 60)
	end
	t.equal(jump.x, 150, "and in the end it arrives")

	-- Direction is preserved on the way.
	local diagonal = MovementBudget.new(0, 0, 0, 0, CAP)
	stepTo(diagonal, 300, 0, 400, 0)
	t.near(diagonal.x / diagonal.z, 300 / 400, 1e-9, "the shadow follows a straight line towards the real position")

	-- Falling is free.
	local fall = MovementBudget.new(0, 100, 0, 0, CAP)
	stepTo(fall, 0, 3, 0, 1 / 60)
	t.equal(fall.y, 3, "dropping a hundred studs in a frame costs nothing")
	-- Climbing is not.
	local climb = MovementBudget.new(0, 3, 0, 0, CAP)
	stepTo(climb, 0, 103, 0, 1 / 60)
	t.expect(climb.y < 50, "climbing a hundred studs in a frame is not followed")

	-- A time that goes backwards earns nothing and costs nothing.
	local backwards = MovementBudget.new(0, 3, 0, 10, CAP)
	stepTo(backwards, 5, 3, 0, 9)
	t.equal(backwards.x, 5, "a step at an earlier time than the last still fits in the bank")
	t.equal(backwards.at, 9, "and the clock follows")

	-- The bank never holds more than its cap after a step, however long the gap.
	local rested = MovementBudget.new(0, 3, 0, 0, CAP)
	stepTo(rested, 0, 3, 0, 1000)
	t.equal(rested.credit, CAP, "a long rest banks no more than the cap")

	-- A long gap between updates still lets an honest player have run.
	local gap = MovementBudget.new(0, 3, 0, 0, CAP)
	stepTo(gap, 500, 3, 0, 30)
	t.equal(gap.x, 500, "a five hundred stud run over thirty seconds between updates is followed in full")

	-- A position that is not a real number does not poison the shadow.
	local poisoned = MovementBudget.new(1, 2, 3, 0, CAP)
	stepTo(poisoned, 0 / 0, 2, 3, 1)
	t.equal(poisoned.x, 1, "a NaN position is ignored")
	stepTo(poisoned, math.huge, 2, 3, 2)
	t.equal(poisoned.x, 1, "and so is an infinite one")
	stepTo(poisoned, 2, 2, 3, 3)
	t.equal(poisoned.x, 2, "and the next real position is followed normally")
end
