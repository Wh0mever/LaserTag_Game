--!nonstrict
--[[
	QueueScreen.luau
	"DUST · В ОЧЕРЕДИ 1/2", then "DUST · СТАРТ ЧЕРЕЗ 7": a small chip at the
	top of the screen while the player stands on a portal pad.

	The server has always sent this — a QueueUpdate every time the queue or the
	countdown changes — and nothing drew it. The only feedback was the lit sign
	above the pad, sixteen studs up behind the player, which is off screen
	whenever the camera faces away from it: on a phone, most of the time. A
	player on the pad had no way to know they were queued, how many more were
	needed, or that the match was about to start.

	Everything comes from ClientState.queue; this asks the server for nothing.
	An empty map id means "in no queue" (QueueService sends that to whoever
	steps off), and the chip is never shown during a match.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local TextUtil = require(Shared.Util.TextUtil)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local QueueScreen = {}
QueueScreen.Priority = 38

local CHIP_HEIGHT = 30
local BELOW_BAR = 8

local trove = Trove.new()
local chip: Frame? = nil
local label: TextLabel? = nil

--[[
	The chip's text for a queue state, or nil when there is nothing to show.
	Pure over its arguments, so the harness can check every wording.
]]
function QueueScreen.textFor(mapId: string?, count: number, needed: number, countdown: number?): string?
	if type(mapId) ~= "string" or mapId == "" or count <= 0 then
		return nil
	end

	local name = TextUtil.upper(mapId)
	if type(countdown) == "number" and countdown > 0 then
		return `{name}  ·  СТАРТ ЧЕРЕЗ {math.ceil(countdown)}`
	end
	if count < needed then
		return `{name}  ·  В ОЧЕРЕДИ {count}/{needed}`
	end
	return `{name}  ·  МАТЧ СОБРАН`
end

local function refresh()
	if not chip or not label then
		return
	end

	local queue = ClientState.queue or {}
	local text = if ClientState.isInMatch()
		then nil
		else QueueScreen.textFor(queue.mapId, queue.count or 0, queue.needed or 0, queue.countdown)

	chip.Visible = text ~= nil
	if text then
		label.Text = text
		-- Gold for the countdown, the one moment the player has to act on
		-- (stay on the pad); calm otherwise.
		local starting = type(queue.countdown) == "number" and queue.countdown > 0
		label.TextColor3 = if starting then UITheme.Colors.Coin else UITheme.Colors.Text
	end
end

-- The chip, for tests.
function QueueScreen.chip(): Frame?
	return chip
end

function QueueScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("Queue", Constants.DISPLAY_ORDER.HUD)
	if not gui then
		return
	end

	local frame = Instance.new("Frame")
	frame.Name = "QueueChip"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, UIController.getTopBarOffset() + BELOW_BAR)
	frame.Size = UDim2.fromOffset(0, CHIP_HEIGHT)
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.BackgroundColor3 = UITheme.Colors.PanelDark
	frame.BackgroundTransparency = 0.15
	frame.BorderSizePixel = 0
	frame.Visible = false
	frame.Parent = gui
	UITheme.corner(UITheme.Radius.Pill).Parent = frame
	UITheme.stroke(UITheme.Colors.Accent, 1.5).Parent = frame
	UITheme.padding(16, 0).Parent = frame
	trove:Add(frame)
	chip = frame

	local text = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.Text, UITheme.Fonts.Bold)
	text.Name = "Text"
	text.Size = UDim2.new(0, 0, 1, 0)
	text.AutomaticSize = Enum.AutomaticSize.X
	text.TextTruncate = Enum.TextTruncate.None
	text.Parent = frame
	label = text

	-- The bar is in real pixels and the scale moves with the viewport, so the
	-- chip is placed again when either does; see UIController.getTopBarOffset.
	local function place()
		frame.Position = UDim2.new(0.5, 0, 0, UIController.getTopBarOffset() + BELOW_BAR)
	end
	trove:Add(UIController.ScaleChanged:Connect(place))
	trove:Add(UIController.ViewportChanged:Connect(place))

	trove:Add(ClientState.QueueChanged:Connect(refresh))
	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name == "InMatch" then
			refresh()
		end
	end))
	refresh()
end

function QueueScreen.stop()
	trove:Clean()
	chip = nil
	label = nil
end

return QueueScreen
