--!nonstrict
--[[
	IdleTracker.spec.luau
	Deciding who has stopped playing, from position samples.

	Two cases carry the whole design, and both are ones a naive implementation
	gets exactly backwards:

	  * A RESPAWN is not movement. A player being farmed at their spawn is
	    teleported a hundred studs every few seconds, so counting a teleport as
	    activity would make the most obviously idle player in the match look like
	    the busiest one. Anything above `maxStep` re-baselines without touching
	    the clock.

	  * STANDING STILL is not idling, if they are shooting. The Arc Lance exists
	    to be played by holding a lane, so position sampling alone would remove a
	    player for using the weapon the way it was designed. `markActive` is what
	    firing calls.

	Everything is in the caller's units: positions are {x, y, z} and `now` is
	whatever clock the caller has, so nothing here needs Roblox.
]]

local GameConfig = require("../src/shared/Config/GameConfig")
local IdleTracker = require("../src/server/Match/IdleTracker")

local WARN = 10
local REMOVE = 20

local function newTracker()
	return IdleTracker.new({ warnAfter = WARN, removeAfter = REMOVE, moveEpsilon = 2, maxStep = 40 })
end

local function at(x: number): { x: number, y: number, z: number }
	return { x = x, y = 0, z = 0 }
end

--[[
	The action for `id` in a step result, or nil. Actions are returned as a list
	because several players can be due at once, so a test that wants one has to
	go looking for it.
]]
local function actionFor(actions, id: any): string?
	for _, entry in actions do
		if entry.id == id then
			return entry.action
		end
	end
	return nil
end

return function(t)
	-- Config ---------------------------------------------------------------

	t.equal(IdleTracker.DEFAULTS.warnAfter, GameConfig.IDLE_WARN_SECONDS, "DEFAULTS.warnAfter tracks GameConfig")
	t.equal(IdleTracker.DEFAULTS.removeAfter, GameConfig.IDLE_REMOVE_SECONDS, "DEFAULTS.removeAfter tracks GameConfig")
	t.expect(
		IdleTracker.DEFAULTS.warnAfter < IdleTracker.DEFAULTS.removeAfter,
		"the default warning arrives before the default removal"
	)

	-- A config that would remove somebody without ever warning them is rejected
	-- outright rather than honoured: being removed with no notice is the one
	-- outcome this whole module exists to avoid.
	local inverted = IdleTracker.new({ warnAfter = 90, removeAfter = 30 })
	t.expect(
		inverted.config.warnAfter < inverted.config.removeAfter,
		"an inverted config falls back rather than removing without warning"
	)

	local zeroed = IdleTracker.new({ warnAfter = 0, removeAfter = -5, moveEpsilon = 0 })
	t.equal(zeroed.config.warnAfter, IdleTracker.DEFAULTS.warnAfter, "a zero threshold falls back")
	t.equal(zeroed.config.removeAfter, IdleTracker.DEFAULTS.removeAfter, "a negative threshold falls back")
	t.equal(zeroed.config.moveEpsilon, IdleTracker.DEFAULTS.moveEpsilon, "a zero epsilon falls back")

	-- Standing still ---------------------------------------------------------

	local still = newTracker()
	IdleTracker.observe(still, "a", at(0), 0)
	IdleTracker.observe(still, "a", at(0), 5)
	t.equal(actionFor(IdleTracker.step(still, 5), "a"), nil, "five seconds still is not yet a warning")

	IdleTracker.observe(still, "a", at(0), WARN)
	t.equal(actionFor(IdleTracker.step(still, WARN), "a"), IdleTracker.Actions.Warn, "the warning arrives on time")

	-- Latched: the same idle stretch does not warn again every tick.
	IdleTracker.observe(still, "a", at(0), WARN + 1)
	t.equal(actionFor(IdleTracker.step(still, WARN + 1), "a"), nil, "a warned player is not warned again")

	IdleTracker.observe(still, "a", at(0), REMOVE)
	t.equal(actionFor(IdleTracker.step(still, REMOVE), "a"), IdleTracker.Actions.Remove, "removal arrives on time")

	-- Walking ---------------------------------------------------------------

	local walker = newTracker()
	IdleTracker.observe(walker, "b", at(0), 0)
	for second = 1, REMOVE + 10 do
		-- Five studs a sample: a walk, comfortably between the epsilon and the
		-- teleport threshold.
		IdleTracker.observe(walker, "b", at(second * 5), second)
		t.equal(actionFor(IdleTracker.step(walker, second), "b"), nil, `a walking player is left alone at {second}s`)
	end

	-- A sub-epsilon twitch is not movement: physics jitter must not reset the
	-- clock, or nobody is ever idle.
	local twitchy = newTracker()
	IdleTracker.observe(twitchy, "c", at(0), 0)
	IdleTracker.observe(twitchy, "c", at(0.4), REMOVE / 2)
	IdleTracker.observe(twitchy, "c", at(0.8), REMOVE)
	t.equal(actionFor(IdleTracker.step(twitchy, REMOVE), "c"), IdleTracker.Actions.Remove, "jitter is not movement")

	-- Respawns ---------------------------------------------------------------
	-- THE CASE THIS MODULE EXISTS FOR. A player farmed at their spawn is
	-- teleported repeatedly; counting that as activity would exempt exactly the
	-- player who most needs removing.

	local farmed = newTracker()
	IdleTracker.observe(farmed, "d", at(0), 0)
	for second = 1, REMOVE do
		-- Alternating between two points a hundred studs apart: death, respawn,
		-- death, respawn. Never a step a player could have walked.
		IdleTracker.observe(farmed, "d", at(if second % 2 == 0 then 0 else 100), second)
	end
	t.equal(
		actionFor(IdleTracker.step(farmed, REMOVE), "d"),
		IdleTracker.Actions.Remove,
		"repeated respawns do not count as playing"
	)

	-- A dead player has no character and so no position. That teaches nothing
	-- either way, and the clock keeps running.
	local dead = newTracker()
	IdleTracker.observe(dead, "e", at(0), 0)
	IdleTracker.observe(dead, "e", nil, REMOVE / 2)
	IdleTracker.observe(dead, "e", nil, REMOVE)
	t.equal(
		actionFor(IdleTracker.step(dead, REMOVE), "e"),
		IdleTracker.Actions.Remove,
		"a missing position is not activity"
	)

	-- Firing ------------------------------------------------------------------
	-- The marksman case: perfectly still, and playing.

	local marksman = newTracker()
	IdleTracker.observe(marksman, "f", at(0), 0)
	for second = 1, REMOVE * 2 do
		IdleTracker.observe(marksman, "f", at(0), second)
		-- A shot every few seconds, which is slower than the Lance can fire.
		if second % 5 == 0 then
			IdleTracker.markActive(marksman, "f", second)
		end
		t.equal(
			actionFor(IdleTracker.step(marksman, second), "f"),
			nil,
			`a player holding an angle and firing is left alone at {second}s`
		)
	end

	-- Coming back clears the latch, so a player who drifts off twice is warned
	-- twice rather than removed without notice the second time.
	local returner = newTracker()
	IdleTracker.observe(returner, "g", at(0), 0)
	IdleTracker.observe(returner, "g", at(0), WARN)
	t.equal(actionFor(IdleTracker.step(returner, WARN), "g"), IdleTracker.Actions.Warn, "warned the first time")

	IdleTracker.markActive(returner, "g", WARN + 1)
	t.equal(actionFor(IdleTracker.step(returner, WARN + 2), "g"), nil, "activity clears the warning")

	IdleTracker.observe(returner, "g", at(0), WARN + 1 + WARN)
	t.equal(
		actionFor(IdleTracker.step(returner, WARN + 1 + WARN), "g"),
		IdleTracker.Actions.Warn,
		"warned again on a second idle stretch"
	)

	-- Bookkeeping -------------------------------------------------------------

	local counted = newTracker()
	IdleTracker.observe(counted, "h", at(0), 0)
	t.equal(IdleTracker.idleSeconds(counted, "h", 7), 7, "idle time is measured from the last activity")
	t.equal(IdleTracker.idleSeconds(counted, "unknown", 7), 0, "an untracked id has no idle time")

	t.equal(IdleTracker.secondsUntilRemoval(counted, "h", 0), REMOVE, "a fresh player has the full grace")
	t.equal(IdleTracker.secondsUntilRemoval(counted, "h", REMOVE - 3), 3, "the countdown reports what is left")
	t.equal(IdleTracker.secondsUntilRemoval(counted, "h", REMOVE + 99), 0, "the countdown floors at zero")

	IdleTracker.forget(counted, "h")
	t.equal(actionFor(IdleTracker.step(counted, REMOVE * 10), "h"), nil, "a forgotten player produces no actions")

	-- reset() starts a player fresh: entering a match must not inherit an idle
	-- clock from wherever they were standing beforehand.
	local rejoined = newTracker()
	IdleTracker.observe(rejoined, "i", at(0), 0)
	IdleTracker.observe(rejoined, "i", at(0), REMOVE - 1)
	IdleTracker.reset(rejoined, "i", REMOVE - 1)
	t.equal(actionFor(IdleTracker.step(rejoined, REMOVE - 1), "i"), nil, "a reset player starts clean")
	t.equal(IdleTracker.idleSeconds(rejoined, "i", REMOVE - 1), 0, "a reset clears the accrued idle time")

	-- Several players at once, which is the shape the runtime actually calls in.
	local many = newTracker()
	for _, id in { "x", "y", "z" } do
		IdleTracker.observe(many, id, at(0), 0)
	end
	IdleTracker.markActive(many, "y", REMOVE - 1)
	IdleTracker.observe(many, "x", at(0), REMOVE)
	IdleTracker.observe(many, "y", at(0), REMOVE)
	IdleTracker.observe(many, "z", at(0), REMOVE)

	local actions = IdleTracker.step(many, REMOVE)
	t.equal(actionFor(actions, "x"), IdleTracker.Actions.Remove, "x is removed")
	t.equal(actionFor(actions, "z"), IdleTracker.Actions.Remove, "z is removed")
	t.equal(actionFor(actions, "y"), nil, "y, who acted, is untouched")

	-- Garbage in ---------------------------------------------------------------
	-- The runtime feeds this from a live match; a bad sample must not take the
	-- match down, and must never remove somebody.

	local hostile = newTracker()
	IdleTracker.observe(hostile, "j", at(0), 0)
	IdleTracker.observe(hostile, "j", { x = 0 / 0, y = 0, z = 0 }, 1)
	IdleTracker.observe(hostile, "j", { x = math.huge, y = 0, z = 0 }, 2)
	IdleTracker.observe(hostile, "j", "over there", 3)
	IdleTracker.observe(hostile, "j", 42, 4)
	IdleTracker.observe(hostile, nil, at(0), 5)
	IdleTracker.observe(hostile, "j", at(0), 0 / 0)
	IdleTracker.markActive(hostile, "j", 0 / 0)
	t.equal(actionFor(IdleTracker.step(hostile, 5), "j"), nil, "malformed samples neither remove nor error")
	t.equal(#IdleTracker.step(hostile, 0 / 0), 0, "a NaN clock produces no actions")

	t.equal(IdleTracker.idleSeconds(hostile, "j", 0 / 0), 0, "a NaN clock reports no idle time")
end
