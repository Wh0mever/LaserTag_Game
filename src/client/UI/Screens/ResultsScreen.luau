--!nonstrict
--[[
	ResultsScreen.luau
	The end-of-match overlay: whether THIS player won, lost or drew (and who beat
	whom, or that the opponents left), both scores, the coins earned and how long
	until the server sends everyone back to the hub.

	Driven entirely by MatchStateChanged (through ClientState.MatchChanged). The
	phase leaving "Results" hides it, so nothing here has to guess when the
	teleport happened — if the server never fires the next phase, the overlay
	still stops counting at zero instead of going negative.

	The countdown is local. The Results payload carries scores and rewards but no
	clock, so the entry time is captured here and counted against
	GameConfig.RESULTS_DURATION; being a second out on a cosmetic countdown is
	cheaper than another per-second remote.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local GameConfig = require(Shared.Config.GameConfig)
local TextUtil = require(Shared.Util.TextUtil)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)

local ResultsScreen = {}
ResultsScreen.Priority = 23

local RESULTS_PHASE = "Results"

local player = Players.LocalPlayer
local trove = Trove.new()

local root: Frame? = nil
local headline: TextLabel? = nil
local subline: TextLabel? = nil
local scoreLabels: { [string]: TextLabel } = {}
local rewardLabel: TextLabel? = nil
local countdownLabel: TextLabel? = nil
local shownAt = 0
local lastCountdown = -1

--------------------------------------------------------------------------------
-- Construction
--------------------------------------------------------------------------------

local function centered(text: string, size: number, color: Color3, font: Enum.Font): TextLabel
	local label = UITheme.label(text, size, color, font)
	label.TextXAlignment = Enum.TextXAlignment.Center
	return label
end

local function buildScoreSide(teamId: string, alignRight: boolean, parent: Instance)
	local team = Constants.TEAMS[teamId]
	local color = UITheme.teamColor(teamId)

	local holder = Instance.new("Frame")
	holder.Name = `Team{teamId}`
	holder.AnchorPoint = Vector2.new(alignRight and 1 or 0, 0.5)
	holder.Position = UDim2.new(0.5, alignRight and -34 or 34, 0.5, 0)
	holder.Size = UDim2.new(0.5, -40, 1, 0)
	holder.BackgroundTransparency = 1
	holder.Parent = parent

	local name = centered(TextUtil.upper(team.name), UITheme.TextSizes.Small, color, UITheme.Fonts.Bold)
	name.Name = "Name"
	name.Size = UDim2.new(1, 0, 0, 18)
	name.Parent = holder

	local score = centered("0", UITheme.TextSizes.Display, UITheme.Colors.Text, UITheme.Fonts.Number)
	score.Name = "Score"
	score.Position = UDim2.new(0, 0, 0, 18)
	score.Size = UDim2.new(1, 0, 1, -18)
	score.Parent = holder
	scoreLabels[teamId] = score
end

local function build(gui: Instance)
	local overlay = Instance.new("Frame")
	overlay.Name = "Root"
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundColor3 = UITheme.Colors.Background
	overlay.BackgroundTransparency = 0.35
	overlay.BorderSizePixel = 0
	overlay.Visible = false
	overlay.Parent = gui
	root = trove:Add(overlay)

	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.45)
	card.Size = UDim2.fromScale(0.44, 0.46)
	card.BackgroundColor3 = UITheme.Colors.Panel
	card.BorderSizePixel = 0
	card.Parent = overlay
	UITheme.corner(UITheme.Radius.Large).Parent = card
	UITheme.stroke(UITheme.Colors.Accent, 2).Parent = card
	UITheme.padding(20, 18).Parent = card

	local constraint = Instance.new("UISizeConstraint")
	constraint.MinSize = Vector2.new(300, 240)
	constraint.MaxSize = Vector2.new(620, 400)
	constraint.Parent = card

	local title =
		centered("МАТЧ ОКОНЧЕН", UITheme.TextSizes.Display, UITheme.Colors.Text, UITheme.Fonts.Heading)
	title.Name = "Headline"
	title.Size = UDim2.new(1, 0, 0.2, 0)
	-- Shrinks to fit rather than cutting the end off. On a phone the card is
	-- 260 px across and "ПОРАЖЕНИЕ" at full size needs about 250: one word
	-- fits, but "ПОБЕДА — АЛЬФА" at full size needed 340 and read "ПОБЕДА —…",
	-- which is the one thing this screen exists to say, minus the part that
	-- says it.
	title.TextScaled = true
	local titleCap = Instance.new("UITextSizeConstraint")
	titleCap.MaxTextSize = UITheme.TextSizes.Display
	titleCap.MinTextSize = UITheme.TextSizes.Body
	titleCap.Parent = title
	title.Parent = card
	headline = title

	-- Who beat whom, or why the match ended early. Kept off the headline so the
	-- headline can stay one short word that fits a phone at full size.
	local reason = centered("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	reason.Name = "Subline"
	reason.Position = UDim2.fromScale(0, 0.2)
	reason.Size = UDim2.fromScale(1, 0.1)
	reason.Parent = card
	subline = reason

	local scores = Instance.new("Frame")
	scores.Name = "Scores"
	scores.Position = UDim2.fromScale(0, 0.32)
	scores.Size = UDim2.fromScale(1, 0.32)
	scores.BackgroundTransparency = 1
	scores.Parent = card

	buildScoreSide("A", true, scores)
	buildScoreSide("B", false, scores)

	local dash = centered("–", UITheme.TextSizes.Title, UITheme.Colors.TextMuted, UITheme.Fonts.Number)
	dash.Name = "Dash"
	dash.AnchorPoint = Vector2.new(0.5, 0.5)
	dash.Position = UDim2.fromScale(0.5, 0.5)
	dash.Size = UDim2.fromOffset(40, 40)
	dash.Parent = scores

	local reward = centered("", UITheme.TextSizes.Heading, UITheme.Colors.Coin, UITheme.Fonts.Bold)
	reward.Name = "Reward"
	reward.Position = UDim2.fromScale(0, 0.66)
	reward.Size = UDim2.fromScale(1, 0.16)
	reward.Parent = card
	rewardLabel = reward

	local countdown = centered("", UITheme.TextSizes.Small, UITheme.Colors.TextDim, UITheme.Fonts.Bold)
	countdown.Name = "Countdown"
	countdown.AnchorPoint = Vector2.new(0.5, 1)
	countdown.Position = UDim2.fromScale(0.5, 1)
	countdown.Size = UDim2.fromScale(1, 0.14)
	countdown.Parent = card
	countdownLabel = countdown
end

--------------------------------------------------------------------------------
-- Presentation
--------------------------------------------------------------------------------

--[[
	Did the player win, lose or draw. Decided from the team on record, so the
	headline can answer the question the player came to the screen with.

	A viewer on neither playing team (a spectator, or somebody the server has
	already moved) is "neutral": they get the winning team's name instead, since
	"you won" would be a claim about someone else.
]]
function ResultsScreen.outcomeFor(winnerTeam: string?, myTeam: string?): string
	if winnerTeam == nil then
		return "draw"
	end
	if myTeam ~= "A" and myTeam ~= "B" then
		return "neutral"
	end
	return if myTeam == winnerTeam then "win" else "loss"
end

local function teamName(teamId: string): string
	local team = Constants.TEAMS[teamId]
	return TextUtil.upper(team and team.name or teamId)
end

-- (headline, colour, line under it) for one outcome.
local function presentation(outcome: string, winnerTeam: string?, reason: string?): (string, Color3, string)
	-- Only a winner can have been left by the opponents; the other outcomes
	-- describe the scoreline as it stands.
	local forfeit = if reason == "forfeit" and outcome ~= "loss"
		then "СОПЕРНИКИ ПОКИНУЛИ МАТЧ"
		else nil

	if outcome == "win" then
		return "ПОБЕДА",
			UITheme.Colors.Positive,
			forfeit or `Победила команда {teamName(winnerTeam)}`
	elseif outcome == "loss" then
		return "ПОРАЖЕНИЕ", UITheme.Colors.Negative, `Победила команда {teamName(winnerTeam)}`
	elseif outcome == "draw" then
		return "НИЧЬЯ", UITheme.Colors.TextDim, "Счёт равный"
	end

	return `ПОБЕДА — {teamName(winnerTeam)}`, UITheme.teamColor(winnerTeam), forfeit or ""
end

--[[
	True when this client actually played the match that just ended. The server
	moves everyone back to the hub as part of the Results phase, so "am I still
	in a match" alone would flicker; a reward entry is the durable proof.
]]
local function wasParticipant(match): boolean
	local rewards = match.data and match.data.rewards
	if type(rewards) == "table" and rewards[tostring(player.UserId)] ~= nil then
		return true
	end
	return ClientState.getMapId() == match.mapId
end

local function show(match)
	if not root then
		return
	end

	local data = match.data or {}
	local scores = data.scores or match.scores or { A = 0, B = 0 }
	local outcome = ResultsScreen.outcomeFor(data.winnerTeam, ClientState.getTeamId())
	local text, color, detail = presentation(outcome, data.winnerTeam, data.reason)

	if headline then
		headline.Text = text
		headline.TextColor3 = color
	end
	if subline then
		subline.Text = detail
	end
	for _, teamId in Constants.TEAM_IDS do
		local label = scoreLabels[teamId]
		if label then
			label.Text = tostring(scores[teamId] or 0)
		end
	end

	-- String key: see MatchRuntime._endMatch for why a numeric one never arrives.
	local earned = type(data.rewards) == "table" and tonumber(data.rewards[tostring(player.UserId)]) or 0
	if rewardLabel then
		rewardLabel.Text = if earned > 0 then `+{earned} монет` else "Монет не начислено"
		rewardLabel.TextColor3 = if earned > 0 then UITheme.Colors.Coin else UITheme.Colors.TextMuted
	end

	shownAt = os.clock()
	lastCountdown = -1
	root.Visible = true
end

local function hide()
	if root then
		root.Visible = false
	end
	shownAt = 0
end

local function onMatchChanged(match)
	if match.phase ~= RESULTS_PHASE then
		if root and root.Visible then
			hide()
		end
		return
	end

	if root and root.Visible then
		return
	end
	if not wasParticipant(match) then
		return
	end

	show(match)
end

--[[
	One text write per second; the rest of the frames early-return.
]]
local function step()
	if not root or not root.Visible or not countdownLabel then
		return
	end

	local remaining = math.max(math.ceil(GameConfig.RESULTS_DURATION - (os.clock() - shownAt)), 0)
	if remaining == lastCountdown then
		return
	end

	lastCountdown = remaining
	countdownLabel.Text = if remaining > 0
		then `Возврат в хаб через {remaining}…`
		else "Возвращаемся в хаб…"
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function ResultsScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("Results", Constants.DISPLAY_ORDER.Results)
	if not gui then
		return
	end

	build(gui)

	trove:Add(ClientState.MatchChanged:Connect(onMatchChanged))
	trove:Connect(RunService.Heartbeat, step)

	onMatchChanged(ClientState.match)
end

function ResultsScreen.stop()
	trove:Clean()
	table.clear(scoreLabels)
	root = nil
	headline = nil
	subline = nil
	rewardLabel = nil
	countdownLabel = nil
end

return ResultsScreen
