--!nonstrict
--[[
	FriendsScreen.luau
	Two lists: friends already in this server, and friends online somewhere else.

	GetFriendsRequest is rate limited to 2 calls per 10 seconds on the server, so
	the refresh button enforces its own cooldown rather than letting an impatient
	player spend the budget and get kicked for it. A refresh in flight disables
	the button outright.

	Rows are pooled and reused between refreshes: the same fifteen ListRows are
	re-titled instead of being destroyed and rebuilt every time the list comes
	back.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local ListRow = require(script.Parent.Parent.Components.ListRow)
local Panel = require(script.Parent.Parent.Components.Panel)
local RemoteNames = require(Shared.RemoteNames)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local FriendsScreen = {}
FriendsScreen.Priority = 30

-- Comfortably inside the server's 2-per-10s budget, so a player mashing the
-- button never trips the rate limiter's violation counter.
local REFRESH_COOLDOWN = 6
local ROW_HEIGHT = 48
local NEVER = -math.huge

local trove = Trove.new()
local panel: any = nil
local refreshButton: any = nil
local sections: { [string]: any } = {}
local pool: { any } = {}
local used: { any } = {}
local pending = false
local lastFetchAt = NEVER

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

local function acquire(parent: Instance)
	local row = table.remove(pool)
	if not row then
		row = ListRow.create({ parent = parent, title = "", height = ROW_HEIGHT })
		row.instance.ZIndex = 3
		trove:Add(function()
			row:destroy()
		end)
	end

	row.instance.Parent = parent
	row.instance.Visible = true
	table.insert(used, row)
	return row
end

local function releaseAll()
	for index = #used, 1, -1 do
		local row = used[index]
		used[index] = nil
		row.instance.Visible = false
		row.instance.Parent = nil
		table.insert(pool, row)
	end
end

local function fill(section, entries, valueText: string, accent: Color3)
	local count = 0
	for index, entry in entries do
		if type(entry) ~= "table" or type(entry.name) ~= "string" then
			continue
		end

		local display = entry.displayName or entry.name
		local row = acquire(section.list)
		row:update({
			title = display,
			subtitle = `@{entry.name}`,
			value = valueText,
			valueColor = accent,
			accentColor = accent,
			icon = string.upper(string.sub(display, 1, 1)),
			layoutOrder = index,
		})
		count += 1
	end

	section.empty.Visible = count == 0
	section.header.Text = `{section.title}  ({count})`
end

--------------------------------------------------------------------------------
-- Fetching
--------------------------------------------------------------------------------

local function setButton(text: string, enabled: boolean)
	if refreshButton and refreshButton.instance.Parent then
		refreshButton:setText(text)
		refreshButton:setEnabled(enabled)
	end
end

--[[
	Throttled by REFRESH_COOLDOWN for every caller, including the button: a
	refused refresh that silently does nothing is worse than a button that is
	visibly disabled until it can be used again.
]]
local function fetch()
	local now = os.clock()
	if pending or now - lastFetchAt < REFRESH_COOLDOWN then
		return
	end

	lastFetchAt = now
	pending = true
	setButton("…", false)

	task.spawn(function()
		local remote = ClientState.getRemote(RemoteNames.GetFriendsRequest)
		local result
		if remote then
			local ok, response = pcall(function()
				return (remote :: any):InvokeServer()
			end)
			result = ok and response or nil
		end

		pending = false
		-- Stays disabled for the rest of the cooldown window, then comes back.
		setButton("ОБНОВИТЬ", false)
		task.delay(math.max(REFRESH_COOLDOWN - (os.clock() - lastFetchAt), 0), function()
			setButton("ОБНОВИТЬ", true)
		end)

		releaseAll()
		if type(result) ~= "table" then
			fill(sections.inServer, {}, "", UITheme.Colors.Positive)
			fill(sections.online, {}, "", UITheme.Colors.AccentAlt)
			sections.inServer.empty.Text = "Не удалось загрузить список друзей"
			return
		end

		sections.inServer.empty.Text = "Друзей на этом сервере пока нет"
		fill(sections.inServer, result.inServer or {}, "ЗДЕСЬ", UITheme.Colors.Positive)
		fill(sections.online, result.online or {}, "В СЕТИ", UITheme.Colors.AccentAlt)
	end)
end

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function buildSection(key: string, title: string, emptyText: string, order: number, parent: Instance)
	local root = Instance.new("Frame")
	root.Name = key
	root.LayoutOrder = order
	root.Size = UDim2.new(1, 0, 0.5, -6)
	root.BackgroundTransparency = 1
	root.ZIndex = 3
	root.Parent = parent

	local header = UITheme.label(title, UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, 20)
	header.ZIndex = 3
	header.Parent = root

	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.new(0, 0, 0, 22)
	list.Size = UDim2.new(1, 0, 1, -22)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollBarThickness = 4
	list.ScrollBarImageColor3 = UITheme.Colors.Stroke
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.CanvasSize = UDim2.new()
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ZIndex = 3
	list.Parent = root

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = list

	local empty = UITheme.label(emptyText, UITheme.TextSizes.Small, UITheme.Colors.TextMuted)
	empty.Name = "Empty"
	empty.Position = UDim2.new(0, 0, 0, 26)
	empty.Size = UDim2.new(1, 0, 0, 20)
	empty.ZIndex = 3
	empty.Parent = root

	sections[key] = { instance = root, header = header, list = list, empty = empty, title = title }
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function FriendsScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("FriendsMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		title = "ДРУЗЬЯ",
		subtitle = "Кто сейчас в игре и на этом сервере",
		size = UDim2.fromScale(0.56, 0.68),
		parent = gui,
		accentColor = UITheme.Colors.Positive,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	local body = Instance.new("Frame")
	body.Name = "Sections"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.ZIndex = 3
	body.Parent = panel.content

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = body

	buildSection(
		"inServer",
		"НА ЭТОМ СЕРВЕРЕ",
		"Друзей на этом сервере пока нет",
		1,
		body
	)
	buildSection(
		"online",
		"В СЕТИ, НО В ДРУГОМ МЕСТЕ",
		"Сейчас никого из друзей нет в сети",
		2,
		body
	)

	refreshButton = Button.create({
		name = "Refresh",
		text = "ОБНОВИТЬ",
		size = UDim2.fromOffset(104, 30),
		position = UDim2.new(1, -56, 0, 13),
		anchorPoint = Vector2.new(1, 0),
		parent = panel.body,
		onActivated = fetch,
	})
	refreshButton.instance.ZIndex = 4
	trove:Add(function()
		refreshButton:destroy()
	end)

	UIController.registerMenu("Friends", panel:asMenuHandle())
	-- Panel's own close paths bypass UIController, which owns the cursor lock.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu("Friends")
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu("Friends")
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu("Friends")
	end)

	-- Fetching on open (rather than at boot) keeps the call off the join path and
	-- means the list is fresh exactly when it is being looked at.
	trove:Add(UIController.MenuVisibilityChanged:Connect(function(name: string, isOpen: boolean)
		if name == "Friends" and isOpen then
			fetch()
		end
	end))
end

function FriendsScreen.stop()
	trove:Clean()
	table.clear(sections)
	table.clear(pool)
	table.clear(used)
	panel = nil
	refreshButton = nil
end

return FriendsScreen
