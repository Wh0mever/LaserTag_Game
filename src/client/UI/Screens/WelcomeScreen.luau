--!nonstrict
--[[
	WelcomeScreen.luau
	What the game is, shown once to a player who has never finished a match.

	Most of the hub already teaches itself: each portal carries a lit sign with
	the map name and "STAND ON THE PAD TO QUEUE", and that sign becomes the queue
	readout ("2/2 STARTING IN 8") while somebody is standing on it. The side
	buttons carry their own key hints. None of that needed a tutorial layered on
	top, and a modal that repeats what is already on screen is just a door to
	close before playing.

	Two things were genuinely missing, and they are the only things here:

	  * What the mode IS. Nothing in the world says "two teams, ten minutes, most
	    kills wins". A player could queue, fight and leave without ever learning
	    what decided the result.

	  * The controls, before the first fight rather than after it. They are
	    listed in the settings panel, but a new player has no reason to open
	    settings, and finding out that R reloads by dying with an empty magazine
	    is a bad first match.

	Shown when Stats.MatchesPlayed is 0, which needs no new profile field and no
	remote — the whole screen is client-side. A player who dismisses it and
	rejoins without having played sees it again, which is correct rather than a
	bug: they still have not played.

	Reopenable from the settings panel, since a card you can only ever see once
	is a card you cannot check back on.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local GameConfig = require(Shared.Config.GameConfig)
local Panel = require(script.Parent.Parent.Components.Panel)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local WelcomeScreen = {}
-- After the screens it may need to close over, and after ClientState has a
-- profile to read MatchesPlayed from.
WelcomeScreen.Priority = 36

local MENU_NAME = "Welcome"

-- Long enough that the hub has finished building and the profile has landed,
-- short enough that it is still the first thing a new player reads.
local OPEN_DELAY = 1.5

local trove = Trove.new()
local panel: any = nil
-- Type metrics. The card is the first thing a new player reads and it was set
-- in the two smallest sizes the theme has, so it read as fine print with half
-- the panel empty beneath it. Rows are derived from these so bigger text moves
-- the layout with it instead of overlapping.
local TITLE_HEIGHT = 22
local BODY_HEIGHT = 42
local CONTROL_ROW = 24
local LINE_HEIGHT = 1.12

local shownThisSession = false

--[[
	Body text is assembled from config rather than written out, so a retuned
	match length or a renamed weapon cannot leave this screen quietly lying to
	the one player who most needs it to be true.
]]
local function steps(): { { title: string, body: string } }
	local minutes = math.floor(GameConfig.MATCH_DURATION / 60)

	local weaponNames = {}
	for _, weaponId in WeaponConfig.Order do
		table.insert(weaponNames, WeaponConfig.Weapons[weaponId].displayName)
	end

	return {
		{
			title = "1  ·  ОЧЕРЕДЬ",
			body = "Встаньте на площадку портала в хабе. Табличка над ней показывает, сколько человек уже ждёт, и ведёт обратный отсчёт, когда матч собран.",
		},
		{
			title = "2  ·  БОЙ",
			body = `Две команды, {minutes} минут. Побеждает тот, у кого больше убийств к концу, — либо первая команда, набравшая цель по убийствам из HUD: тогда матч кончается досрочно. Возрождение через {Constants.RESPAWN_SECONDS} секунды после смерти.`,
		},
		{
			title = "3  ·  МОНЕТЫ",
			body = "Убийства и победы приносят монеты. Скины — только внешний вид: они никогда не меняют урон и точность.",
		},
		{
			title = "ОРУЖИЕ",
			body = `{weaponNames[1]}, {weaponNames[2]} и {weaponNames[3]}. Каждое убивает быстрее остальных на своей дистанции: пистолет — вплотную, винтовка — на средней, пика — вдоль длинного коридора. Вовремя переключиться важнее любого скина.`,
		},
	}
end

local function controlLines(): { { action: string, keys: string } }
	if ClientState.isTouch then
		return {
			{ action = "Движение", keys = "Левый стик" },
			{ action = "Обзор", keys = "Свайп по правой половине" },
			{ action = "Огонь", keys = "Кнопка огня" },
			{ action = "Перезарядка и смена", keys = "Кнопки рядом с огнём" },
			{ action = "Меню", keys = "Кнопки слева" },
			{ action = "Вид", keys = "Кнопка ВИД" },
		}
	end

	return {
		{ action = "Движение и прыжок", keys = "W A S D  ·  Space" },
		{ action = "Огонь", keys = "Левая кнопка мыши" },
		{ action = "Перезарядка", keys = Constants.KEYBINDS.Reload },
		{ action = "Смена оружия", keys = "1  2  3" },
		{ action = "Сменить вид", keys = Constants.KEYBINDS.Perspective },
		{ action = "Таблица счёта", keys = "Tab (удерживать)" },
		{ action = "Настройки", keys = Constants.KEYBINDS.Settings },
	}
end

local function buildStep(entry, order: number, parent: Instance)
	local root = Instance.new("Frame")
	root.Name = entry.title
	root.LayoutOrder = order
	root.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT + BODY_HEIGHT)
	root.AutomaticSize = Enum.AutomaticSize.Y
	root.BackgroundTransparency = 1
	root.ZIndex = 3
	root.Parent = parent

	local title = UITheme.label(entry.title, UITheme.TextSizes.Body, UITheme.Colors.Accent, UITheme.Fonts.Bold)
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
	title.ZIndex = 3
	title.Parent = root

	local body = UITheme.label(entry.body, UITheme.TextSizes.Body, UITheme.Colors.TextDim)
	body.Name = "Body"
	body.Position = UDim2.new(0, 0, 0, TITLE_HEIGHT)
	body.Size = UDim2.new(1, 0, 0, BODY_HEIGHT)
	body.LineHeight = LINE_HEIGHT
	body.TextWrapped = true
	body.TextYAlignment = Enum.TextYAlignment.Top
	body.AutomaticSize = Enum.AutomaticSize.Y
	body.ZIndex = 3
	body.Parent = root
end

local function buildControls(parent: Instance, order: number)
	local lines = controlLines()

	local root = Instance.new("Frame")
	root.Name = "Controls"
	root.LayoutOrder = order
	root.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT + #lines * CONTROL_ROW)
	root.BackgroundTransparency = 1
	root.ZIndex = 3
	root.Parent = parent

	local header =
		UITheme.label("УПРАВЛЕНИЕ", UITheme.TextSizes.Body, UITheme.Colors.Accent, UITheme.Fonts.Bold)
	header.Name = "Header"
	header.Size = UDim2.new(1, 0, 0, TITLE_HEIGHT)
	header.ZIndex = 3
	header.Parent = root

	for index, line in lines do
		local row = Instance.new("Frame")
		row.Name = line.action
		row.Position = UDim2.new(0, 0, 0, TITLE_HEIGHT + (index - 1) * CONTROL_ROW)
		row.Size = UDim2.new(1, 0, 0, CONTROL_ROW - 2)
		row.BackgroundTransparency = 1
		row.ZIndex = 3
		row.Parent = root

		local action = UITheme.label(line.action, UITheme.TextSizes.Small, UITheme.Colors.TextDim)
		action.Name = "Action"
		action.Size = UDim2.new(0.5, 0, 1, 0)
		action.ZIndex = 3
		action.Parent = row

		local keys = UITheme.label(line.keys, UITheme.TextSizes.Small, UITheme.Colors.Text, UITheme.Fonts.Number)
		keys.Name = "Keys"
		keys.AnchorPoint = Vector2.new(1, 0)
		keys.Position = UDim2.fromScale(1, 0)
		keys.Size = UDim2.new(0.5, 0, 1, 0)
		keys.TextXAlignment = Enum.TextXAlignment.Right
		keys.ZIndex = 3
		keys.Parent = row
	end
end

--[[
	Open it if this player has never finished a match.

	Guarded by `shownThisSession` as well as the stat: the profile can arrive
	more than once (a reconnect, a re-push), and a card that reopens itself while
	somebody is reading it is worse than one that never opened.
]]
local function maybeOpen()
	if shownThisSession or not panel then
		return
	end

	local played = ClientState.stats and ClientState.stats.MatchesPlayed
	if type(played) ~= "number" or played > 0 then
		return
	end

	shownThisSession = true
	task.delay(OPEN_DELAY, function()
		-- The player may have walked onto a pad in the meantime; dropping them
		-- into a menu at that point would be worse than never showing this.
		if panel and not ClientState.isInMatch() then
			UIController.openMenu(MENU_NAME)
		end
	end)
end

--[[
	Reopen on demand. The settings panel calls this, which is the only way back
	to a card that otherwise shows once and is gone.
]]
function WelcomeScreen.open()
	if panel then
		UIController.openMenu(MENU_NAME)
	end
end

function WelcomeScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("WelcomeMenu", Constants.DISPLAY_ORDER.Menu)
	if not gui then
		return
	end

	panel = Panel.create({
		title = "КАК ИГРАТЬ",
		-- The name goes in the subtitle rather than the title: a Panel title
		-- truncates at the end instead of shrinking, and on a phone this one is
		-- already close to its box. Replacing the old line keeps the length the
		-- same as what shipped, so nothing new can clip.
		subtitle = `{Constants.GAME_NAME} · за 30 секунд`,
		size = UDim2.fromScale(0.56, 0.78),
		parent = gui,
		accentColor = UITheme.Colors.Accent,
		closeOnOverlay = false,
	})
	trove:Add(function()
		panel:destroy()
	end)

	local body = Instance.new("ScrollingFrame")
	body.Name = "Steps"
	body.Size = UDim2.fromScale(1, 1)
	body.BackgroundTransparency = 1
	body.BorderSizePixel = 0
	body.ScrollBarThickness = 4
	body.ScrollBarImageColor3 = UITheme.Colors.Stroke
	body.ScrollingDirection = Enum.ScrollingDirection.Y
	body.CanvasSize = UDim2.new()
	body.AutomaticCanvasSize = Enum.AutomaticSize.Y
	body.ZIndex = 3
	body.Parent = panel.content

	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 18)
	layout.Parent = body

	local entries = steps()
	for index, entry in entries do
		buildStep(entry, index, body)
	end
	buildControls(body, #entries + 1)

	UIController.registerMenu(MENU_NAME, panel:asMenuHandle())
	-- Panel's own close paths bypass UIController, which owns the cursor lock.
	panel.closeButton:setOnActivated(function()
		UIController.closeMenu(MENU_NAME)
	end)
	local overlay = panel.instance:FindFirstChild("Overlay")
	if overlay then
		trove:Connect(overlay.Activated, function()
			UIController.closeMenu(MENU_NAME)
		end)
	end
	trove:Add(function()
		UIController.unregisterMenu(MENU_NAME)
	end)

	-- The profile lands after the client boots, so the decision to show this
	-- cannot be made here — it waits for the stats to arrive.
	trove:Add(ClientState.ProfileChanged:Connect(maybeOpen))
end

function WelcomeScreen.start()
	-- Covers the case where the profile arrived before this screen registered
	-- its listener.
	maybeOpen()
end

function WelcomeScreen.stop()
	trove:Clean()
	panel = nil
	shownThisSession = false
end

return WelcomeScreen
