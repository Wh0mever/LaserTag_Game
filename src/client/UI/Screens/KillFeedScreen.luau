--!nonstrict
--[[
	KillFeedScreen.luau
	The rolling "Killer -> Victim" list in the top-right corner.

	Rows are pooled. A kill feed on a busy server churns several entries a
	second, and destroying/recreating a five-label frame that often is exactly
	the allocation pattern that shows up as a GC hitch mid-fight — so a row that
	expires is hidden and pushed back onto a free list instead.

	Expiry is driven by one Heartbeat that walks at most MAX_VISIBLE rows and
	writes transparencies. It never creates an Instance, and it early-returns to
	nothing while the feed is empty.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local KillFeedScreen = {}
KillFeedScreen.Priority = 21

-- More than this on screen and the oldest entries are unreadable anyway; the
-- feed drops the oldest rather than growing down over the score chips.
local MAX_VISIBLE = 5
local ROW_HEIGHT = 26
local ROW_SPACING = 4
local FADE_SECONDS = 0.5
local ARROW = "➔"
local HEADSHOT_MARK = "☠"

local trove = Trove.new()
local container: Frame? = nil
local pool: { any } = {}
local active: { any } = {}

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function buildRow()
	local root = Instance.new("Frame")
	root.Name = "Entry"
	root.Size = UDim2.new(0, 0, 0, ROW_HEIGHT)
	root.AutomaticSize = Enum.AutomaticSize.X
	root.BackgroundColor3 = UITheme.Colors.PanelDark
	root.BackgroundTransparency = 0.25
	root.BorderSizePixel = 0
	root.Visible = false
	UITheme.corner(UITheme.Radius.Small).Parent = root
	UITheme.padding(8, 0).Parent = root

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = root

	local function part(name: string, order: number, font: Enum.Font): TextLabel
		local label = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.Text, font)
		label.Name = name
		label.LayoutOrder = order
		label.AutomaticSize = Enum.AutomaticSize.X
		label.Size = UDim2.new(0, 0, 1, 0)
		label.TextTruncate = Enum.TextTruncate.None
		label.Parent = root
		return label
	end

	local row = {
		instance = root,
		killer = part("Killer", 1, UITheme.Fonts.Bold),
		arrow = part("Arrow", 2, UITheme.Fonts.Body),
		headshot = part("Headshot", 3, UITheme.Fonts.Bold),
		victim = part("Victim", 4, UITheme.Fonts.Bold),
		expiresAt = 0,
	}

	row.arrow.TextColor3 = UITheme.Colors.TextDim
	row.headshot.TextColor3 = UITheme.Colors.Warning
	row.headshot.Text = HEADSHOT_MARK
	return row
end

local function setRowFade(row, alpha: number)
	row.instance.BackgroundTransparency = 0.25 + alpha * 0.75
	row.killer.TextTransparency = alpha
	row.arrow.TextTransparency = alpha
	row.headshot.TextTransparency = alpha
	row.victim.TextTransparency = alpha
end

local function release(index: number)
	local row = table.remove(active, index)
	if not row then
		return
	end

	row.instance.Visible = false
	row.instance.Parent = nil
	table.insert(pool, row)
end

local function acquire()
	local row = table.remove(pool)
	if not row then
		row = buildRow()
	end
	return row
end

--------------------------------------------------------------------------------
-- Feed
--------------------------------------------------------------------------------

local function push(entry)
	if not container then
		return
	end

	-- Oldest first in `active`, so trimming from the front drops the stalest row.
	while #active >= MAX_VISIBLE do
		release(1)
	end

	local row = acquire()
	local killerName = entry.killerName
	row.killer.Text = killerName or "World"
	row.killer.TextColor3 = if killerName then UITheme.teamColor(entry.killerTeam) else UITheme.Colors.TextDim
	row.arrow.Text = ARROW
	row.headshot.Visible = entry.isHeadshot == true
	row.victim.Text = entry.victimName or "?"
	row.victim.TextColor3 = UITheme.teamColor(entry.victimTeam)
	row.expiresAt = os.clock() + Constants.KILL_FEED_DURATION

	setRowFade(row, 0)
	table.insert(active, row)

	-- Newest at the top: LayoutOrder counts down as the row ages.
	for index, item in active do
		item.instance.LayoutOrder = #active - index
	end

	row.instance.Visible = true
	row.instance.Parent = container
end

local function step()
	if #active == 0 then
		return
	end

	local now = os.clock()
	for index = #active, 1, -1 do
		local row = active[index]
		local remaining = row.expiresAt - now
		if remaining <= 0 then
			release(index)
		elseif remaining < FADE_SECONDS then
			setRowFade(row, 1 - remaining / FADE_SECONDS)
		end
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function KillFeedScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("KillFeed", Constants.DISPLAY_ORDER.KillFeed)
	if not gui then
		return
	end

	local holder = Instance.new("Frame")
	holder.Name = "Feed"
	holder.AnchorPoint = Vector2.new(1, 0)
	holder.Position = UDim2.new(1, -18, 0, 18)
	holder.Size = UDim2.new(0.32, 0, 0, MAX_VISIBLE * (ROW_HEIGHT + ROW_SPACING))
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	container = trove:Add(holder)

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, ROW_SPACING)
	layout.Parent = holder

	trove:Add(ClientState.KillFeed:Connect(push))
	trove:Connect(RunService.Heartbeat, step)
end

function KillFeedScreen.stop()
	trove:Clean()
	table.clear(active)
	table.clear(pool)
	container = nil
end

return KillFeedScreen
