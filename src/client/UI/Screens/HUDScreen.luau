--!nonstrict
--[[
	HUDScreen.luau
	The in-match heads-up display: match timer, the two team score chips, health,
	the ammo counter, the crosshair and the two-slot hotbar.

	The widgets themselves are built once by HUDWidgets; this file only ever
	writes Text/Size/Color on what came back. Nothing here creates an Instance
	from a per-frame callback — the RenderStepped binding below moves four
	crosshair bars and nothing else.

	State comes from ClientState Signals (MatchChanged, AmmoChanged, SlotChanged,
	AttributeChanged). The one exception is health, which is a Humanoid property
	rather than a remote, so it is read from the character.

	The hotbar publishes InputController.SlotPressed rather than calling
	WeaponClient: a tap and the "1" key then travel the exact same path, and the
	HUD keeps no opinion about whether the swap was allowed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local HUDWidgets = require(script.Parent.HUDWidgets)
local InputController = require(script.Parent.Parent.Parent.Controllers.InputController)
local MathUtil = require(Shared.Util.MathUtil)
local RecoilController = require(script.Parent.Parent.Parent.Controllers.RecoilController)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UIController)
local UITheme = require(script.Parent.Parent.UITheme)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local HUDScreen = {}
-- After UIController (1); the HUD exposes no API other screens need at init.
HUDScreen.Priority = 20

local CROSSHAIR_MIN_GAP = 4
local CROSSHAIR_MAX_GAP = 30
-- How much of the accumulated camera kick feeds the bloom. The kick is already a
-- camera rotation the player can see; the crosshair only hints at it.
local RECOIL_BLOOM_WEIGHT = 0.45
local HEALTH_LOW = 0.3
local HEALTH_MEDIUM = 0.6

local player = Players.LocalPlayer
local trove = Trove.new()
local characterTrove = Trove.new()
local widgets: any = nil

--------------------------------------------------------------------------------
-- Updates
--------------------------------------------------------------------------------

local function formatClock(seconds: number): string
	local whole = math.max(math.floor(seconds), 0)
	return string.format("%d:%02d", math.floor(whole / 60), whole % 60)
end

local function refreshVisibility()
	if not widgets then
		return
	end

	widgets.root.Visible = ClientState.isInMatch()
	-- The death camera has its own overlay; a crosshair floating over it would
	-- suggest the player can still shoot.
	widgets.crosshair.Visible = not ClientState.isDead
end

local function onMatchChanged(match)
	if not widgets then
		return
	end

	widgets.timer.Text = formatClock(match.timeLeft or 0)
	for _, teamId in Constants.TEAM_IDS do
		local label = widgets.scores[teamId]
		if label then
			label.Text = tostring(match.scores and match.scores[teamId] or 0)
		end
	end

	-- The target arrives on the phase broadcast and survives the 1 Hz ticks,
	-- which only carry the scores. It rises as the lobby fills, so it is read
	-- every time rather than latched on the first InProgress.
	local target = widgets.scoreTarget
	if target then
		local limit = match.data and match.data.scoreLimit
		local live = match.phase == "InProgress" and type(limit) == "number" and limit > 0
		target.Visible = live
		if live then
			target.Text = `ДО {limit} УБИЙСТВ`
		end
	end
end

local function onAmmoChanged(ammo)
	if not widgets or type(ammo) ~= "table" then
		return
	end

	local weapon = WeaponConfig.get(ammo.weaponId)
	widgets.ammoWeapon.Text = weapon and weapon.displayName or tostring(ammo.weaponId)
	widgets.ammoMag.Text = tostring(ammo.mag or 0)
	widgets.ammoSize.Text = `/{ammo.magSize or 0}`

	-- Reloading dims the counter rather than replacing it with a word: the player
	-- still needs to read the magazine that is coming back.
	local dim = ammo.reloading == true
	widgets.ammoMag.TextTransparency = dim and 0.55 or 0
	widgets.ammoSize.TextTransparency = dim and 0.55 or 0
	widgets.ammoWeapon.TextColor3 = dim and UITheme.Colors.Warning or UITheme.Colors.TextDim
end

local function onSlotChanged(slot: number)
	if not widgets then
		return
	end

	for index, button in widgets.slots do
		local active = index == slot
		button:setColor(active and UITheme.Colors.Accent or UITheme.Colors.PanelLight)
		button.label.TextColor3 = active and UITheme.Colors.PanelDark or UITheme.Colors.Text
	end
end

--------------------------------------------------------------------------------
-- Health
--------------------------------------------------------------------------------

local function healthColor(fraction: number): Color3
	if fraction > HEALTH_MEDIUM then
		return UITheme.Colors.Positive
	elseif fraction > HEALTH_LOW then
		local alpha = (fraction - HEALTH_LOW) / (HEALTH_MEDIUM - HEALTH_LOW)
		return UITheme.Colors.Warning:Lerp(UITheme.Colors.Positive, alpha)
	end
	return UITheme.Colors.Negative:Lerp(UITheme.Colors.Warning, fraction / HEALTH_LOW)
end

local function setHealth(current: number, maximum: number)
	if not widgets then
		return
	end

	local fraction = MathUtil.clamp(maximum > 0 and current / maximum or 0, 0, 1)
	widgets.healthLabel.Text = tostring(math.max(math.ceil(current), 0))
	TweenService:Create(widgets.healthFill, UITheme.Tween.Fast, {
		Size = UDim2.fromScale(fraction, 1),
		BackgroundColor3 = healthColor(fraction),
	}):Play()
end

--[[
	Rebinds the health readout to a new character. Called from CharacterAdded and
	from start(), both of which are allowed to yield on the WaitForChild.
]]
local function bindCharacter(character: Model?)
	characterTrove:Clean()
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		humanoid = character:WaitForChild("Humanoid", 5)
	end
	if not humanoid then
		return
	end

	setHealth(humanoid.Health, humanoid.MaxHealth)
	characterTrove:Connect(humanoid.HealthChanged, function(health: number)
		setHealth(health, humanoid.MaxHealth)
	end)
	characterTrove:Connect(humanoid:GetPropertyChangedSignal("MaxHealth"), function()
		setHealth(humanoid.Health, humanoid.MaxHealth)
	end)
end

--------------------------------------------------------------------------------
-- Crosshair
--------------------------------------------------------------------------------

--[[
	Moves the four crosshair bars. Runs every rendered frame and allocates
	nothing: the bars were built once and only their Position is written.

	The bars spread, they do not shift. The accumulated recoil is already a
	camera rotation, so the screen centre still IS where the shot goes — sliding
	the crosshair off centre would lie about the aim point. It widens instead,
	which is the honest reading of "this burst is less accurate now".
]]
local function updateCrosshair()
	local camera = workspace.CurrentCamera
	if not camera or not widgets or not widgets.root.Visible then
		return
	end

	local weaponId = ClientState.ammo.weaponId or Constants.SLOTS[Constants.DEFAULT_SLOT]
	local pitch, yaw = RecoilController.getOffset()
	local kick = math.sqrt(pitch * pitch + yaw * yaw) * RECOIL_BLOOM_WEIGHT
	local spreadDeg = RecoilController.getBloomDeg(weaponId) + kick

	-- Degrees of cone -> pixels on this viewport, through the camera's focal
	-- length, so the same spread reads the same on any screen or field of view.
	local focal = (camera.ViewportSize.Y * 0.5) / math.tan(math.rad(camera.FieldOfView * 0.5))
	local gap =
		MathUtil.clamp(CROSSHAIR_MIN_GAP + focal * math.tan(math.rad(spreadDeg)), CROSSHAIR_MIN_GAP, CROSSHAIR_MAX_GAP)

	for _, entry in widgets.crosshairBars do
		entry.bar.Position = UDim2.new(0.5, entry.dx * gap, 0.5, entry.dy * gap)
	end
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

function HUDScreen.init()
	ClientState.init()

	local gui = UIController.getScreenGui("HUD", Constants.DISPLAY_ORDER.HUD)
	if not gui then
		return
	end

	widgets = HUDWidgets.build(gui, function(slot: number)
		-- The same intent the number keys publish; WeaponClient decides whether
		-- the swap is allowed.
		InputController.SlotPressed:Fire(slot)
	end)
	trove:Add(function()
		widgets.destroy()
	end)

	trove:Add(ClientState.MatchChanged:Connect(onMatchChanged))
	trove:Add(ClientState.AmmoChanged:Connect(onAmmoChanged))
	trove:Add(ClientState.SlotChanged:Connect(onSlotChanged))
	trove:Add(ClientState.Died:Connect(refreshVisibility))
	trove:Add(ClientState.Respawned:Connect(function()
		refreshVisibility()
		bindCharacter(player.Character)
	end))
	trove:Add(ClientState.AttributeChanged:Connect(function(name: string)
		if name == "InMatch" then
			refreshVisibility()
		end
	end))

	trove:Connect(player.CharacterAdded, bindCharacter)
	trove:Connect(player.CharacterRemoving, function()
		characterTrove:Clean()
	end)
	trove:Add(characterTrove)

	trove:Connect(RunService.RenderStepped, updateCrosshair)

	onAmmoChanged(ClientState.ammo)
	onSlotChanged(ClientState.currentSlot)
	onMatchChanged(ClientState.match)
	refreshVisibility()
end

function HUDScreen.start()
	-- bindCharacter may WaitForChild, so the first bind waits for start().
	bindCharacter(player.Character)
end

function HUDScreen.stop()
	trove:Clean()
	widgets = nil
end

return HUDScreen
