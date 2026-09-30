--!nonstrict
--[[
	PositionHistory.luau
	A short memory of where something was, so the server can ask "where was it
	a moment ago?".

	That question is the whole of lag compensation. A player fires at what their
	screen shows, and their screen shows other players as they were a round trip
	and a little interpolation ago. Testing the shot against where targets are
	NOW, when it finally arrives, misses everything that was moving: at running
	speed a tenth of a second is nearly two studs, more than a body's width.

	Pure — no Roblox API — so tests/PositionHistory.spec.luau requires it
	directly. Positions are plain numbers; the caller converts at the edge.

	A fixed ring: recording allocates nothing after the first lap, which matters
	because every tracked character is recorded on every Heartbeat.
]]

local PositionHistory = {}

export type History = {
	capacity: number,
	count: number,
	-- Slot of the newest sample, 1..capacity.
	head: number,
	times: { number },
	xs: { number },
	ys: { number },
	zs: { number },
}

function PositionHistory.new(capacity: number): History
	local size = math.max(math.floor(capacity), 2)
	local history = {
		capacity = size,
		count = 0,
		head = size,
		times = table.create(size, 0),
		xs = table.create(size, 0),
		ys = table.create(size, 0),
		zs = table.create(size, 0),
	}
	return history
end

function PositionHistory.clear(history: History)
	history.count = 0
	history.head = history.capacity
end

-- Slot of the sample `back` places behind the newest (0 is the newest).
local function slotBack(history: History, back: number): number
	return (history.head - 1 - back) % history.capacity + 1
end

--[[
	Add a sample. Times only move forward: a sample at or before the newest one
	replaces it rather than stacking a zero-length interval that interpolation
	would divide by.
]]
function PositionHistory.record(history: History, time: number, x: number, y: number, z: number)
	if history.count > 0 and time <= history.times[history.head] then
		local head = history.head
		history.times[head] = time
		history.xs[head], history.ys[head], history.zs[head] = x, y, z
		return
	end

	local slot = history.head % history.capacity + 1
	history.head = slot
	history.count = math.min(history.count + 1, history.capacity)
	history.times[slot] = time
	history.xs[slot], history.ys[slot], history.zs[slot] = x, y, z
end

--[[
	Where it was at `time`, linearly between the two samples either side. Asking
	for a time newer than the newest sample gives the newest, and older than the
	oldest gives the oldest: the memory has edges, and an answer at the edge is
	more useful to a caller than none. Returns nil only when nothing has been
	recorded.
]]
function PositionHistory.at(history: History, time: number): (number?, number?, number?)
	if history.count == 0 then
		return nil, nil, nil
	end

	local newest = history.head
	if time >= history.times[newest] then
		return history.xs[newest], history.ys[newest], history.zs[newest]
	end

	-- Walk back from the newest to the first sample at or before `time`. Rewinds
	-- are a fraction of a second, so this is a handful of steps, not the ring.
	local newerSlot = newest
	for back = 1, history.count - 1 do
		local olderSlot = slotBack(history, back)
		local olderTime = history.times[olderSlot]
		if olderTime <= time then
			local newerTime = history.times[newerSlot]
			local alpha = (time - olderTime) / (newerTime - olderTime)
			return history.xs[olderSlot] + (history.xs[newerSlot] - history.xs[olderSlot]) * alpha,
				history.ys[olderSlot] + (history.ys[newerSlot] - history.ys[olderSlot]) * alpha,
				history.zs[olderSlot] + (history.zs[newerSlot] - history.zs[olderSlot]) * alpha
		end
		newerSlot = olderSlot
	end

	-- Older than everything remembered.
	return history.xs[newerSlot], history.ys[newerSlot], history.zs[newerSlot]
end

--[[
	How far back to look for a shot, in seconds: what the shooter's own latency
	accounts for, plus the interpolation delay their client draws other players
	behind by, capped at `maximum`.

	The cap is what keeps this fair. Every second of rewind is a second in which
	a target that has already moved behind cover can still be hit, so it must
	never be a number the shooter can inflate: it is `maximum` for a bad
	connection and no more. A latency that is not a real, non-negative number
	(nil, NaN, negative) counts as none.
]]
function PositionHistory.rewindSeconds(latency: any, interpolation: number, maximum: number): number
	local measured = if type(latency) == "number" and latency >= 0 and latency < math.huge then latency else 0
	return math.min(measured + interpolation, maximum)
end

return PositionHistory
