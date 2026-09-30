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
	reaches zero, so a slow server spawn shows "…" instead of dropping
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
local TextUtil = require(Shared.Util.TextUtil)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)
local UITheme = require(script.Parent.Parent.UI.UITheme)

local SpectatorController = {}
-- Last of the controllers: it only reacts to state the others have already set.
SpectatorController.Priority = 10

-- A strip, not a panel. The death camera puts the killer in the middle of the
-- view, so the card hangs from the top edge (over the clock and the score,
-- which mean nothing for three seconds) and stays small enough that a phone
-- held sideways, about 294 studs tall, still shows the person who shot you.
-- The width is a ceiling: a narrower window gets a narrower card.
local CARD_WIDTH, CARD_HEIGHT = 300, 104
-- The line under the bar only has something to say while the killer is being
-- watched; without it the card gives that row back rather than leaving a
-- blank band at the bottom.
local FOOTER_HEIGHT = 16
local CARD_TOP = 12
-- Barely a dim: the killer and the map have to stay readable.
local DIM_TRANSPARENCY = 0.8

local trove = Trove.new()
local countdownTrove = Trove.new()

local root: Frame? = nil
local cardFrame: Frame? = nil
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

local function alignedLabel(
	name: string,
	text: string,
	size: number,
	color: Color3,
	font: Enum.Font,
	alignment: Enum.TextXAlignment
): TextLabel
	local label = UITheme.label(text, size, color, font)
	label.Name = name
	label.TextXAlignment = alignment
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
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, CARD_TOP)
	card.Size = UDim2.new(0.9, 0, 0, CARD_HEIGHT - FOOTER_HEIGHT)
	card.BackgroundColor3 = UITheme.Colors.Panel
	card.BorderSizePixel = 0
	card.Parent = overlay
	cardFrame = card
	UITheme.corner(UITheme.Radius.Large).Parent = card
	UITheme.stroke(UITheme.Colors.Negative, 2).Parent = card
	UITheme.padding(14, 10).Parent = card

	local limit = Instance.new("UISizeConstraint")
	-- Width only: the height is set by whether the footer line is showing.
	limit.MaxSize = Vector2.new(CARD_WIDTH, math.huge)
	limit.Parent = card

	-- Two columns over a bar: who did it on the left, how long to wait on the
	-- right. Positioned by hand so the strip's height never depends on layout.
	local eyebrow = alignedLabel(
		"Eyebrow",
		"ВЫ УБИТЫ",
		UITheme.TextSizes.Small,
		UITheme.Colors.TextDim,
		UITheme.Fonts.Bold,
		Enum.TextXAlignment.Left
	)
	eyebrow.Size = UDim2.new(0.54, 0, 0, 16)
	eyebrow.Parent = card
	eyebrowLabel = eyebrow

	local name = alignedLabel(
		"Killer",
		"",
		UITheme.TextSizes.Heading,
		UITheme.Colors.Text,
		UITheme.Fonts.Heading,
		Enum.TextXAlignment.Left
	)
	name.Position = UDim2.fromOffset(0, 18)
	name.Size = UDim2.new(0.54, 0, 0, 28)
	name.Parent = card
	killerLabel = name

	local respawn = alignedLabel(
		"RespawnCaption",
		"ВОЗРОЖДЕНИЕ",
		UITheme.TextSizes.Small,
		UITheme.Colors.TextDim,
		UITheme.Fonts.Bold,
		Enum.TextXAlignment.Right
	)
	respawn.AnchorPoint = Vector2.new(1, 0)
	respawn.Position = UDim2.fromScale(1, 0)
	respawn.Size = UDim2.new(0.44, 0, 0, 16)
	respawn.Parent = card

	local countdown = alignedLabel(
		"Countdown",
		"3",
		UITheme.TextSizes.Display,
		UITheme.Colors.Accent,
		UITheme.Fonts.Number,
		Enum.TextXAlignment.Right
	)
	countdown.AnchorPoint = Vector2.new(1, 0)
	countdown.Position = UDim2.new(1, 0, 0, 14)
	countdown.Size = UDim2.new(0.44, 0, 0, 38)
	countdown.Parent = card
	countdownLabel = countdown

	local barTrack = Instance.new("Frame")
	barTrack.Name = "BarTrack"
	barTrack.Position = UDim2.fromOffset(0, 58)
	barTrack.Size = UDim2.new(1, 0, 0, 6)
	barTrack.BackgroundColor3 = UITheme.Colors.PanelDark
	barTrack.BorderSizePixel = 0
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

	local footer = alignedLabel(
		"Watching",
		"",
		UITheme.TextSizes.Small,
		UITheme.Colors.TextMuted,
		UITheme.Fonts.Body,
		Enum.TextXAlignment.Center
	)
	footer.Position = UDim2.fromOffset(0, 68)
	footer.Size = UDim2.new(1, 0, 0, 16)
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
		footerLabel.Text = if watching then `НАБЛЮДЕНИЕ: {killer.DisplayName}` else ""

		local height = if watching then CARD_HEIGHT else CARD_HEIGHT - FOOTER_HEIGHT
		if cardFrame and cardFrame.Size.Y.Offset ~= height then
			cardFrame.Size = UDim2.new(0.9, 0, 0, height)
		end
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
		killerLabel.Text = TextUtil.upper(killer.DisplayName)
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
