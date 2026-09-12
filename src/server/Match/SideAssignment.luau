--!nonstrict
--[[
	SideAssignment.luau
	Whether a player may move to the side they picked.

	Pure: it takes counts and team ids and returns a verdict. No Player objects,
	no Roblox API, so tests/SideAssignment.spec.luau can exercise every roster
	shape off Roblox — which matters, because the interesting cases here are
	arithmetic on team sizes and they are tedious to produce in a live match.

	THE RULE, AND WHY IT IS NOT "THE PLAYER DECIDES". Letting everyone pick the
	same side is not a feature, it is the end of the mode: a 7-versus-1 team
	deathmatch has no game in it, and the side that emptied cannot opt back into
	being fun. CS2 has exactly this rule and phrases it the same way — you may
	change sides while the sides stay even.

	So a move is allowed when the two teams end up no more than one player apart.
	That permits the move nobody can argue with (evening up a lopsided match, or
	swapping on an even-sized roster where someone goes the other way) and
	refuses the one that breaks the mode. It is deliberately NOT a preference
	that gets honoured later: the answer is yes or no at the moment of asking, so
	the player finds out immediately rather than being silently queued.

	The verdict carries a reason so the interface can say why, rather than
	leaving a dead button. A button that quietly does nothing is the failure this
	whole project keeps finding.
]]

local SideAssignment = {}

SideAssignment.OK = "ok"
SideAssignment.ALREADY_THERE = "alreadyThere"
SideAssignment.UNKNOWN_TEAM = "unknownTeam"
SideAssignment.NOT_PLAYING = "notPlaying"
SideAssignment.WOULD_UNBALANCE = "wouldUnbalance"

-- How far apart the two sides may end up. One, not zero: an odd roster can
-- never be even, and refusing every move on a 5-player match would make the
-- feature vanish exactly when a match is small enough for one player to matter.
local MAX_DIFFERENCE = 1

local function isPlayable(teamIds: { string }, teamId: any): boolean
	if type(teamId) ~= "string" then
		return false
	end
	for _, id in teamIds do
		if id == teamId then
			return true
		end
	end
	return false
end

--[[
	`counts` is {[teamId] = number} for the sides currently playing, `from` the
	team the player is on (nil or "" if they are not playing), `to` the team they
	asked for.

	Returns (allowed, reason). The reason is one of the constants above and is
	set even when allowed, so callers can log a single value.
]]
function SideAssignment.evaluate(
	counts: { [string]: number },
	from: any,
	to: any,
	teamIds: { string }
): (boolean, string)
	if not isPlayable(teamIds, to) then
		return false, SideAssignment.UNKNOWN_TEAM
	end
	if not isPlayable(teamIds, from) then
		return false, SideAssignment.NOT_PLAYING
	end
	if from == to then
		return false, SideAssignment.ALREADY_THERE
	end

	local after: { [string]: number } = {}
	for _, id in teamIds do
		after[id] = counts[id] or 0
	end

	-- The mover leaves one side and joins the other; both ends move, which is
	-- why a swap on an even roster stays even and a defection does not.
	after[from] -= 1
	after[to] += 1

	local smallest, largest = math.huge, -math.huge
	for _, id in teamIds do
		smallest = math.min(smallest, after[id])
		largest = math.max(largest, after[id])
	end

	if largest - smallest > MAX_DIFFERENCE then
		return false, SideAssignment.WOULD_UNBALANCE
	end

	return true, SideAssignment.OK
end

--[[
	Counts per team from a {[player] = teamId} roster. Teams with nobody on them
	are present as zero rather than missing, so callers never have to guard a nil.
]]
function SideAssignment.countTeams(roster: { [any]: string }, teamIds: { string }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, id in teamIds do
		counts[id] = 0
	end

	for _, teamId in roster do
		if counts[teamId] then
			counts[teamId] += 1
		end
	end

	return counts
end

return SideAssignment
