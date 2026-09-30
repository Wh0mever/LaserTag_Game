--!nonstrict
--[[
	MovementBudget.luau
	The server's own idea of where a player is, held to a speed limit.

	The character belongs to its client: the client simulates the physics and the
	server accepts the result. So the position the server reads is only as honest
	as the client, and a shot fired "from" it is only as honest as that. A modified
	client can jump its character across the map and fire in the same frame, and
	the server, which resolves every shot from the character's position, would
	kill from wherever it was told to.

	This keeps a second position that follows the real one but is not allowed to
	outrun a player. Shots are resolved from that one. For an honest player the
	two are the same thing, every frame. For a client that teleports, the shadow
	walks after it at a legal speed and the shots come from where the player
	could actually have got to.

	It follows, it does not correct. Nothing here moves a character or refuses
	one: a false positive costs an honest player a slightly wrong shot origin for
	a moment, not a yank backwards across the map on a laggy phone.

	Movement is paid for out of an allowance that grows with time and can be
	banked up to a cap. The bank is what lets a stalled connection catch up: a
	phone that freezes for a second and then delivers all of it in one packet has
	moved about a second's worth, and that must fit.

	Pure — no Roblox API — so tests/MovementBudget.spec.luau requires it directly.
]]

local MovementBudget = {}

export type State = {
	x: number,
	y: number,
	z: number,
	-- When the state was last brought up to date.
	at: number,
	-- Allowance banked and not yet spent, in studs.
	credit: number,
}

--[[
	Start following at (x, y, z), with a full bank. A player who has just been
	placed is exactly as entitled to a stalled connection as one who has stood
	still for a while; this is also how the state is re-anchored after the server
	itself moves the character.
]]
function MovementBudget.new(x: number, y: number, z: number, now: number, capacity: number): State
	return { x = x, y = y, z = z, at = now, credit = capacity }
end

--[[
	What moving from the shadow to (x, y, z) costs, in studs.

	Falling is free. Gravity does that at any speed and nobody has to be paid for
	it; it is climbing (a jump, a ramp) and travelling along the ground that take
	effort. A downward teleport is therefore not caught by cost, but it puts the
	character under the map or onto a lower floor, neither of which a shot from
	there gains anything from that a fall would not.
]]
local function cost(state: State, x: number, y: number, z: number): number
	local dx, dy, dz = x - state.x, y - state.y, z - state.z
	return math.sqrt(dx * dx + dz * dz) + math.max(dy, 0)
end

--[[
	Bring the shadow up to (x, y, z) as it stands at `now`.

	`rate` is studs of movement earned per second; `capacity` the most that can
	be banked. The interval since the last update earns `rate * elapsed` on top of
	the bank, uncapped, so a long gap between updates never makes an honest run
	look impossible; only what is left over afterwards is capped.

	If the move costs no more than that, the shadow lands on the real position.
	If it costs more, the shadow goes as far along the way as the allowance
	reaches and the bank is empty.
]]
function MovementBudget.step(state: State, x: number, y: number, z: number, now: number, rate: number, capacity: number)
	local elapsed = math.max(now - state.at, 0)
	state.at = now

	local allowance = state.credit + rate * elapsed
	local needed = cost(state, x, y, z)

	-- A position that is not a real number (NaN, infinity) is not a position. It
	-- must not reach the shadow: one NaN would poison every step after it.
	if needed ~= needed or needed == math.huge then
		state.credit = math.min(allowance, capacity)
		return
	end

	if needed <= allowance then
		state.x, state.y, state.z = x, y, z
		state.credit = math.min(allowance - needed, capacity)
		return
	end

	local fraction = allowance / needed
	state.x += (x - state.x) * fraction
	state.y += (y - state.y) * fraction
	state.z += (z - state.z) * fraction
	state.credit = 0
end

return MovementBudget
