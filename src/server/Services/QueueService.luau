--!nonstrict
--[[
	QueueService.luau
	Joining a match means standing on a portal pad in the hub. There is
	deliberately no queue remote: a client cannot fake where its character is
	standing on the server, so the pad sample below is unspoofable in a way that
	any "I want to queue" message never could be.

	Priority 5 — it feeds MatchService, which is the same priority; the ordering
	between the two does not matter because this service does nothing until its
	start() loop begins.

	The pads are sampled rather than touched. Touched/TouchEnded on a walk-on pad
	misses a player who spawns already standing on it, double-fires while they
	shuffle, and never fires at all if they die on the pad — a poll has none of
	those failure modes and costs one box query per pad per QUEUE_POLL_INTERVAL.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Constants = require(Shared.Constants)
local GameConfig = require(Shared.Config.GameConfig)
local MatchService = require(script.Parent.MatchService)
local MatchStateMachine = require(script.Parent.Parent.Match.MatchStateMachine)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local WorldService = require(script.Parent.WorldService)

local QueueService = {}
QueueService.Priority = 5

-- Sampled volume above a pad: tall enough to catch a jumping player, short
-- enough that somebody on a walkway overhead is not counted as queued.
local SAMPLE_HEIGHT = 9

local WORLD_WAIT_TIMEOUT = 60
local WORLD_POLL_INTERVAL = 0.25

local overlapParams: OverlapParams? = nil
local pads: { { [string]: any } } = {}
local queues: { [string]: { Player } } = {}
local signState: { [string]: string } = {}
local lastPayload: { [string]: { count: number, countdown: number? } } = {}

--------------------------------------------------------------------------------
-- Sampling
--------------------------------------------------------------------------------

--[[
	Only live HumanoidRootParts are ever handed to the overlap query. Filtering to
	one part per character keeps every result unambiguous (part.Parent is the
	character) and keeps the query cheap no matter how many accessories the
	server is carrying.
]]
local function livingRoots(): { BasePart }
	local roots = {}

	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
			table.insert(roots, root)
		end
	end

	return roots
end

--[[
	A player may queue only from the hub. Anyone already in a match is playing on
	a pad-free map, and anyone whose profile has not loaded cannot be paid for the
	match they would join.
]]
local function canQueue(player: Player): boolean
	if player:GetAttribute("Loaded") ~= true then
		return false
	end
	local mapId = player:GetAttribute("InMatch")
	return type(mapId) ~= "string" or mapId == ""
end

local function sample(pad, claimed: { [Player]: boolean }, list: { Player })
	local part = pad.padPart
	if not part or not part.Parent then
		return
	end

	local size = part.Size
	local cframe = part.CFrame * CFrame.new(0, size.Y * 0.5 + SAMPLE_HEIGHT * 0.5, 0)

	for _, hit in workspace:GetPartBoundsInBox(cframe, Vector3.new(size.X, SAMPLE_HEIGHT, size.Z), overlapParams) do
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		-- `claimed` enforces one map per player: whichever pad is sampled first
		-- wins, so a player can never be counted into two queues at once.
		if player and not claimed[player] and canQueue(player) then
			claimed[player] = true
			table.insert(list, player)
		end
	end
end

--------------------------------------------------------------------------------
-- Publishing
--------------------------------------------------------------------------------

local States = MatchStateMachine.States

local function statusText(phase: string, count: number, needed: number, countdown: number?): string
	if phase == States.Countdown and countdown then
		return `STARTING IN {countdown}`
	elseif phase == States.InProgress then
		return "MATCH IN PROGRESS"
	elseif phase == States.Results then
		return "MATCH ENDING"
	elseif count > 0 then
		return `{count} / {needed} QUEUED`
	end
	return "STAND ON THE PAD TO QUEUE"
end

--[[
	MapBuilder builds each portal sign as SurfaceGui > Root > Status; that shape
	is the contract between the two files, so a sign missing it is skipped rather
	than rebuilt here.
]]
local function updateSigns(mapId: string, text: string)
	if signState[mapId] == text then
		return
	end
	signState[mapId] = text

	for _, pad in pads do
		if pad.mapId == mapId and pad.gui then
			local root = pad.gui:FindFirstChild("Root")
			local status = root and root:FindFirstChild("Status")
			if status and status:IsA("TextLabel") then
				status.Text = text
			end
		end
	end
end

--[[
	QueueUpdate goes to the players in the queue and to whoever just stepped off
	it — a leaver still needs one last message or their HUD keeps showing a queue
	they are no longer in.
]]
local function publish(mapId: string, current: { Player }, previous: { Player }, membersChanged: boolean)
	local phase = MatchService.getPhase(mapId)
	local countdown = MatchService.getCountdown(mapId)
	local count = #current
	local needed = GameConfig.MIN_PLAYERS

	updateSigns(mapId, statusText(phase, count, needed, countdown))

	-- Two reasons to send: the numbers on the HUD moved, or somebody stepped off
	-- the pad and is owed a final update even though the numbers did not.
	local last = lastPayload[mapId]
	local payloadChanged = last == nil or last.count ~= count or last.countdown ~= countdown
	if not payloadChanged and not membersChanged then
		return
	end
	lastPayload[mapId] = { count = count, countdown = countdown }

	local notified: { [Player]: boolean } = {}
	for _, player in current do
		notified[player] = true
		Remotes.fireClient(RemoteNames.QueueUpdate, player, mapId, count, needed, countdown)
	end

	for _, player in previous do
		if not notified[player] and player:IsDescendantOf(Players) then
			Remotes.fireClient(RemoteNames.QueueUpdate, player, mapId, count, needed, countdown)
		end
	end
end

local function sameMembers(a: { Player }, b: { Player }): boolean
	if #a ~= #b then
		return false
	end
	for _, player in a do
		if not table.find(b, player) then
			return false
		end
	end
	return true
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	One sampling pass over every pad. Exposed so a test place or an operator
	command can force a refresh; the start() loop is the only regular caller.
]]
function QueueService.poll()
	if not overlapParams then
		return
	end
	overlapParams.FilterDescendantsInstances = livingRoots()

	local claimed: { [Player]: boolean } = {}
	local current: { [string]: { Player } } = {}
	for _, mapId in Constants.MAPS do
		current[mapId] = {}
	end

	for _, pad in pads do
		local list = current[pad.mapId]
		if list then
			sample(pad, claimed, list)
		end
	end

	for _, mapId in Constants.MAPS do
		local previous = queues[mapId] or {}
		local list = current[mapId]
		local membersChanged = not sameMembers(previous, list)
		queues[mapId] = list

		-- Sent every poll rather than only when membership moves. MatchRuntime
		-- drops the list while it is holding on Results or while its roster is
		-- full, and nothing else would ever replay it: players standing still on
		-- the pad would then wait forever. Both consumers treat an unchanged
		-- list as a no-op, so re-sending cannot restart a countdown or seat a
		-- joiner twice.
		MatchService.onQueueChanged(mapId, list)

		-- Published after the diff so the sign and the HUD show the phase the
		-- queue change has already produced rather than the one before it.
		publish(mapId, list, previous, membersChanged)
	end
end

function QueueService.getQueue(mapId: string): { Player }
	return table.clone(queues[mapId] or {})
end

function QueueService.init()
	local params = OverlapParams.new()
	-- An include filter over the character roots is what makes this cheap: the
	-- query never has to consider the thousand-odd static parts of the hub.
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = {}
	params.RespectCanCollide = false
	overlapParams = params

	for _, mapId in Constants.MAPS do
		queues[mapId] = {}
	end
end

function QueueService.start()
	local deadline = os.clock() + WORLD_WAIT_TIMEOUT
	while not WorldService.isBuilt() and os.clock() < deadline do
		task.wait(WORLD_POLL_INTERVAL)
	end

	pads = WorldService.getPortalPads()
	if #pads == 0 then
		warn("[QueueService] no portal pads were built; nobody can queue for a match")
		return
	end

	while true do
		local ok, err = pcall(QueueService.poll)
		if not ok then
			warn(`[QueueService] poll failed: {err}`)
		end
		task.wait(GameConfig.QUEUE_POLL_INTERVAL)
	end
end

return QueueService
