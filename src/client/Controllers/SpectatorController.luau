--!nonstrict
--[[
	SpectatorController.luau
	The death overlay: who killed you, and how long until you are back.

	It owns no camera state. CameraController already swings the view onto the
	killer when ClientState.Died fires and restores it on Respawned; this module
	only reads `CameraController.isDeathCamActive()` to decide whether to label
	the view as spectating, and never assigns to workspace.CurrentCamera. Two
	modules writing the camera is how a player ends up stuck in a scriptable view.

	The countdown runs off a local clock seeded from the server's respawnSeconds
	rather than off a tick from the server, because a respawn timer that stutters
	with packet loss looks broken even when it is not. The overlay hides on
	Respawned — the authoritative "you are alive again" — not when the countdown
	reaches zero, so a slow server spawn shows "RESPAWNING…" instead of dropping
	the overlay onto a corpse.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local CameraController = require(script.Parent.CameraController)
local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)
local UITheme = require(script.Parent.Parent.UI.UITheme)

local SpectatorController = {}
-- Last of the controllers: it only reacts to state the others have already set.
SpectatorController.Priority = 10

local CARD_WIDTH, CARD_HEIGHT = 420, 178
local DIM_TRANSPARENCY = 0.58

local trove = Trove.new()
local countdownTrove = Trove.new()

local root: Frame? = nil
local dim: Frame? = nil
local eyebrowLabel: TextLabel? = nil
local killerLabel: TextLabel? = nil
local countdownLabel: TextLabel? = nil
local footerLabel: TextLabel? = nil
local barFill: Frame? = nil

local visible = false
local endsAt = 0
local totalSeconds = Constants.RESPAWN_SECONDS
local killer: Player? = nil

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function centeredLabel(text: string, size: number, color: Color3, font: Enum.Font): TextLabel
	local label = UITheme.label(text, size, color, font)
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	return label
end

--[[
	Built on first death rather than at boot. Controllers start before the UI
	pass, so a ScreenGui created during start() would register its UIScale before
	UIController has computed the device scale; by the first death that ordering
	is long settled.
]]
local function ensureGui(): boolean
	if root and root.Parent then
		return true
	end

	local gui = UIController.getScreenGui("Spectator", Constants.DISPLAY_ORDER.Toast)
	if not gui then
		return false
	end

	local overlay = Instance.new("Frame")
	overlay.Name = "Root"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.Visible = false
	overlay.Parent = gui
	root = overlay

	local shade = Instance.new("Frame")
	shade.Name = "Dim"
	shade.Size = UDim2.fromScale(1, 1)
	shade.BackgroundColor3 = UITheme.Colors.Background
	shade.BackgroundTransparency = DIM_TRANSPARENCY
	shade.BorderSizePixel = 0
	shade.Parent = overlay
	dim = shade

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	-- Above centre: the death camera frames the killer in the lower two thirds
	-- of the screen, so the card must not sit on top of them.
	card.Position = UDim2.fromScale(0.5, 0.3)
	card.Size = UDim2.fromOffset(CARD_WIDTH, CARD_HEIGHT)
	card.BackgroundColor3 = UITheme.Colors.Panel
	card.BorderSizePixel = 0
	card.Parent = overlay
	UITheme.corner(UITheme.Radius.Large).Parent = card
	UITheme.stroke(UITheme.Colors.Negative, 2).Parent = card
	UITheme.padding(18, 16).Parent = card

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = card

	local eyebrow = centeredLabel("ELIMINATED", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	eyebrow.Size = UDim2.new(1, 0, 0, 16)
	eyebrow.LayoutOrder = 1
	eyebrow.Parent = card
	eyebrowLabel = eyebrow

	local name = centeredLabel("", UITheme.TextSizes.Title, UITheme.Colors.Text, UITheme.Fonts.Heading)
	name.Size = UDim2.new(1, 0, 0, 30)
	name.LayoutOrder = 2
	name.Parent = card
	killerLabel = name

	local respawn = centeredLabel("RESPAWNING IN", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	respawn.Size = UDim2.new(1, 0, 0, 16)
	respawn.LayoutOrder = 3
	respawn.Parent = card

	local countdown = centeredLabel("3", UITheme.TextSizes.Display, UITheme.Colors.Accent, UITheme.Fonts.Number)
	countdown.Size = UDim2.new(1, 0, 0, 40)
	countdown.LayoutOrder = 4
	countdown.Parent = card
	countdownLabel = countdown

	local barTrack = Instance.new("Frame")
	barTrack.Name = "BarTrack"
	barTrack.Size = UDim2.new(1, 0, 0, 6)
	barTrack.BackgroundColor3 = UITheme.Colors.PanelDark
	barTrack.BorderSizePixel = 0
	barTrack.LayoutOrder = 5
	barTrack.Parent = card
	UITheme.corner(UITheme.Radius.Pill).Parent = barTrack

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UITheme.Colors.Accent
	fill.BorderSizePixel = 0
	fill.Parent = barTrack
	UITheme.corner(UITheme.Radius.Pill).Parent = fill
	barFill = fill

	local footer = centeredLabel("", UITheme.TextSizes.Tiny, UITheme.Colors.TextMuted, UITheme.Fonts.Body)
	footer.Size = UDim2.new(1, 0, 0, 14)
	footer.LayoutOrder = 6
	footer.Parent = card
	footerLabel = footer

	trove:Add(overlay)
	return true
end

--------------------------------------------------------------------------------
-- Countdown
--------------------------------------------------------------------------------

local function onCountdownStep()
	local remaining = math.max(0, endsAt - os.clock())

	if countdownLabel then
		-- ceil, so the last whole second is shown as "1" rather than "0" for the
		-- entire time the player is still waiting.
		countdownLabel.Text = if remaining > 0 then tostring(math.ceil(remaining)) else "…"
	end

	if barFill then
		barFill.Size = UDim2.fromScale(math.clamp(remaining / math.max(totalSeconds, 0.001), 0, 1), 1)
	end

	if footerLabel then
		local watching = killer and killer.Parent ~= nil and CameraController.isDeathCamActive()
		footerLabel.Text = if watching then `SPECTATING {killer.DisplayName}` else ""
	end
end

--------------------------------------------------------------------------------
-- Show / hide
--------------------------------------------------------------------------------

local function hide()
	countdownTrove:Clean()
	visible = false
	killer = nil

	if root then
		root.Visible = false
	end
end

local function show(killerUserId: number?, respawnSeconds: number)
	if not ensureGui() or not root then
		return
	end

	-- Defensive: a second DeathInfo without an intervening respawn would
	-- otherwise leave two Heartbeat connections stepping the same countdown.
	countdownTrove:Clean()

	killer = if type(killerUserId) == "number" then Players:GetPlayerByUserId(killerUserId) else nil
	totalSeconds = if type(respawnSeconds) == "number" and respawnSeconds > 0
		then respawnSeconds
		else Constants.RESPAWN_SECONDS
	endsAt = os.clock() + totalSeconds

	if killer and killer ~= Players.LocalPlayer then
		eyebrowLabel.Text = "ВАС УБИЛ"
		killerLabel.Text = string.upper(killer.DisplayName)
		killerLabel.TextColor3 = UITheme.teamColor(killer:GetAttribute("TeamId"))
	else
		-- No attribution: fall damage, the kill plane, or a killer who left.
		eyebrowLabel.Text = "ВЫ УБИТЫ"
		killerLabel.Text = "ВНЕ ИГРЫ"
		killerLabel.TextColor3 = UITheme.Colors.TextDim
	end

	if dim then
		dim.BackgroundTransparency = DIM_TRANSPARENCY
	end

	visible = true
	root.Visible = true
	onCountdownStep()

	-- Only bound while the overlay is up: there is no reason to touch four GUI
	-- properties every frame for the rest of a ten minute match.
	countdownTrove:Connect(RunService.Heartbeat, onCountdownStep)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function SpectatorController.isVisible(): boolean
	return visible
end

--[[
	The player being spectated, or nil when the death was unattributed.
]]
function SpectatorController.getKiller(): Player?
	return killer
end

function SpectatorController.getSecondsLeft(): number
	if not visible then
		return 0
	end
	return math.max(0, endsAt - os.clock())
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function SpectatorController.init()
	ClientState.init()

	trove:Add(ClientState.Died:Connect(show))
	trove:Add(ClientState.Respawned:Connect(hide))
	trove:Add(countdownTrove)
end

function SpectatorController.stop()
	hide()
	trove:Clean()
end

return SpectatorController
