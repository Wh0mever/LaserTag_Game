--!nonstrict
--[[
	NoticeScreen.luau
	A short banner across the top of the screen, for the things the server needs
	a player to actually read.

	Deliberately not part of the HUD. The HUD is hidden outside a match, and the
	message this exists for — "you were returned to the hub for standing still" —
	arrives exactly as the player stops being in one. A notice that vanished at
	the moment it became relevant would leave somebody in the hub with no idea
	why they were moved.

	One banner, reused. A second notice replaces the first rather than stacking:
	these are short and infrequent, and a queue of them would be a worse way to
	read one urgent line.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local RemoteNames = require(Shared.RemoteNames)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local NoticeScreen = {}
NoticeScreen.Priority = 38

local SHOW_SECONDS = 5
local FADE = TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Severity -> accent. An unknown severity falls back to the neutral one rather
-- than erroring: this is the module that tells a player what went wrong, so it
-- is the last one that should break on a surprise.
local ACCENTS = {
	info = UITheme.Colors.Accent,
	warning = UITheme.Colors.Warning,
	error = UITheme.Colors.Negative,
}

local trove = Trove.new()
local frame: Frame? = nil
local label: TextLabel? = nil
local stroke: UIStroke? = nil
-- Bumped on every notice so a stale hide cannot close a newer one.
local token = 0

local function hide()
	if not frame then
		return
	end
	TweenService:Create(frame, FADE, { BackgroundTransparency = 1 }):Play()
	if label then
		TweenService:Create(label, FADE, { TextTransparency = 1 }):Play()
	end
	if stroke then
		TweenService:Create(stroke, FADE, { Transparency = 1 }):Play()
	end
end

--[[
	Show `message`. Exposed so anything client-side can use the same banner
	rather than inventing a second one.
]]
function NoticeScreen.show(message: any, severity: any)
	if not frame or not label or type(message) ~= "string" or message == "" then
		return
	end

	local accent = ACCENTS[severity] or ACCENTS.info

	label.Text = message
	label.TextColor3 = accent
	label.TextTransparency = 0
	frame.BackgroundTransparency = 0.08
	if stroke then
		stroke.Color = accent
		stroke.Transparency = 0.1
	end

	token += 1
	local mine = token
	task.delay(SHOW_SECONDS, function()
		if token == mine then
			hide()
		end
	end)
end

function NoticeScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("Notice", Constants.DISPLAY_ORDER.Toast)
	if not gui then
		return
	end

	local root = Instance.new("Frame")
	root.Name = "Banner"
	root.AnchorPoint = Vector2.new(0.5, 0)
	root.Position = UDim2.new(0.5, 0, 0, 96)
	root.Size = UDim2.fromOffset(440, 40)
	root.BackgroundColor3 = UITheme.Colors.PanelDark
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.ZIndex = 60
	root.Parent = gui
	frame = root
	trove:Add(root)

	UITheme.corner(UITheme.Radius.Medium).Parent = root
	local edge = UITheme.stroke(UITheme.Colors.Accent, 1.5)
	edge.Transparency = 1
	edge.Parent = root
	stroke = edge

	local text = UITheme.label("", UITheme.TextSizes.Small, UITheme.Colors.Accent, UITheme.Fonts.Bold)
	text.Name = "Message"
	text.Size = UDim2.fromScale(1, 1)
	text.TextTransparency = 1
	text.TextWrapped = true
	text.ZIndex = 61
	text.Parent = root
	label = text
end

--[[
	The remote is connected here rather than in init() because getRemote yields
	on its first call, and a yielding init() stalls the whole loader.
]]
function NoticeScreen.start()
	local remote = ClientState.getRemote(RemoteNames.Notice)
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end

	trove:Connect((remote :: any).OnClientEvent, function(message: string, severity: string)
		NoticeScreen.show(message, severity)
	end)
end

function NoticeScreen.stop()
	trove:Clean()
	frame = nil
	label = nil
	stroke = nil
	token = 0
end

return NoticeScreen
