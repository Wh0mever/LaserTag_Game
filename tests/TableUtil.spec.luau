--!nonstrict
local TableUtil = require("../src/shared/Util/TableUtil")

return function(t)
	-- deepClone must fully detach nested tables.
	local source = { a = 1, nested = { b = 2, deep = { c = 3 } }, list = { 1, 2, 3 } }
	local clone = TableUtil.deepClone(source)

	t.equal(clone.a, 1, "deepClone copies scalars")
	t.equal(clone.nested.deep.c, 3, "deepClone copies nested values")

	clone.nested.deep.c = 99
	clone.list[1] = 99
	t.equal(source.nested.deep.c, 3, "mutating a clone does not touch the source")
	t.equal(source.list[1], 1, "mutating a cloned array does not touch the source")

	-- reconcile fills gaps without clobbering existing data.
	local template = {
		Coins = 100,
		Stats = { Kills = 0, Deaths = 0, Wins = 0 },
		Spin = { Pity = 0 },
	}
	local saved = { Coins = 7500, Stats = { Kills = 42 } }
	TableUtil.reconcile(saved, template)

	t.equal(saved.Coins, 7500, "reconcile keeps an existing value")
	t.equal(saved.Stats.Kills, 42, "reconcile keeps an existing nested value")
	t.equal(saved.Stats.Deaths, 0, "reconcile fills a missing nested field")
	t.equal(saved.Spin.Pity, 0, "reconcile fills a missing nested table")

	-- The filled-in sub-table must be a clone, not a shared reference.
	saved.Spin.Pity = 5
	t.equal(template.Spin.Pity, 0, "reconcile clones template sub-tables")

	-- deepEquals
	t.expect(TableUtil.deepEquals({ a = { b = 1 } }, { a = { b = 1 } }), "deepEquals matches identical shapes")
	t.expect(not TableUtil.deepEquals({ a = 1 }, { a = 1, b = 2 }), "deepEquals rejects extra keys")
	t.expect(not TableUtil.deepEquals({ a = 1 }, { a = 2 }), "deepEquals rejects differing values")

	-- count / keys
	t.equal(TableUtil.count({ x = 1, y = 2, z = 3 }), 3, "count counts dictionary entries")
	t.equal(#TableUtil.keys({ x = 1, y = 2 }), 2, "keys returns every key")

	-- shuffle is a permutation and is deterministic for a fixed randomFn.
	local list = { 1, 2, 3, 4, 5 }
	local shuffled = TableUtil.shuffle(list, function(n)
		return n -- identity: picks the last element every time, i.e. no swaps
	end)
	t.equal(#shuffled, 5, "shuffle preserves length")
	t.deepEqual(shuffled, list, "shuffle with identity picks is a no-op")
	t.equal(list[1], 1, "shuffle does not mutate the input")

	local reversedPick = TableUtil.shuffle(list, function(_)
		return 1 -- always swap with the first element
	end)
	t.equal(#reversedPick, 5, "shuffle with constant picks still returns every element")

	local seen = {}
	for _, value in reversedPick do
		seen[value] = true
	end
	t.equal(TableUtil.count(seen), 5, "shuffle keeps every element exactly once")

	-- find
	t.equal(
		TableUtil.find({ 1, 5, 9 }, function(v)
			return v > 4
		end),
		5,
		"find returns the first match"
	)
	t.equal(
		TableUtil.find({ 1, 2 }, function(v)
			return v > 100
		end),
		nil,
		"find returns nil when nothing matches"
	)
end
