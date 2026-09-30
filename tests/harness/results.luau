--!nonstrict
--[[
	tests/harness/results.luau
	What the end-of-match screen tells the player.

	The headline used to name the winning TEAM ("ПОБЕДА — БРАВО") and leave the
	player to work out whether that was them, and a match that ended because the
	other side left read "ПОБЕДА" over a scoreline the player was losing. The
	first thing a child looks for on this screen is whether THEY won.

	Run:  lune run tests/harness/results
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

local passed, failed = 0, 0
local failures: { string } = {}

local function check(ok: boolean, message: string)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, message)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

Env.setDevice("phone")
Env.enableClientRuntime()
Env.service("Workspace").CurrentCamera.ViewportSize = roblox.Vector2.new(640, 294)

local ClientState = Env.load("src/client/ClientState")
local ResultsScreen = Env.load("src/client/UI/Screens/ResultsScreen")
local UIController = Env.load("src/client/UI/UIController")
local UITheme = Env.load("src/client/UI/UITheme")

local player = Env.service("Players").LocalPlayer

ClientState.init()
UIController.init()
ResultsScreen.init()

local gui = UIController.getScreen("Results")
local root = gui and gui:FindFirstChild("Root")
local card = root and root:FindFirstChild("Card")
local headline = card and card:FindFirstChild("Headline")
local subline = card and card:FindFirstChild("Subline")

check(headline ~= nil, "the results card has a headline")
check(subline ~= nil, "and a line under it for the reason")

-- Show a Results screen for a player on `myTeam` when `data` is what the server
-- sent.
local function showResults(myTeam: string, data: { [string]: any })
	-- Leave and re-enter so a screen already showing does not swallow the next.
	ClientState.match.phase = "InProgress"
	ClientState.MatchChanged:Fire(ClientState.match)

	player:SetAttribute("TeamId", myTeam)
	player:SetAttribute("InMatch", "Dust")
	ClientState.match.mapId = "Dust"
	ClientState.match.phase = "Results"
	ClientState.match.data = data
	ClientState.MatchChanged:Fire(ClientState.match)
end

local function same(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) < 0.01 and math.abs(a.G - b.G) < 0.01 and math.abs(a.B - b.B) < 0.01
end

--------------------------------------------------------------------------------
-- Did I win
--------------------------------------------------------------------------------

heading("Headline")

if headline then
	local function under(): string
		return if subline then subline.Text else ""
	end

	showResults("A", { scores = { A = 23, B = 19 }, winnerTeam = "A", rewards = {} })
	check(root.Visible, "the screen opens for a participant")
	check(headline.Text == "ПОБЕДА", `the winner is told they won (got "{headline.Text}")`)
	check(same(headline.TextColor3, UITheme.Colors.Positive), "in green")
	check(
		under() == "Победила команда АЛЬФА",
		`and which team it was, under the headline (got "{under()}")`
	)

	showResults("B", { scores = { A = 23, B = 19 }, winnerTeam = "A", rewards = {} })
	check(headline.Text == "ПОРАЖЕНИЕ", `a player on the other team is told they lost (got "{headline.Text}")`)
	check(same(headline.TextColor3, UITheme.Colors.Negative), "in red")
	check(
		under() == "Победила команда АЛЬФА",
		`and who beat them, in capitals that survive Cyrillic (got "{under()}")`
	)

	showResults("B", { scores = { A = 19, B = 23 }, winnerTeam = "B", rewards = {} })
	check(headline.Text == "ПОБЕДА", "the same screen tells team B they won when they did")
	check(under() == "Победила команда БРАВО", `naming their own team (got "{under()}")`)

	showResults("A", { scores = { A = 20, B = 20 }, winnerTeam = nil, rewards = {} })
	check(headline.Text == "НИЧЬЯ", `a level match is a draw for everyone (got "{headline.Text}")`)
	check(same(headline.TextColor3, UITheme.Colors.TextDim), "in a neutral colour")
	check(under() ~= "" and not string.find(under(), "Победила", 1, true), "and does not name a winner")

	showResults("A", { scores = { A = 3, B = 9 }, winnerTeam = "A", rewards = {}, reason = "forfeit" })
	check(headline.Text == "ПОБЕДА", "a forfeit is still a win")
	check(
		under() == "СОПЕРНИКИ ПОКИНУЛИ МАТЧ",
		`and says why the scoreline disagrees with it (got "{under()}")`
	)

	-- Someone whose team is not one of the two (a spectator, or a player the
	-- server has already moved) still gets a sensible screen, not an error.
	showResults("LOBBY", { scores = { A = 23, B = 19 }, winnerTeam = "A", rewards = {} })
	check(headline.Text ~= "" and root.Visible, `a viewer on no team still sees who won (got "{headline.Text}")`)
	check(string.find(headline.Text, "АЛЬФА", 1, true) ~= nil, "by team name")
end

--------------------------------------------------------------------------------
-- The phone
--------------------------------------------------------------------------------

heading("Phone")

if headline then
	check(headline.TextScaled, "the headline shrinks to fit rather than being cut off")
	local cap = headline:FindFirstChildOfClass("UITextSizeConstraint")
	check(cap ~= nil and cap.MaxTextSize <= UITheme.TextSizes.Display, "and is capped at display size")
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} results check(s) failed`, 0)
end
print("  All results checks passed.")
