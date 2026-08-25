--!nonstrict
--[[
	EffectPool.luau
	Fixed-size instance pools, plus the single list of live effects that drives
	them.

	Two rules make this safe on the hot path:

	  * Pools never grow. When every beam is already on screen the next shot's
	    beam is DROPPED rather than allocated. A pool that grows under load never
	    shrinks again, and a frame already drawing eighteen beams gains nothing
	    from a nineteenth.
	  * One list, one loop. Every live effect — beam, impact, damage number,
	    damage indicator — is stepped from `EffectPool.step`, so the per-frame
	    cost is proportional to what is actually visible instead of to the pool
	    sizes.

	Helper module for VFXController: it has no init/start, so the Loader requires
	it and then leaves it alone.
]]

local EffectPool = {}

export type Live = {
	pool: string,
	item: any,
	startedAt: number,
	duration: number,
	step: (any, number) -> (),
	finish: (any) -> (),
}

local pools: { [string]: { any } } = {}
local live: { Live } = {}

--[[
	Build `size` items with `factory(index)` and register them under `name`.
	Rebuilding an existing pool replaces it; anything still live from the old one
	is discarded on release rather than returned to the new pool.
]]
function EffectPool.create(name: string, size: number, factory: (index: number) -> any)
	local free = table.create(size)
	for index = 1, size do
		free[index] = factory(index)
	end
	pools[name] = free
end

function EffectPool.exists(name: string): boolean
	return pools[name] ~= nil
end

--[[
	Take an item, or nil when the pool is empty or has not been built yet.
	Callers must handle nil by skipping the effect.
]]
function EffectPool.acquire(name: string): any
	local free = pools[name]
	return free and table.remove(free) or nil
end

--[[
	Hand an acquired item to the step loop for `duration` seconds. `step` is
	called with (item, alpha) each frame where alpha runs 0 -> 1; `finish` is
	called once at the end, before the item goes back to its pool.
]]
function EffectPool.play(name: string, item: any, duration: number, step: (any, number) -> (), finish: (any) -> ())
	table.insert(live, {
		pool = name,
		item = item,
		startedAt = os.clock(),
		duration = math.max(duration, 0.01),
		step = step,
		finish = finish,
	})
end

--[[
	Advance every live effect. Iterates backwards so a finished effect can be
	removed without disturbing the indices still to be visited.
]]
function EffectPool.step(now: number)
	for index = #live, 1, -1 do
		local entry = live[index]
		local alpha = (now - entry.startedAt) / entry.duration

		if alpha >= 1 then
			table.remove(live, index)
			entry.finish(entry.item)

			local free = pools[entry.pool]
			if free then
				table.insert(free, entry.item)
			end
		else
			entry.step(entry.item, alpha)
		end
	end
end

function EffectPool.liveCount(): number
	return #live
end

--[[
	Drop every pool and every live effect. The instances themselves belong to
	whoever built them; this only forgets about them.
]]
function EffectPool.clear()
	table.clear(live)
	table.clear(pools)
end

return EffectPool
