--!nonstrict
local RateLimiterCore = require("../src/server/Net/RateLimiterCore")

return function(t)
	-- Time is injected, so every case below steps a virtual clock rather than
	-- sleeping; `now` values are seconds.

	-- Exactly maxRequests are accepted inside one window, and the next is not.
	local basic = { maxRequests = 3, windowSeconds = 5, cooldownSeconds = 0 }
	local state = RateLimiterCore.newState()

	for index = 1, 3 do
		local allowed, violation = RateLimiterCore.check(state, "Shoot", 0, basic)
		t.expect(allowed, `request #{index} inside the window is allowed`)
		t.expect(not violation, `request #{index} is not a violation`)
	end

	local allowed, violation = RateLimiterCore.check(state, "Shoot", 0, basic)
	t.expect(not allowed, "the request past maxRequests is rejected")
	t.expect(violation, "the rejected request is reported as a violation")
	t.equal(RateLimiterCore.violations(state, "Shoot"), 1, "violations counts the rejection")

	-- Once the whole window has passed the timestamps are pruned and the key is
	-- usable again.
	t.expect(RateLimiterCore.check(state, "Shoot", 5.1, basic), "a request after the window is allowed again")
	t.equal(RateLimiterCore.violations(state, "Shoot"), 1, "an allowed request does not add a violation")
	t.equal(RateLimiterCore.violations(state, "NeverUsed"), 0, "violations is 0 for a key that has never been seen")

	-- Pruning is partial: only the timestamps that actually expired are dropped.
	local sliding = RateLimiterCore.newState()
	local slidingConfig = { maxRequests = 2, windowSeconds = 10, cooldownSeconds = 0 }

	RateLimiterCore.check(sliding, "Reload", 0, slidingConfig)
	RateLimiterCore.check(sliding, "Reload", 9, slidingConfig)
	t.expect(
		not RateLimiterCore.check(sliding, "Reload", 9.5, slidingConfig),
		"the window is full while both timestamps are still inside it"
	)
	-- At t = 10.5 the t = 0 entry has expired but the t = 9 entry has not.
	t.expect(RateLimiterCore.check(sliding, "Reload", 10.5, slidingConfig), "only the expired timestamp is pruned")
	t.expect(
		not RateLimiterCore.check(sliding, "Reload", 10.6, slidingConfig),
		"the timestamp that survived pruning still counts against the window"
	)

	-- Violations accumulate per key.
	local strict = { maxRequests = 1, windowSeconds = 10, cooldownSeconds = 0 }
	local violations = RateLimiterCore.newState()

	RateLimiterCore.check(violations, "Buy", 0, strict)
	for expected = 1, 3 do
		local _, isViolation = RateLimiterCore.check(violations, "Buy", 0, strict)
		t.expect(isViolation, `rejection #{expected} is reported as a violation`)
		t.equal(RateLimiterCore.violations(violations, "Buy"), expected, `violation count reached {expected}`)
	end

	-- reset clears both the counter and the window.
	RateLimiterCore.reset(violations, "Buy")
	t.equal(RateLimiterCore.violations(violations, "Buy"), 0, "reset clears the violation count")
	t.expect(RateLimiterCore.check(violations, "Buy", 0, strict), "reset clears the window as well")

	-- A cooldown blocks past the point where the window alone would have cleared,
	-- and requests made during it are not counted as fresh violations.
	local cooling = RateLimiterCore.newState()
	local cooldownConfig = { maxRequests = 2, windowSeconds = 1, cooldownSeconds = 4 }

	RateLimiterCore.check(cooling, "Spin", 0, cooldownConfig)
	RateLimiterCore.check(cooling, "Spin", 0, cooldownConfig)

	local limitOk, limitViolation = RateLimiterCore.check(cooling, "Spin", 0, cooldownConfig)
	t.expect(not limitOk, "hitting the limit rejects the request")
	t.expect(limitViolation, "hitting the limit opens the cooldown")

	local duringOk, duringViolation = RateLimiterCore.check(cooling, "Spin", 2, cooldownConfig)
	t.expect(not duringOk, "the cooldown still blocks after the window itself has cleared")
	t.expect(not duringViolation, "a request during the cooldown is not a new violation")
	t.equal(RateLimiterCore.violations(cooling, "Spin"), 1, "the cooldown does not inflate the violation count")

	t.expect(
		RateLimiterCore.check(cooling, "Spin", 4.1, cooldownConfig),
		"requests are accepted again once the cooldown expires"
	)

	-- Keys are independent: exhausting one leaves the others untouched.
	local keys = RateLimiterCore.newState()
	for _ = 1, 3 do
		RateLimiterCore.check(keys, "A", 0, basic)
	end

	t.expect(not RateLimiterCore.check(keys, "A", 0, basic), "key A is exhausted")
	t.expect(RateLimiterCore.check(keys, "B", 0, basic), "key B is unaffected by key A")
	t.equal(RateLimiterCore.violations(keys, "B"), 0, "key B carries no violations from key A")

	-- States are independent too, which is what keeps one player's flood from
	-- rate limiting everyone else.
	local other = RateLimiterCore.newState()
	t.expect(RateLimiterCore.check(other, "A", 0, basic), "a fresh state starts with an empty window")
	t.equal(RateLimiterCore.violations(other, "A"), 0, "a fresh state starts with no violations")
end
