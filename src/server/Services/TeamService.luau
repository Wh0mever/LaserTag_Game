--!nonstrict
--[[
	TeamService.luau
	Creates the three Team objects and owns every team assignment.

	Team names are display strings ("Alpha", "Bravo"); the stable identity is the
	TeamId attribute ("A", "B", "LOBBY") carried on both the Team and the Player.
	Everything downstream — friendly fire, spawn selection, HUD colours — keys off
	that id, so renaming a team for flavour can never change game behaviour.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Teams = game:GetService("Teams")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local TableUtil = require(Shared.Util.TableUtil)

local TeamService = {}
TeamService.Priority = 2

local TEAM_ID_ATTRIBUTE = "TeamId"
local LOBBY_ID = "LOBBY"
local PLAYABLE_IDS = Constants.TEAM_IDS

local teams: { [string]: Team } = {}
local rng = Random.new()

local function findExisting(teamId: string): Team?
	for _, child in Teams:GetChildren() do
		if child:IsA("Team") and child:GetAttribute(TEAM_ID_ATTRIBUTE) == teamId then
			return child
		end
	end
	return nil
end

local function createTeam(teamId: string): Team
	local definition = Constants.TEAMS[teamId]
	local team = findExisting(teamId) or Instance.new("Team")

	team.Name = definition.name
	team.TeamColor = BrickColor.new(definition.brickColor)
	-- Every assignment is explicit. Roblox's auto-assigner would drop joining
	-- players onto a playing team mid-match and fight the match roster.
	team.AutoAssignable = false
	team:SetAttribute(TEAM_ID_ATTRIBUTE, teamId)
	team.Parent = Teams

	return team
end

function TeamService.init()
	for _, teamId in PLAYABLE_IDS do
		teams[teamId] = createTeam(teamId)
	end
	teams[LOBBY_ID] = createTeam(LOBBY_ID)
end

function TeamService.getTeam(teamId: string): Team?
	if type(teamId) ~= "string" then
		return nil
	end
	return teams[string.upper(teamId)]
end

function TeamService.assignToTeam(player: Player, teamId: string)
	local team = TeamService.getTeam(teamId)
	if not team then
		warn(`[TeamService] Unknown team id "{tostring(teamId)}"`)
		return
	end

	player.Team = team
	player.Neutral = false
	player:SetAttribute(TEAM_ID_ATTRIBUTE, team:GetAttribute(TEAM_ID_ATTRIBUTE))
end

function TeamService.moveToLobby(player: Player)
	TeamService.assignToTeam(player, LOBBY_ID)
end

function TeamService.getTeamId(player: Player): string
	local attribute = player:GetAttribute(TEAM_ID_ATTRIBUTE)
	if type(attribute) == "string" and Constants.TEAMS[attribute] then
		return attribute
	end

	-- Fall back to the Team object for a player whose attribute has not been
	-- written yet (they joined before TeamService assigned them anything).
	local team = player.Team
	local fromTeam = team and team:GetAttribute(TEAM_ID_ATTRIBUTE)
	if type(fromTeam) == "string" and Constants.TEAMS[fromTeam] then
		return fromTeam
	end

	return LOBBY_ID
end

function TeamService.sameTeam(a: Player, b: Player): boolean
	if not a or not b then
		return false
	end
	return TeamService.getTeamId(a) == TeamService.getTeamId(b)
end

function TeamService.getPlayersOnTeam(teamId: string): { Player }
	local team = TeamService.getTeam(teamId)
	if not team then
		return {}
	end
	return team:GetPlayers()
end

--[[
	Split a roster across the two playing teams.

	Shuffled first, then dealt alternately: alternating alone would make a
	player's side a pure function of join order, which is both predictable and
	unfair to whoever queues with a friend. Alternating after the shuffle keeps
	the two sides within one player of each other for any roster size.

	Returns a {[Player] = teamId} map; it does not assign anyone, so the caller
	can inspect or adjust the split before committing it.
]]
function TeamService.balanceAssign(players: { Player }): { [Player]: string }
	local shuffled = TableUtil.shuffle(players, function(n: number): number
		return rng:NextInteger(1, n)
	end)

	local roster: { [Player]: string } = {}
	for index, player in ipairs(shuffled) do
		roster[player] = if index % 2 == 1 then PLAYABLE_IDS[1] else PLAYABLE_IDS[2]
	end

	return roster
end

--[[
	Which playing team is currently the smaller one in `roster`. Ties go to team
	A so a late joiner never bounces between sides on repeated calls.
]]
function TeamService.smallestTeamIn(roster: { [Player]: string }): string
	local counts: { [string]: number } = {}
	for _, teamId in PLAYABLE_IDS do
		counts[teamId] = 0
	end

	for _, teamId in roster do
		if counts[teamId] then
			counts[teamId] += 1
		end
	end

	local smallest = PLAYABLE_IDS[1]
	for _, teamId in PLAYABLE_IDS do
		if counts[teamId] < counts[smallest] then
			smallest = teamId
		end
	end

	return smallest
end

function TeamService.teamColor(teamId: string): Color3
	local key = if type(teamId) == "string" then string.upper(teamId) else LOBBY_ID
	local definition = Constants.TEAMS[key] or Constants.TEAMS[LOBBY_ID]
	local color = definition.color
	return Color3.fromRGB(color.r, color.g, color.b)
end

return TeamService
