--!nonstrict
--[[
	ScoreboardScreen.luau
	The hold-Tab roster: both teams side by side with each player's kills.

	It asks the server for nothing. Team membership and kill counts already
	replicate as player attributes (TeamId, SessionKills, InMatch), and the team
	totals ride on the match state the HUD is already receiving, so the whole
	screen is built from data every client has.

	Rows are pooled and only rebuilt while the board is actually open — holding
	Tab is a burst, not a steady load, and a player who never presses it pays
	nothing beyond one hidden frame.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local ScoreboardScreen = {}
ScoreboardScreen.Priority = 40

local ROW_HEIGHT = 30
local ROW_SPACING = 4
local HEADER_HEIGHT = 46
local COLUMN_WIDTH = 0.48
local REFRESH_INTERVAL = 0.5

local trove = Trove.new()
local root: Frame? = nil
local columns: { [string]: { list: Frame, header: TextLabel, rows: { any } } } = {}
local isOpen = false
local refreshHandle: thread? = nil

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
	holder.Size = UDim2.new(COLUMN_WIDTH, 0, 1, -HEADER_HEIGHT - 16)
	holder.Position = if alignRight
		then UDim2.new(1 - COLUMN_WIDTH, -12, 0, HEADER_HEIGHT + 8)
		else UDim2.fromOffset(12, HEADER_HEIGHT + 8)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local header = UITheme.label(team.name:upper(), UITheme.TextSizes.Subtitle, color, UITheme.Fonts.Heading)
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

	local list = Instance.new("Frame")
	list.Name = "Rows"
	list.Size = UDim2.new(1, 0, 1, -38)
	list.Position = UDim2.fromOffset(0, 38)
	list.BackgroundTransparency = 1
	list.Parent = holder

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_SPACING)
	layout.Parent = list

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
	panel.Size = UDim2.fromScale(0.62, 0.6)
	panel.BackgroundColor3 = UITheme.Colors.Panel
	panel.BackgroundTransparency = 0.08
	panel.BorderSizePixel = 0
	panel.Visible = false
	panel.Parent = gui
	UITheme.corner(UITheme.Radius.Large).Parent = panel
	UITheme.stroke(UITheme.Colors.Stroke, 1).Parent = panel

	local sizeConstraint = Instance.new("UISizeConstraint")
	sizeConstraint.MinSize = Vector2.new(320, 240)
	sizeConstraint.MaxSize = Vector2.new(860, 620)
	sizeConstraint.Parent = panel

	local title = UITheme.label(
		"ТАБЛИЦА СЧЁТА",
		UITheme.TextSizes.Heading,
		UITheme.Colors.Text,
		UITheme.Fonts.Heading
	)
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
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

local function refresh()
	if not isOpen or not root then
		return
	end

	local mapId = ClientState.getMapId()
	local rosters: { [string]: { { name: string, kills: number } } } = { A = {}, B = {} }

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
				kills = tonumber(player:GetAttribute("SessionKills")) or 0,
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

		column.header.Text = `{Constants.TEAMS[teamId].name:upper()}  —  {scores[teamId] or 0}`

		for index, entry in bucket do
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
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

local function setOpen(open: boolean)
	if open == isOpen or not root then
		return
	end

	isOpen = open
	root.Visible = open

	if open then
		refresh()
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

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ScoreboardScreen.init()
	if not build() then
		return
	end

	trove:Add(InputController.ScoreboardHeld:Connect(setOpen))

	-- A menu taking the screen closes the board; otherwise it would sit on top
	-- of the shop with a stale roster.
	trove:Add(UIController.MenuVisibilityChanged:Connect(function(_name: string, visible: boolean)
		if visible then
			setOpen(false)
		end
	end))
end

function ScoreboardScreen.stop()
	setOpen(false)
	trove:Clean()
end

return ScoreboardScreen
