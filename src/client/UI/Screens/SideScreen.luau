--!nonstrict
--[[
	SideScreen.luau
	"Pick a side", the way CS2 asks when you join a server.

	Opens once when the player lands on a map and closes on the first answer,
	including the answer "leave me where I am". It is not a menu the player goes
	looking for — it comes to them, once, at the only moment the question makes
	sense.

	NOTHING HERE DECIDES ANYTHING. The buttons send a team id and the server
	replies with whether the move happened. It is not told the team sizes and
	does not compute whether a move is legal, because a client that worked that
	out for itself would be a client that could be edited to work it out
	differently. SideAssignment on the server owns the rule; this file owns the
	question and the sentence that explains the answer.

	The refusal text is why the reply carries a reason at all. "Пока нельзя"
	with no explanation is the same dead button this project keeps finding — a
	player who is told the sides would become uneven understands immediately,
	tries again after someone else swaps, and never files it as broken.

	IT MUST NEVER BE A WALL. The balance rule refuses a move that would make the
	sides more than one apart, and in a 1v1 — the size nearly every match starts
	at — that is BOTH sides: leaving A for B turns 1v1 into 0v2. So the two team
	buttons are the entire screen and neither of them can be pressed, in front of
	a player who has just walked into a match and wants to shoot.

	Two things stop that. ИГРАТЬ answers the question with "leave me where I am",
	which is always available because it asks the server for nothing. And the
	whole panel closes itself after a countdown, so a player who taps nothing at
	all is still playing a few seconds later. A question with no acceptable
	answer is worse than no question.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Button = require(script.Parent.Parent.Components.Button)
local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local Panel = require(script.Parent.Parent.Components.Panel)
local RemoteNames = require(Shared.RemoteNames)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local SideScreen = {}
SideScreen.Priority = 37

local MENU_NAME = "Side"

-- Why a move was refused, in words a nine year old can act on. Keyed by the
-- SideAssignment constants the server sends back.
local REASONS = {
	wouldUnbalance = "Тогда команды станут неравными. Попробуй, когда кто-то перейдёт.",
	alreadyThere = "Ты уже в этой команде.",
	notPlaying = "Сейчас ты не в матче.",
	unknownTeam = "Такой команды нет.",
}

-- How long the question waits before answering itself with "stay". Long enough
-- to read two team names and a number, short enough that nobody stands in a
-- match they cannot see because a menu is over it.
local AUTO_CLOSE_SECONDS = 10

-- Bands inside the panel content, bottom-up. Named because the sides row is
-- sized by subtracting them, so a taller button would otherwise silently start
-- overlapping the row above it.
local STATUS_HEIGHT = 40
local STAY_HEIGHT = 48
local STAY_TEXT = "ИГРАТЬ"

local trove = Trove.new()
local panel: any = nil
local buttons: { [string]: any } = {}
local stayButton: any = nil
local status: TextLabel? = nil
local answered = false
local counts: { [string]: number } = {}
-- Bumped every time the question opens or closes. The countdown loop carries the
-- value it started with and stops the moment it stops matching, which is how a
-- player who answers in the first second does not get closed on again later by a
-- timer from a previous match.
local generation = 0

--[[
	The team sizes on the buttons, CS2-style.

	They come from the server on every answer and when the panel opens, and are
	never computed here: the number a player reads has to be the number the rule
	used, or "that would unbalance it" arrives next to a scoreline that says it
	would not.

	The side the player is already on is marked, because "ВЫБЕРИ СТОРОНУ" in front
	of two identical buttons does not say which one you are looking out of.
]]
local function labelFor(teamId: string): string
	local team = Constants.TEAMS[teamId]
	local name = string.upper(team and team.name or teamId)
	local size = counts[teamId]
	local label = if size then `{name}  {size}` else name
	if ClientState.getTeamId() == teamId then
		label ..= "  ·  ТЫ"
	end
	return label
end

local function refreshLabels()
	for teamId, button in buttons do
		button:setText(labelFor(teamId))
	end
end

local function applyCounts(fresh: any)
	if type(fresh) ~= "table" then
		return
	end
	counts = {}
	for _, teamId in Constants.TEAM_IDS do
		if type(fresh[teamId]) == "number" then
			counts[teamId] = fresh[teamId]
		end
	end
	refreshLabels()
end

--[[
	Asks the server for the current sizes. Fire and forget: the panel is usable
	without the numbers, so a failure here leaves the plain team names rather
	than blocking the question.
]]
local function pullCounts()
	local remote = ClientState.getRemote(RemoteNames.TeamCountsRequest)
	if not remote then
		return
	end

	local ok, reply = pcall(function()
		return (remote :: any):InvokeServer()
	end)
	if ok and type(reply) == "table" then
		applyCounts(reply.counts)
	end
end

local function teamColor(teamId: string): Color3
	local team = Constants.TEAMS[teamId]
	local rgb = team and team.color or { r = 200, g = 200, b = 200 }
	return Color3.fromRGB(rgb.r, rgb.g, rgb.b)
end

local function setStatus(text: string, color: Color3?)
	if status then
		status.Text = text
		status.TextColor3 = color or UITheme.Colors.TextDim
	end
end

--[[
	Only the TEAM buttons. ИГРАТЬ is deliberately left alone: it is the answer
	that needs no server, so greying it out while a request is in flight would
	take away the only guaranteed exit at exactly the moment the request is
	about to come back refused.
]]
local function setBusy(busy: boolean)
	for _, button in buttons do
		button:setEnabled(not busy)
	end
end

--[[
	Answer "leave me where I am" and get out of the way.

	Nothing is sent. The server already put this player on a side when the match
	started, so staying is not a request that can be refused — which is the whole
	point of having it.
]]
local function stay()
	if answered then
		return
	end
	answered = true
	generation += 1
	UIController.closeMenu(MENU_NAME)
end

--[[
	Ask for `teamId`. The reply is authoritative in both directions: a yes closes
	the panel, a no leaves it open with the reason, because being refused and
	then having the question disappear is indistinguishable from it having worked.
]]
local function choose(teamId: string)
	if answered then
		return
	end

	local remote = ClientState.getRemote(RemoteNames.ChooseSideRequest)
	if not remote then
		setStatus("Нет связи с сервером.", UITheme.Colors.Negative)
		return
	end

	setBusy(true)
	setStatus("Секунду…")

	local ok, result = pcall(function()
		return (remote :: any):InvokeServer(teamId)
	end)

	setBusy(false)

	if not ok or type(result) ~= "table" then
		setStatus("Не получилось. Попробуй ещё раз.", UITheme.Colors.Negative)
		return
	end

	applyCounts(result.counts)

	if result.ok then
		answered = true
		generation += 1
		UIController.closeMenu(MENU_NAME)
		return
	end

	setStatus(REASONS[result.reason] or "Пока нельзя.", UITheme.Colors.Negative)
	-- A refusal is the case where the countdown matters most, so it is the case
	-- where the way out has to be named out loud rather than left to a small ✕.
	if stayButton then
		stayButton:setText("ИГРАТЬ ЗА СВОЮ СТОРОНУ")
	end
end

local function buildSideButton(parent: Instance, teamId: string, order: number)
	local button = Button.create({
		name = teamId,
		parent = parent,
		text = labelFor(teamId),
		size = UDim2.new(0.5, -8, 1, 0),
		color = teamColor(teamId),
		onActivated = function()
			choose(teamId)
		end,
	})
	button.instance.LayoutOrder = order
	buttons[teamId] = button
	return button
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function SideScreen.isOpen(): boolean
	return panel ~= nil and panel:isOpen()
end

--[[
	The sides on offer, for tests. Keyed by team id so a check can press one
	without knowing where on the screen it landed.
]]
function SideScreen.buttons(): { [string]: any }
	return buttons
end

-- The panel itself, for tests that need to close it the way a player does.
function SideScreen.panel(): any
	return panel
end

-- The sizes currently shown, for tests.
function SideScreen.counts(): { [string]: number }
	return counts
end

--[[
	Goes through UIController rather than panel:open().

	Panel:open() shows the panel and tells nobody. MenuVisibilityChanged is fired
	by UIController.openMenu alone, and that signal is what frees the mouse on a
	desktop and takes the touch controls off the screen — so a panel opened
	directly appears UNDER the fire button, which is exactly where a question
	nobody can answer would go.
]]
function SideScreen.open()
	if not panel or answered then
		return
	end

	UIController.openMenu(MENU_NAME)
	SideScreen.startCountdown()
end

--[[
	Counts the question down and then answers it with "stay".

	This exists because of the 1v1: the balance rule refuses both sides, so
	without it the only exit is the ✕ in the corner, and a player who does not
	find it is standing in a match behind a menu wondering why nothing responds.
	A timer cannot be missed.

	It carries the generation it started in and checks it every second, so
	answering early does not leave a timer running that closes the question the
	player reopened for the next match.

	Separate from open() only so tests can run the loop without waiting out ten
	real seconds.
]]
function SideScreen.startCountdown(seconds: number?)
	generation += 1
	local mine = generation
	local remaining = seconds or AUTO_CLOSE_SECONDS

	task.spawn(function()
		while remaining > 0 do
			if generation ~= mine or not SideScreen.isOpen() then
				return
			end
			if panel then
				panel:setSubtitle(`Команды должны остаться равными  ·  {remaining}`)
			end
			task.wait(1)
			remaining -= 1
		end

		if generation == mine and SideScreen.isOpen() then
			stay()
		end
	end)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SideScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("SideMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		-- The panel's own X button and the tap-behind close it without going
		-- through UIController, so it would never learn. This is how it learns.
		onClose = function()
			UIController.notifyClosed(MENU_NAME)
		end,
		title = "ВЫБЕРИ СТОРОНУ",
		subtitle = "Команды должны остаться равными",
		size = UDim2.fromScale(0.62, 0.42),
		parent = gui,
		accentColor = UITheme.Colors.Accent,
		-- Not dismissable by tapping past it: the one question this screen asks
		-- should be answered on purpose, including the answer "stay".
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	-- Three bands down the panel: the two sides, the reason line, and the way
	-- out. The way out is last and full width because it is the one control that
	-- can never be refused, and a 1v1 is a match where it is the only one.
	local row = Instance.new("Frame")
	row.Name = "Sides"
	row.Size = UDim2.new(1, 0, 1, -(STATUS_HEIGHT + STAY_HEIGHT))
	row.BackgroundTransparency = 1
	row.Parent = panel.content

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 16)
	layout.Parent = row

	for index, teamId in Constants.TEAM_IDS do
		buildSideButton(row, teamId, index)
	end

	status = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.TextDim)
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0.5, 1)
	status.Position = UDim2.new(0.5, 0, 1, -STAY_HEIGHT)
	status.Size = UDim2.new(1, -16, 0, STATUS_HEIGHT)
	status.TextWrapped = true
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.Parent = panel.content

	stayButton = Button.create({
		name = "Stay",
		parent = panel.content,
		text = STAY_TEXT,
		size = UDim2.new(1, -16, 0, STAY_HEIGHT - 10),
		position = UDim2.new(0.5, 0, 1, 0),
		anchorPoint = Vector2.new(0.5, 1),
		color = UITheme.Colors.Accent,
		textColor = UITheme.Colors.Background,
		onActivated = stay,
	})
	trove:Add(function()
		stayButton:destroy()
	end)

	UIController.registerMenu(MENU_NAME, panel:asMenuHandle())
	trove:Add(function()
		UIController.unregisterMenu(MENU_NAME)
	end)

	--[[
		Entering a match is the trigger, and leaving one is what re-arms it.
		Without the reset a player would be asked once per session rather than
		once per match, which is the same as not being asked.
	]]
	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name ~= "InMatch" then
			return
		end

		if ClientState.isInMatch() then
			answered = false
			setStatus("")
			setBusy(false)
			-- Back to the plain wording: the longer "ИГРАТЬ ЗА СВОЮ СТОРОНУ" is
			-- an answer to a refusal, and this match has not refused anything yet.
			if stayButton then
				stayButton:setText(STAY_TEXT)
			end
			refreshLabels()
			SideScreen.open()
			-- After opening, so the question is on screen while the numbers are
			-- being fetched rather than after.
			pullCounts()
		else
			answered = false
			-- Retires any countdown still running for the match just left.
			generation += 1
			if panel and panel:isOpen() then
				UIController.closeMenu(MENU_NAME)
			end
		end
	end))
end

function SideScreen.stop()
	trove:Clean()
	panel = nil
	buttons = {}
	stayButton = nil
	status = nil
	answered = false
	counts = {}
	-- Retires any countdown still in flight, so it cannot fire into a torn-down
	-- screen after a restart.
	generation += 1
end

-- The "leave me where I am" button, for tests.
function SideScreen.stayButton(): any
	return stayButton
end

return SideScreen
