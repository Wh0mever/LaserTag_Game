--!nonstrict
--[[
	ScoreboardScreen.luau
	The hold-Tab roster: both teams side by side with each player's kills in
	THIS match. On a touchscreen, tapping the score at the top of the screen
	opens it — Tab was the only way in, so a phone player never saw it.

	It asks the server for nothing. Team membership and kill counts already
	replicate as player attributes (TeamId, SessionKills, InMatch), and the team
	totals ride on the match state the HUD is already receiving, so the whole
	screen is built from data every client has.

	Rows are pooled and only rebuilt while the board is actually open — holding
	Tab is a burst, not a steady load, and a player who never presses it pays
	nothing beyond one hidden frame.

	EACH TEAM'S ROWS SCROLL. A full lobby is up to eight a side, and on a phone
	the board has room for four: the rest used to be drawn below it, over the
	HUD and off the bottom of the screen, and the players at the bottom of a list
	are the ones who most want to find themselves. So the rows sit in a
	ScrollingFrame, and opening the board scrolls the local player's team to
	their row when it is not on the first page.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local TextUtil = require(Shared.Util.TextUtil)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local ScoreboardScreen = {}
ScoreboardScreen.Priority = 40

local ROW_HEIGHT = 30
local ROW_SPACING = 4
local HEADER_HEIGHT = 46
local COLUMN_GUTTER = 12
-- Below the team's name and its underline, inside a column.
local COLUMN_HEADER = 38
-- What the board keeps for itself above and below the rows, so the rows'
-- window is the board's height less this.
local ROWS_CHROME = HEADER_HEIGHT + 16 + COLUMN_HEADER
local BOARD_HEIGHT_SCALE = 0.6
local BOARD_MIN_HEIGHT = 240
local BOARD_MAX_HEIGHT = 620
-- How long a tap-opened board stays up on a touchscreen. There is no key to
-- let go of, so it closes itself (or on a second tap).
local TOUCH_OPEN_SECONDS = 5
local REFRESH_INTERVAL = 0.5

local trove = Trove.new()
local root: Frame? = nil
local columns: { [string]: { list: Frame, header: TextLabel, rows: { any } } } = {}
local isOpen = false
local refreshHandle: thread? = nil
-- Opened by a tap, and so closing itself: see holdTouchOpen.
local tapOpened = false
local touchOpenToken = 0
-- Where the local player is listed, and until when a layout change should
-- scroll to them again (see scrollToLocalRow).
local localRow: { teamId: string, index: number }? = nil
local settleUntil = 0
-- Defined further down; the columns are built before they can be written.
local scrollToLocalRow: () -> ()
local holdTouchOpen: () -> ()

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildRow(parent: Frame)
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundColor3 = UITheme.Colors.PanelLight
	row.BackgroundTransparency = 0.3
	row.BorderSizePixel = 0
	row.Visible = false
	row.Parent = parent
	UITheme.corner(UITheme.Radius.Small).Parent = row

	local name = UITheme.label("", UITheme.TextSizes.Body, UITheme.Colors.Text)
	name.Name = "PlayerName"
	name.Size = UDim2.new(1, -60, 1, 0)
	name.Position = UDim2.fromOffset(10, 0)
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.TextTruncate = Enum.TextTruncate.AtEnd
	name.Parent = row

	local kills = UITheme.label("0", UITheme.TextSizes.Body, UITheme.Colors.Text, UITheme.Fonts.Number)
	kills.Name = "Kills"
	kills.Size = UDim2.new(0, 44, 1, 0)
	kills.Position = UDim2.new(1, -52, 0, 0)
	kills.TextXAlignment = Enum.TextXAlignment.Right
	kills.Parent = row

	return { root = row, name = name, kills = kills }
end

local function buildColumn(parent: Frame, teamId: string, alignRight: boolean)
	local color = UITheme.teamColor(teamId)
	local team = Constants.TEAMS[teamId]

	local holder = Instance.new("Frame")
	holder.Name = teamId
	-- Half the board each, less a fixed gutter, so the two columns never touch
	-- however narrow the board gets. As fractions they overlapped below 600 px.
	holder.Size = UDim2.new(0.5, -COLUMN_GUTTER * 1.5, 1, -HEADER_HEIGHT - 16)
	holder.Position = if alignRight
		then UDim2.new(0.5, COLUMN_GUTTER / 2, 0, HEADER_HEIGHT + 8)
		else UDim2.fromOffset(COLUMN_GUTTER, HEADER_HEIGHT + 8)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local header = UITheme.label(TextUtil.upper(team.name), UITheme.TextSizes.Subtitle, color, UITheme.Fonts.Heading)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 26)
	header.TextXAlignment = Enum.TextXAlignment.Left
	header.Parent = holder

	local underline = Instance.new("Frame")
	underline.Name = "Underline"
	underline.Size = UDim2.new(1, 0, 0, 2)
	underline.Position = UDim2.fromOffset(0, 28)
	underline.BackgroundColor3 = color
	underline.BorderSizePixel = 0
	underline.Parent = holder

	local list = Instance.new("ScrollingFrame")
	list.Name = "Rows"
	list.Size = UDim2.new(1, 0, 1, -COLUMN_HEADER)
	list.Position = UDim2.fromOffset(0, COLUMN_HEADER)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 3
	list.ScrollBarImageColor3 = UITheme.Colors.Stroke
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.Parent = holder

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_SPACING)
	layout.Parent = list

	-- The canvas grows a layout pass after the rows do, so a scroll asked for
	-- at the moment of opening is clamped against the old, shorter canvas. It
	-- is asked again as the content settles.
	trove:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
		if os.clock() < settleUntil then
			scrollToLocalRow()
		end
	end)
	-- Reading the roster is not a reason to close a board that is being read.
	trove:Connect(list:GetPropertyChangedSignal("CanvasPosition"), function()
		holdTouchOpen()
	end)

	columns[teamId] = { list = list, header = header, rows = {} }
end

local function build(): boolean
	local gui = UIController.getScreenGui("Scoreboard", Constants.DISPLAY_ORDER.Results - 1)
	if not gui then
		warn("[ScoreboardScreen] no ScreenGui — the board will not be shown")
		return false
	end

	local panel = Instance.new("Frame")
	panel.Name = "Board"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.45)
	panel.Size = UDim2.fromScale(0.62, BOARD_HEIGHT_SCALE)
	panel.BackgroundColor3 = UITheme.Colors.Panel
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Visible = false
	panel.Parent = gui
	UITheme.corner(UITheme.Radius.Large).Parent = panel
	UITheme.stroke(UITheme.Colors.Stroke, 1).Parent = panel

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(320, BOARD_MIN_HEIGHT)
	sizeConstraint.MaxSize = Vector2.new(860, BOARD_MAX_HEIGHT)
	sizeConstraint.Parent = panel

	local title = UITheme.label(
		"ТАБЛИЦА СЧЁТА",
		UITheme.TextSizes.Heading,
		UITheme.Colors.Text,
		UITheme.Fonts.Heading
	)
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.Parent = panel

	root = panel
	buildColumn(panel, "A", false)
	buildColumn(panel, "B", true)

	trove:Add(panel)
	return true
end

--------------------------------------------------------------------------------
-- Population
--------------------------------------------------------------------------------

local function rowFor(teamId: string, index: number)
	local column = columns[teamId]
	local row = column.rows[index]
	if not row then
		row = buildRow(column.list)
		column.rows[index] = row
	end
	return row
end

--[[
	Puts the local player's team on their row when it is not on the first page.

	The window is the board's height less its chrome, worked out from the same
	numbers that size the board: Lune has no layout to ask, and the answer only
	has to be right about "is this row on the first page", since the engine clamps
	a scroll past the end. CanvasPosition is in real pixels, so the row's offset
	in canvas units is multiplied by the scale.
]]
function scrollToLocalRow()
	local target = localRow
	if not target then
		return
	end
	local column = columns[target.teamId]
	if not column then
		return
	end

	local canvas = UIController.getCanvasSize()
	local boardHeight = if canvas
		then math.clamp(canvas.Y * BOARD_HEIGHT_SCALE, BOARD_MIN_HEIGHT, BOARD_MAX_HEIGHT)
		else BOARD_MIN_HEIGHT
	local window = boardHeight - ROWS_CHROME

	local rowTop = (target.index - 1) * (ROW_HEIGHT + ROW_SPACING)
	local top = if rowTop + ROW_HEIGHT > window then rowTop else 0
	column.list.CanvasPosition = Vector2.new(0, top * UIController.scale)
end

local function refresh(scrollToMe: boolean?)
	if not isOpen or not root then
		return
	end

	local mapId = ClientState.getMapId()
	local rosters: { [string]: { { name: string, kills: number, isLocal: boolean } } } = { A = {}, B = {} }
	local localPlayer = Players.LocalPlayer
	localRow = nil

	for _, player in Players:GetPlayers() do
		-- Out of a match the board lists everyone in the hub; in a match it
		-- lists only that match's players, so the other arena stays invisible.
		local playerMap = player:GetAttribute("InMatch")
		if mapId ~= "" and playerMap ~= mapId then
			continue
		end

		local teamId = player:GetAttribute("TeamId")
		local bucket = rosters[teamId]
		if bucket then
			table.insert(bucket, {
				name = player.DisplayName,
				kills = tonumber(player:GetAttribute("MatchKills")) or 0,
				isLocal = player == localPlayer,
			})
		end
	end

	local scores = ClientState.match.scores or { A = 0, B = 0 }

	for _, teamId in Constants.TEAM_IDS do
		local column = columns[teamId]
		local bucket = rosters[teamId]

		table.sort(bucket, function(a, b)
			if a.kills == b.kills then
				return a.name < b.name
			end
			return a.kills > b.kills
		end)

		column.header.Text = `{TextUtil.upper(Constants.TEAMS[teamId].name)}  —  {scores[teamId] or 0}`

		for index, entry in bucket do
			if entry.isLocal then
				localRow = { teamId = teamId, index = index }
			end
			local row = rowFor(teamId, index)
			row.root.LayoutOrder = index
			row.root.Visible = true
			row.name.Text = entry.name
			row.kills.Text = tostring(entry.kills)
		end

		for index = #bucket + 1, #column.rows do
			column.rows[index].root.Visible = false
		end
	end

	if scrollToMe then
		scrollToLocalRow()
	end
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

-- How long after opening a change in the rows' size still scrolls to the
-- local player again: a layout pass or two, not a state the board stays in.
local SETTLE_SECONDS = 1

local function setOpen(open: boolean)
	-- Only during a match. In the hub it listed everyone playing on every other
	-- map, merged into two columns under this player's last final score.
	if open and not ClientState.isInMatch() then
		return
	end
	-- The board's ScreenGui outranks the menus, so it would be drawn ON the shop
	-- with a roster the shop knows nothing about. A menu is opened on purpose;
	-- the board can wait.
	if open and UIController.isAnyMenuOpen() then
		return
	end
	if open == isOpen or not root then
		return
	end

	isOpen = open
	root.Visible = open

	if not open then
		tapOpened = false
	end

	if open then
		settleUntil = os.clock() + SETTLE_SECONDS
		refresh(true)
		-- Attributes replicate on their own schedule, so the board re-reads
		-- while it is held rather than freezing on the values at key-down.
		refreshHandle = task.spawn(function()
			while isOpen do
				task.wait(REFRESH_INTERVAL)
				refresh()
			end
		end)
	elseif refreshHandle then
		task.cancel(refreshHandle)
		refreshHandle = nil
	end
end

--[[
	A tap-opened board closes itself TOUCH_OPEN_SECONDS after the last thing that
	happened to it: the tap, or the roster being scrolled. Each call restarts the
	clock; a board held open with Tab is not on a timer at all.
]]
function holdTouchOpen()
	if not tapOpened then
		return
	end

	touchOpenToken += 1
	local mine = touchOpenToken
	task.delay(TOUCH_OPEN_SECONDS, function()
		if isOpen and tapOpened and touchOpenToken == mine then
			setOpen(false)
		end
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ScoreboardScreen.init()
	if not build() then
		return
	end

	trove:Add(InputController.ScoreboardHeld:Connect(setOpen))

	local refreshTap: (() -> ())? = nil

	if ClientState.isTouch then
		-- An invisible tap target over the timer and the two score chips: the
		-- score is where a player looks to see how the match is going, so it
		-- is where they tap to see more of it.
		local gui = root and root.Parent
		local tap = Instance.new("TextButton")
		tap.Name = "ScoreTap"
		tap.AnchorPoint = Vector2.new(0.5, 0)
		tap.Position = UDim2.new(0.5, 0, 0, 6)
		tap.Size = UDim2.fromOffset(280, 92)
		tap.BackgroundTransparency = 1
		tap.Text = ""
		-- Over the menus it would swallow taps meant for a panel's title bar and
		-- open the board on top of it.
		local function refresh()
			tap.Visible = ClientState.isInMatch() and not UIController.isAnyMenuOpen()
		end
		refreshTap = refresh
		refresh()
		tap.Parent = gui
		trove:Add(tap)

		trove:Connect(tap.Activated, function()
			if isOpen then
				setOpen(false)
				return
			end
			setOpen(true)
			tapOpened = isOpen
			holdTouchOpen()
		end)

		trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
			if name == "InMatch" then
				refresh()
				if not ClientState.isInMatch() then
					setOpen(false)
				end
			end
		end))
	end

	-- A menu taking the screen closes the board; otherwise it would sit on top
	-- of the shop with a stale roster. setOpen refuses to open one over a menu,
	-- so this is the other half of the same rule.
	trove:Add(UIController.MenuVisibilityChanged:Connect(function(_name: string, visible: boolean)
		if visible then
			setOpen(false)
		end
		if refreshTap then
			refreshTap()
		end
	end))
end

function ScoreboardScreen.stop()
	setOpen(false)
	trove:Clean()
end

return ScoreboardScreen
