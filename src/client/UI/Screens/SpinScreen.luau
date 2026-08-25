--!nonstrict
--[[
	SpinScreen.luau
	The reward wheel panel: the wheel itself (SpinWheel), the published odds
	table, the pity counter and the free-spin timer.

	Two things in here are deliberate and must not be "simplified" away.

	1. The odds table is mandatory. A randomised reward that does not publish its
	   real chances is a dark pattern (and against Roblox policy). The
	   percentages are read straight from SpinConfig.Segments, so they cannot
	   drift from the numbers the server rolls against.

	2. The animation is a replay, not a draw. SpinRequest returns segmentIndex
	   and the wheel is tweened to land on exactly that wedge. Nothing on the
	   client may pick a segment — a client-side roll would be both wrong and
	   trivially forgeable.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local ListRow = require(script.Parent.Parent.Components.ListRow)
local MathUtil = require(Shared.Util.MathUtil)
local Panel = require(script.Parent.Parent.Components.Panel)
local RemoteNames = require(Shared.RemoteNames)
local SpinConfig = require(Shared.Config.SpinConfig)
local SpinWheel = require(script.Parent.SpinWheel)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local SpinScreen = {}
SpinScreen.Priority = 30

local ODDS_ROW_HEIGHT = 30
local SECONDS_PER_HOUR = 3600

local trove = Trove.new()
local panel: any = nil
local wheel: any = nil
local spinButton: any = nil
local costLabel: TextLabel? = nil
local rewardLabel: TextLabel? = nil
local pityFill: Frame? = nil
local pityLabel: TextLabel? = nil
local spinning = false
local lastClockText = ""

--------------------------------------------------------------------------------
-- Status lines
--------------------------------------------------------------------------------

local function setStatus(message: string, color: Color3)
	if rewardLabel then
		rewardLabel.Text = message
		rewardLabel.TextColor3 = color
	end
end

local function formatWait(seconds: number): string
	local whole = math.max(math.floor(seconds), 0)
	local hours = math.floor(whole / SECONDS_PER_HOUR)
	local minutes = math.floor(whole % SECONDS_PER_HOUR / 60)

	if hours > 0 then
		return `{hours}h {minutes}m`
	elseif minutes > 0 then
		return `{minutes}m {whole % 60}s`
	end
	return `{whole}s`
end

--[[
	At most one text write per second: called every Heartbeat while the panel is
	open, and short-circuited when the rendered string has not changed.
]]
local function refreshClock()
	if not costLabel or not panel or not panel:isOpen() then
		return
	end

	-- nextFreeAt is a server clock value, so it is compared against the server
	-- clock rather than os.time(); a client with a skewed clock still sees the
	-- same countdown as everyone else.
	local remaining = (ClientState.spin.nextFreeAt or 0) - workspace:GetServerTimeNow()
	local text = if remaining <= 0
		then "FREE SPIN READY"
		else `Free spin in {formatWait(remaining)}  ·  or {SpinConfig.EXTRA_SPIN_COST} coins now`

	if text ~= lastClockText then
		lastClockText = text
		costLabel.Text = text
		costLabel.TextColor3 = if remaining <= 0 then UITheme.Colors.Positive else UITheme.Colors.TextDim
	end
end

local function refreshPity()
	if not pityFill or not pityLabel then
		return
	end

	local pity = ClientState.spin.pity or 0
	local threshold = math.max(SpinConfig.PITY_THRESHOLD, 1)
	local remaining = math.max(threshold - pity, 0)

	pityFill.Size = UDim2.fromScale(MathUtil.clamp(pity / threshold, 0, 1), 1)
	pityLabel.Text = if remaining <= 0
		then "Next spin is a guaranteed skin"
		else `Guaranteed skin in {remaining} more spin{remaining == 1 and "" or "s"}`
end

--------------------------------------------------------------------------------
-- Spinning
--------------------------------------------------------------------------------

--[[
	Resolves the server's answer to a wedge. segmentIndex is authoritative;
	segmentId is only a fallback for a payload that lost the index.
]]
local function resolveIndex(result): number
	local index = result.segmentIndex
	if type(index) == "number" and SpinConfig.Segments[index] then
		return index
	end
	for position, segment in SpinConfig.Segments do
		if segment.id == result.segmentId then
			return position
		end
	end
	return 1
end

local function finish(result)
	spinning = false
	if spinButton then
		spinButton:setEnabled(true)
	end

	setStatus(result.rewardLabel and `WON: {result.rewardLabel}` or "WON!", UITheme.Colors.Positive)
	refreshPity()
	refreshClock()
end

local function spin()
	if spinning or not wheel then
		return
	end

	spinning = true
	if spinButton then
		spinButton:setEnabled(false)
	end
	setStatus("Spinning…", UITheme.Colors.TextDim)

	task.spawn(function()
		local remote = ClientState.getRemote(RemoteNames.SpinRequest)
		local result
		if remote then
			local ok, response = pcall(function()
				return (remote :: any):InvokeServer()
			end)
			result = ok and response or nil
		end

		if type(result) ~= "table" or not result.ok then
			spinning = false
			if spinButton then
				spinButton:setEnabled(true)
			end
			local reason = type(result) == "table" and result.err or "Spin failed — try again"
			setStatus(reason, UITheme.Colors.Negative)
			return
		end

		-- The server's numbers, adopted wholesale: the client computes no part of
		-- the reward, the timer or the pity counter.
		if type(result.nextFreeAt) == "number" then
			ClientState.spin.nextFreeAt = result.nextFreeAt
		end
		if type(result.pity) == "number" then
			ClientState.spin.pity = result.pity
		end
		if type(result.coins) == "number" then
			ClientState.coins = result.coins
		end

		wheel:landOn(resolveIndex(result), function()
			finish(result)
		end)
	end)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildWheelColumn(parent: Instance)
	local column = Instance.new("Frame")
	column.Name = "WheelColumn"
	column.LayoutOrder = 1
	column.Size = UDim2.new(0.46, -8, 1, 0)
	column.BackgroundTransparency = 1
	column.ZIndex = 3
	column.Parent = parent

	local area = Instance.new("Frame")
	area.Name = "WheelArea"
	area.Size = UDim2.new(1, 0, 1, -84)
	area.BackgroundTransparency = 1
	area.ZIndex = 3
	area.Parent = column

	wheel = SpinWheel.create(area)
	trove:Add(function()
		wheel:destroy()
	end)

	local reward = UITheme.label("", UITheme.TextSizes.Body, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	reward.Name = "Reward"
	reward.AnchorPoint = Vector2.new(0.5, 1)
	reward.Position = UDim2.new(0.5, 0, 1, -66)
	reward.Size = UDim2.new(1, 0, 0, 20)
	reward.TextXAlignment = Enum.TextXAlignment.Center
	reward.ZIndex = 3
	reward.Parent = column
	rewardLabel = reward

	local cost = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	cost.Name = "Cost"
	cost.AnchorPoint = Vector2.new(0.5, 1)
	cost.Position = UDim2.new(0.5, 0, 1, -46)
	cost.Size = UDim2.new(1, 0, 0, 18)
	cost.TextXAlignment = Enum.TextXAlignment.Center
	cost.ZIndex = 3
	cost.Parent = column
	costLabel = cost

	spinButton = Button.create({
		name = "Spin",
		text = "SPIN",
		size = UDim2.new(0.8, 0, 0, 38),
		position = UDim2.new(0.5, 0, 1, -2),
		anchorPoint = Vector2.new(0.5, 1),
		color = UITheme.Colors.Accent,
		textColor = UITheme.Colors.PanelDark,
		parent = column,
		onActivated = spin,
	})
	spinButton.instance.ZIndex = 4
	trove:Add(function()
		spinButton:destroy()
	end)
end

local function buildOddsColumn(parent: Instance)
	local column = Instance.new("Frame")
	column.Name = "OddsColumn"
	column.LayoutOrder = 2
	column.Size = UDim2.new(0.54, -8, 1, 0)
	column.BackgroundTransparency = 1
	column.ZIndex = 3
	column.Parent = parent

	local header = UITheme.label("DROP CHANCES", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 20)
	header.ZIndex = 3
	header.Parent = column

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Odds"
	scroll.Position = UDim2.new(0, 0, 0, 22)
	scroll.Size = UDim2.new(1, 0, 1, -78)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = UITheme.Colors.Stroke
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ZIndex = 3
	scroll.Parent = column

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = scroll

	for index, segment in SpinConfig.Segments do
		local row = ListRow.create({
			name = segment.id,
			parent = scroll,
			title = segment.label,
			value = string.format("%.1f%%", SpinWheel.percentOf(segment)),
			accentColor = SpinWheel.segmentColor(segment),
			valueColor = UITheme.Colors.Text,
			height = ODDS_ROW_HEIGHT,
			layoutOrder = index,
		})
		row.instance.ZIndex = 3
		trove:Add(function()
			row:destroy()
		end)
	end

	local track = Instance.new("Frame")
	track.Name = "PityTrack"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 0, 1, -24)
	track.Size = UDim2.new(1, 0, 0, 8)
	track.BackgroundColor3 = UITheme.Colors.PanelDark
	track.BorderSizePixel = 0
	track.ClipsDescendants = true
	track.ZIndex = 3
	track.Parent = column
	UITheme.corner(UITheme.Radius.Pill).Parent = track

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = UITheme.Colors.AccentAlt
	fill.BorderSizePixel = 0
	fill.ZIndex = 4
	fill.Parent = track
	UITheme.corner(UITheme.Radius.Pill).Parent = fill
	pityFill = fill

	local pity = UITheme.label("", UITheme.TextSizes.Tiny, UITheme.Colors.TextDim)
	pity.Name = "Pity"
	pity.AnchorPoint = Vector2.new(0, 1)
	pity.Position = UDim2.fromScale(0, 1)
	pity.Size = UDim2.new(1, 0, 0, 18)
	pity.ZIndex = 3
	pity.Parent = column
	pityLabel = pity
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SpinScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("SpinMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		title = "REWARD WHEEL",
		subtitle = `Free spin every {math.floor(SpinConfig.FREE_SPIN_INTERVAL / SECONDS_PER_HOUR)}h — all odds shown`,
		size = UDim2.fromScale(0.7, 0.76),
		parent = gui,
		accentColor = UITheme.Colors.AccentAlt,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	local body = Instance.new("Frame")
	body.Name = "Columns"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.ZIndex = 3
	body.Parent = panel.content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = body

	buildWheelColumn(body)
	buildOddsColumn(body)

	UIController.registerMenu("Spin", panel:asMenuHandle())
	-- Panel closes itself from its X button and its backdrop, and neither path
	-- reaches UIController — which is what tells MouseLockController to re-capture
	-- the cursor. Both are re-pointed at closeMenu.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu("Spin")
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu("Spin")
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu("Spin")
	end)

	trove:Add(ClientState.ProfileChanged:Connect(function()
		refreshPity()
		refreshClock()
	end))
	trove:Connect(RunService.Heartbeat, refreshClock)

	refreshPity()
	refreshClock()
end

function SpinScreen.stop()
	trove:Clean()
	panel = nil
	wheel = nil
	spinButton = nil
	costLabel = nil
	rewardLabel = nil
	pityFill = nil
	pityLabel = nil
end

return SpinScreen
