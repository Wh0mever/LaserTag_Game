--!nonstrict
--[[
	LeaderboardService.luau
	Global "Top Kills" board, backed by an OrderedDataStore.

	Cycle: write every online player's lifetime kills, pause for the write to
	propagate, read the sorted page back, render it onto the hub board.

	OrderedDataStore stores integers only and is eventually consistent — a read
	issued right after a write can still serve the previous value, hence the
	deliberate pause between the two halves of a cycle. Every DataStore call is
	pcall'd with bounded retries: a failing board must not take a match with it.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local DataService = require(script.Parent.DataService)
local GameConfig = require(Shared.Config.GameConfig)

local LeaderboardService = {}
LeaderboardService.Priority = 7

local BOARD_ID = "TopKills"

-- The board is read from across a hub, so only the head of the fetched page is
-- worth drawing; resolving 100 usernames per cycle would also burn the
-- GetNameFromUserIdAsync budget for nothing.
local DISPLAY_ROWS = 10
-- Ten rows plus the list layout's padding have to fit the board's content frame.
local ROW_HEIGHT_SCALE = 0.085

local PROPAGATION_DELAY = 5
local RETRY_ATTEMPTS = 3
local RETRY_BACKOFF = 2
-- After a failed read: soon enough that a hiccup does not freeze the board for
-- a whole update interval, far enough apart not to hammer a store that is down.
local READ_RETRY_DELAY = 30
local WORLD_RETRY_DELAY = 5
local WORLD_WAIT_TIMEOUT = 60
-- BindToClose gives the whole server ~30s; leave room for profile releases.
local SHUTDOWN_BUDGET = 20

local TEXT_COLOR = Color3.fromRGB(238, 240, 248)
local DIM_TEXT_COLOR = Color3.fromRGB(168, 172, 186)
local ROW_COLOR = Color3.fromRGB(24, 26, 36)

-- Column layout inside one row, as fractions of the row width.
local COLUMNS = {
	rank = { name = "Rank", x = 0, width = 0.16, align = Enum.TextXAlignment.Left },
	name = { name = "PlayerName", x = 0.18, width = 0.52, align = Enum.TextXAlignment.Left },
	kills = { name = "Kills", x = 0.72, width = 0.26, align = Enum.TextXAlignment.Right },
}

local store = nil
local worldService = nil
local nameCache: { [number]: string } = {}
-- The highest score each player's entry is known to hold. Kills only ever grow,
-- so anything at or below this needs no request: a write per player per cycle
-- for scores that did not move would spend the DataStore budget (60 + 10 per
-- player each minute) on nothing, and the leave-time write below would double
-- the periodic one.
local written: { [number]: number } = {}

local function retry(attempts: number, action: () -> any): (boolean, any)
	local lastError = nil

	for attempt = 1, attempts do
		local ok, result = pcall(action)
		if ok then
			return true, result
		end

		lastError = result
		if attempt < attempts then
			-- Linear backoff: DataStore throttling clears on a seconds scale, and
			-- retrying instantly just spends another request against the budget.
			task.wait(RETRY_BACKOFF * attempt)
		end
	end

	return false, lastError
end

local function writeScore(userId: number, kills: number, attempts: number): boolean
	if not store then
		return false
	end

	local score = math.floor(kills)
	-- OrderedDataStore holds integers only, and a zero-kill entry would just pad
	-- the bottom of a board nobody scrolls.
	if score <= 0 then
		return true
	end

	if (written[userId] or 0) >= score then
		return true
	end

	local ok, err = retry(attempts, function()
		-- Checked again on every attempt: a retry backing off for seconds can
		-- find a newer write (the leave-time one) already stored, and must not
		-- put a lower score over it.
		if (written[userId] or 0) >= score then
			return
		end
		store:SetAsync(tostring(userId), score)
	end)

	if not ok then
		warn(`[LeaderboardService] Failed to write score for {userId}: {tostring(err)}`)
		return false
	end

	written[userId] = math.max(written[userId] or 0, score)
	return true
end

--[[
	A player's profile is being released, whether they left, the server is
	closing or their data was taken. Their kills since the last periodic write
	would otherwise wait for a cycle they are no longer here for.

	DataService fires this on its own thread, so the retries' backoff never holds
	up the leave path.
]]
local function onProfileReleasing(player: Player, kills: number)
	local userId = player.UserId
	-- The high-water mark stays after the leave-time write. Clearing it would
	-- blind the re-check inside writeScore's retry: an older write still backing
	-- off would wake to find nothing recorded and put its lower score over this
	-- one. Kills only grow, so a returning player is never held back by it, and
	-- the table costs one number per player who visited.
	writeScore(userId, kills, RETRY_ATTEMPTS)
end

-- Connected here, not in start(): start() runs the board loop and may yield,
-- and a player leaving before it got round to connecting would be missed.
function LeaderboardService.init()
	store = DataStoreService:GetOrderedDataStore(GameConfig.LEADERBOARD_STORE_NAME)
	DataService.ProfileReleasingSignal:Connect(onProfileReleasing)
end

function LeaderboardService.flush(player: Player)
	local data = DataService.getData(player)
	if not data then
		return
	end
	writeScore(player.UserId, data.Stats.Kills or 0, RETRY_ATTEMPTS)
end

-- Write every online player's score. Called from BindToClose, so the writes run
-- as parallel jobs with a single attempt each and the whole thing gives up at
-- SHUTDOWN_BUDGET rather than eating the shutdown budget profiles also need.
function LeaderboardService.flushAll()
	local pending = 0

	for _, player in Players:GetPlayers() do
		local data = DataService.getData(player)
		if data then
			pending += 1
			task.spawn(function()
				writeScore(player.UserId, data.Stats.Kills or 0, 1)
				pending -= 1
			end)
		end
	end

	local deadline = os.clock() + SHUTDOWN_BUDGET
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

--[[
	The head of the board, or nil when it could not be read. An empty list means
	the store answered and nobody has a score; nil means it did not answer, and
	the caller must not present the second as the first.
]]
local function fetchTop(count: number): { { rank: number, userId: number, kills: number } }?
	if not store then
		return nil
	end

	-- Reading the page is inside the retried call as well: a malformed answer
	-- must cost this cycle a retry, not kill the loop that runs the board.
	local ok, entries = retry(RETRY_ATTEMPTS, function()
		local pages = store:GetSortedAsync(false, count)
		local rows = {}
		for rank, entry in pages:GetCurrentPage() do
			table.insert(rows, {
				rank = rank,
				userId = tonumber(entry.key) or 0,
				kills = entry.value,
			})
		end
		return rows
	end)

	if not ok then
		warn(`[LeaderboardService] Failed to read the sorted board: {tostring(entries)}`)
		return nil
	end

	return entries
end

local function resolveName(userId: number): string
	local cached = nameCache[userId]
	if cached then
		return cached
	end

	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)

	-- Only a success is cached: a throttled lookup must be retried next cycle
	-- rather than pinning a placeholder onto the board forever.
	if ok and type(name) == "string" then
		nameCache[userId] = name
		return name
	end

	return `User {userId}`
end

--[[
	WorldService builds the board as SurfaceGui > Root > Content, where Content is
	a Frame carrying a LayoutOrder-sorted UIListLayout. That structure is the
	contract between the two services; adding a second layout of our own here
	would fight it, so a board without it is reported and left alone.
]]
local function rowContainer(gui: SurfaceGui): Instance?
	local root = gui:FindFirstChild("Root")
	local content = root and root:FindFirstChild("Content")
	if not content then
		warn(`[LeaderboardService] Board "{BOARD_ID}" has no Root.Content frame to render into`)
		return nil
	end
	return content
end

local function ensureLabel(row: Instance, column): TextLabel
	local label = row:FindFirstChild(column.name)
	if not label then
		label = Instance.new("TextLabel")
		label.Name = column.name
		label.BackgroundTransparency = 1
		label.Position = UDim2.new(column.x, 0, 0, 0)
		label.Size = UDim2.new(column.width, 0, 1, 0)
		label.Font = Enum.Font.GothamMedium
		label.TextScaled = true
		label.TextXAlignment = column.align
		label.Parent = row
	end
	return label
end

local function ensureRow(parent: Instance, rank: number): Instance
	local name = `Row{rank}`
	local row = parent:FindFirstChild(name)

	if not row then
		row = Instance.new("Frame")
		row.Name = name
		row.BackgroundColor3 = ROW_COLOR
		row.BackgroundTransparency = 0.45
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, ROW_HEIGHT_SCALE, 0)
		row.Parent = parent
	end

	row.LayoutOrder = rank
	row.Visible = true
	return row
end

local function fillRow(parent: Instance, rank: number, rankText: string, name: string, kills: string, color: Color3)
	local row = ensureRow(parent, rank)
	local texts = { rank = rankText, name = name, kills = kills }

	for key, column in COLUMNS do
		local label = ensureLabel(row, column)
		label.Text = texts[key]
		label.TextColor3 = color
	end
end

-- Rows are reused, never rebuilt: destroying and re-creating ten frames every
-- cycle makes the board blink for anyone standing in front of it.
local function render(gui: SurfaceGui, entries)
	local parent = rowContainer(gui)
	if not parent then
		return
	end

	local shown = math.min(#entries, DISPLAY_ROWS)

	for rank = 1, shown do
		local entry = entries[rank]
		fillRow(parent, rank, `#{rank}`, resolveName(entry.userId), tostring(entry.kills), TEXT_COLOR)
	end

	if shown == 0 then
		fillRow(parent, 1, "", "Пока нет результатов", "", DIM_TEXT_COLOR)
	end

	for rank = math.max(shown, 1) + 1, DISPLAY_ROWS do
		local row = parent:FindFirstChild(`Row{rank}`)
		if row then
			row.Visible = false
		end
	end
end

-- WorldService is loaded by the same Loader pass as this module and builds the
-- hub asynchronously, so it is required lazily and every failure is treated as
-- "not ready yet" rather than fatal.
local function getWorldService()
	if worldService then
		return worldService
	end

	local module = script.Parent:FindFirstChild("WorldService")
	if not module or not module:IsA("ModuleScript") then
		return nil
	end

	local ok, result = pcall(require, module)
	if not ok then
		warn(`[LeaderboardService] WorldService is not requirable yet: {tostring(result)}`)
		return nil
	end

	worldService = result
	return worldService
end

local function getBoard(): SurfaceGui?
	local service = getWorldService()
	if not service or type(service.getBoard) ~= "function" then
		return nil
	end

	local ok, board = pcall(service.getBoard, BOARD_ID)
	if ok and typeof(board) == "Instance" and board:IsA("SurfaceGui") then
		return board
	end
	return nil
end

function LeaderboardService.start()
	-- The board only exists once WorldService has built the hub; wait for it
	-- rather than skipping the first render, then keep re-checking every cycle.
	local deadline = os.clock() + WORLD_WAIT_TIMEOUT
	while os.clock() < deadline and getBoard() == nil do
		task.wait(WORLD_RETRY_DELAY)
	end

	local lastGood = nil

	while true do
		for _, player in Players:GetPlayers() do
			task.spawn(LeaderboardService.flush, player)
		end

		task.wait(PROPAGATION_DELAY)

		local entries = fetchTop(GameConfig.LEADERBOARD_SIZE)
		if entries then
			lastGood = entries
		end

		-- A failed read leaves the last good rows up (drawn again, in case the
		-- board was rebuilt): the store being down says nothing about the scores,
		-- and "no results" would tell everyone in the hub that they were wiped.
		local board = getBoard()
		if board and lastGood then
			render(board, lastGood)
		end

		task.wait(if entries then GameConfig.LEADERBOARD_UPDATE_INTERVAL else READ_RETRY_DELAY)
	end
end

return LeaderboardService
