--!nonstrict
local SideAssignment = require("../src/server/Match/SideAssignment")

local TEAMS = { "A", "B" }

return function(t)
	local function verdict(counts, from, to)
		local allowed, reason = SideAssignment.evaluate(counts, from, to, TEAMS)
		return allowed, reason
	end

	-- The move the feature exists for -------------------------------------
	--
	-- A lopsided match is exactly when someone should be able to cross over,
	-- and it is the case a naive "sides must stay equal" rule would refuse.
	local allowed, reason = verdict({ A = 5, B = 2 }, "A", "B")
	t.expect(allowed, "a player may leave the bigger side to even a lopsided match")
	t.equal(reason, SideAssignment.OK, "and the reason says so")

	-- 4v3 -> 3v4 stays one apart, so it is allowed in both directions.
	t.expect(select(1, verdict({ A = 4, B = 3 }, "A", "B")), "the odd player out may switch")
	t.expect(select(1, verdict({ A = 3, B = 4 }, "B", "A")), "and back again")

	-- What it exists to refuse ---------------------------------------------
	allowed, reason = verdict({ A = 3, B = 3 }, "B", "A")
	t.expect(not allowed, "an even match cannot be broken by walking across")
	t.equal(reason, SideAssignment.WOULD_UNBALANCE, "and the reason names the balance")

	allowed, reason = verdict({ A = 4, B = 2 }, "B", "A")
	t.expect(not allowed, "nobody may pile onto the side that is already winning the headcount")
	t.equal(reason, SideAssignment.WOULD_UNBALANCE, "again for balance")

	-- A 1v1 is even, so neither player may defect and leave a 2v0.
	t.expect(not select(1, verdict({ A = 1, B = 1 }, "A", "B")), "a duel cannot become a walkover")

	-- Degenerate rosters ---------------------------------------------------
	--
	-- The last player on an emptied side may cross: 1v0 -> 0v1 is still one
	-- apart, and refusing it would strand them alone in a match with no
	-- opponent, which is worse than an empty side nobody is on.
	t.expect(select(1, verdict({ A = 1, B = 0 }, "A", "B")), "the last player on a side may leave it")

	-- Bad input ------------------------------------------------------------
	allowed, reason = verdict({ A = 2, B = 2 }, "A", "A")
	t.expect(not allowed, "asking for the side you are already on is refused")
	t.equal(reason, SideAssignment.ALREADY_THERE, "with its own reason, not a balance error")

	allowed, reason = verdict({ A = 2, B = 2 }, "A", "LOBBY")
	t.expect(not allowed, "the lobby is not a side you can pick")
	t.equal(reason, SideAssignment.UNKNOWN_TEAM, "and it is reported as an unknown team")

	for _, bad in { nil, "", 7, {}, true, "a" } do
		t.expect(
			not select(1, verdict({ A = 2, B = 2 }, "A", bad)),
			`a request for {typeof(bad)} "{tostring(bad)}" is refused`
		)
	end

	allowed, reason = verdict({ A = 2, B = 2 }, nil, "A")
	t.expect(not allowed, "a player who is not in the match cannot pick a side in it")
	t.equal(reason, SideAssignment.NOT_PLAYING, "and is told that rather than a balance reason")

	t.expect(not select(1, verdict({ A = 2, B = 2 }, "LOBBY", "A")), "sitting in the lobby is not being on a side")

	-- countTeams ------------------------------------------------------------
	local counts = SideAssignment.countTeams({ p1 = "A", p2 = "A", p3 = "B" }, TEAMS)
	t.equal(counts.A, 2, "countTeams counts the first side")
	t.equal(counts.B, 1, "countTeams counts the second side")

	-- Zero rather than nil, so callers never guard it.
	counts = SideAssignment.countTeams({}, TEAMS)
	t.equal(counts.A, 0, "an empty roster reports zero rather than nil for A")
	t.equal(counts.B, 0, "an empty roster reports zero rather than nil for B")

	-- A roster carrying a team nobody plays must not corrupt the counts.
	counts = SideAssignment.countTeams({ p1 = "A", p2 = "LOBBY" }, TEAMS)
	t.equal(counts.A, 1, "a lobby entry is not counted as a side")
	t.equal(counts.B, 0, "and does not leak into the other side")

	-- The two together: the verdict must be computed from the roster the match
	-- actually has, which is the join these two functions exist to make safe.
	local roster = { p1 = "A", p2 = "A", p3 = "A", p4 = "B" }
	allowed = SideAssignment.evaluate(SideAssignment.countTeams(roster, TEAMS), "A", "B", TEAMS)
	t.expect(allowed, "3v1 lets a player cross to make it 2v2")
end
