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

local trove = Trove.new()
local panel: any = nil
local buttons: { [string]: any } = {}
local status: TextLabel? = nil
local answered = false

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

local function setBusy(busy: boolean)
	for _, button in buttons do
		button:setEnabled(not busy)
	end
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

	if result.ok then
		answered = true
		UIController.closeMenu(MENU_NAME)
		return
	end

	setStatus(REASONS[result.reason] or "Пока нельзя.", UITheme.Colors.Negative)
end

local function buildSideButton(parent: Instance, teamId: string, order: number)
	local team = Constants.TEAMS[teamId]
	local button = Button.create({
		name = teamId,
		parent = parent,
		text = string.upper(team and team.name or teamId),
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

--[[
	Goes through UIController rather than panel:open().

	Panel:open() shows the panel and tells nobody. MenuVisibilityChanged is fired
	by UIController.openMenu alone, and that signal is what frees the mouse on a
	desktop and takes the touch controls off the screen — so a panel opened
	directly appears UNDER the fire button, which is exactly where a question
	nobody can answer would go.
]]
function SideScreen.open()
	if panel and not answered then
		UIController.openMenu(MENU_NAME)
	end
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

	local row = Instance.new("Frame")
	row.Name = "Sides"
	row.Size = UDim2.new(1, 0, 1, -56)
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
	status.Position = UDim2.new(0.5, 0, 1, 0)
	status.Size = UDim2.new(1, -16, 0, 40)
	status.TextWrapped = true
	status.TextXAlignment = Enum.TextXAlignment.Center
	status.Parent = panel.content

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
			SideScreen.open()
		else
			answered = false
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
	status = nil
	answered = false
end

return SideScreen
