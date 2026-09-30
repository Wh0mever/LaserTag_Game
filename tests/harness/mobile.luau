--!nonstrict
--[[
	tests/harness/mobile.luau
	Boots the whole client as a phone and asks what the player can actually do.

	Every other scenario runs on a simulated desktop, and until this existed that
	was the only machine this game had ever been executed on. Mobile shipped
	unobserved, and it showed: a phone kept StarterPlayer's LockFirstPerson and
	its 0.5 zoom for the entire session, because MouseLockController took a touch
	early return before it applied the perspective or subscribed to changes in
	it. Third person — the view the game defaults to — did not exist on mobile at
	all, and the touch VIEW button flipped the stored preference and saved it to
	the profile while the camera never moved.

	None of that was catchable before, for a duller reason than it sounds: the
	sandbox's local player had stub attributes. GetAttribute always returned nil
	and SetAttribute did nothing, so the client could never be put into a match,
	and the touch buttons only exist during one. tests/harness/env.luau now keeps
	attributes for real and fires their changed signals.

	So the checks here are deliberately written as capability — press this, does
	the game do the thing — rather than as "was the right function called". The
	mobile bugs all passed a "was it called" reading.

	Run:  lune run tests/harness/mobile
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

--------------------------------------------------------------------------------
-- Reporting
--------------------------------------------------------------------------------

local passed = 0
local failed = 0
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

--------------------------------------------------------------------------------
-- Boot the client as a phone
--------------------------------------------------------------------------------

heading("Booting a phone")

Env.setDevice("phone")
Env.enableClientRuntime()

--[[
	A phone's actual Roblox viewport, which is NOT its screen in pixels.

	The device that produced the screenshots reports about 640x294 here while its
	screen is 1280x588 — Roblox halves it for the display's pixel ratio. Sizing
	the controls in flat pixels taken off a screenshot therefore made everything
	roughly double: a "128 pixel" button covered a fifth of the view. The default
	sandbox viewport is a 1920x1080 monitor, which would hide exactly that class
	of mistake, so this scenario runs on the small one.
]]
local camera = Env.service("Workspace").CurrentCamera
camera.ViewportSize = roblox.Vector2.new(640, 294)

local ClientState = Env.load("src/client/ClientState")
local InputController = Env.load("src/client/Controllers/InputController")
local PerspectiveController = Env.load("src/client/Controllers/PerspectiveController")
local SettingsController = Env.load("src/client/Controllers/SettingsController")
local MouseLockController = Env.load("src/client/Controllers/MouseLockController")
local MobileControls = Env.load("src/client/Controllers/MobileControlsController")
local UIController = Env.load("src/client/UI/UIController")

local player = Env.service("Players").LocalPlayer

-- Priority order, as the real Loader would run them.
local CONTROLLERS = {
	{ name = "ClientState", module = ClientState },
	{ name = "InputController", module = InputController },
	{ name = "PerspectiveController", module = PerspectiveController },
	{ name = "SettingsController", module = SettingsController },
	{ name = "MouseLockController", module = MouseLockController },
	{ name = "MobileControlsController", module = MobileControls },
}

for _, entry in CONTROLLERS do
	if type(entry.module.init) == "function" then
		local ok, err = pcall(entry.module.init)
		check(ok, `{entry.name} initialises on a phone: {tostring(err)}`)
	end
end
print(`  {#CONTROLLERS} controllers initialised`)

--------------------------------------------------------------------------------
-- The device is what we think it is
--------------------------------------------------------------------------------

heading("Device")

check(ClientState.isTouch, "the client knows it is a touch device")
check(not MouseLockController.isEnabled(), "no cursor is managed on a phone")
check(MobileControls.isActive(), "the touch controls are active")

--------------------------------------------------------------------------------
-- The camera
--
-- StarterPlayer ships CameraMode LockFirstPerson with both zoom distances at
-- 0.5. Anything that fails to overwrite all three leaves the player welded into
-- first person, so these read the properties rather than asking a controller
-- what it believes it did.
--------------------------------------------------------------------------------

heading("Camera")

local function cameraState(): string
	return `mode={tostring(player.CameraMode)} zoom={tostring(player.CameraMinZoomDistance)}`
		.. `..{tostring(player.CameraMaxZoomDistance)}`
end

check(
	PerspectiveController.get() == PerspectiveController.THIRD,
	`a phone starts in the configured default perspective (got {PerspectiveController.get()})`
)
check(
	player.CameraMaxZoomDistance == PerspectiveController.THIRD_ZOOM,
	`the camera is actually pulled back on boot, not just intended to be ({cameraState()})`
)
check(
	player.CameraMode == roblox.Enum.CameraMode.Classic,
	`third person means CameraMode Classic, not LockFirstPerson ({cameraState()})`
)

--------------------------------------------------------------------------------
-- In a match
--------------------------------------------------------------------------------

heading("Entering a match")

player:SetAttribute("InMatch", "Dust")
check(ClientState.isInMatch(), "setting the InMatch attribute puts the client in a match")
check(MobileControls.areButtonsBound(), "the touch buttons appear when the match starts")

-- A phone has a touchscreen and nothing else, so what the "last input" was
-- (the engine can report a stray mouse-type event from a paired accessory) never
-- takes its fire control away.
Env.setLastInputType("MouseMovement")
check(MobileControls.areButtonsBound(), "a phone keeps its controls whatever it last reported")
Env.setLastInputType("Touch")

local controls = MobileControls.controls()

-- The three tap controls are real buttons, so a tap is their Activated event.
local function tap(id: string)
	local node = controls[id] :: any
	if node then
		node.Activated:Fire()
	end
end

for _, id in { "Fire", "Reload", "Switch", "View" } do
	check(controls[id] ~= nil, `a phone gets a {id} control`)
end

--[[
	The controls are drawn, not written.

	Roblox has no vector format, and this game ships no image assets on purpose,
	so an icon here is geometry: a handful of Frames. Asserting the pieces exist
	matters because the failure mode of "replace the label with an icon" is a
	circle with nothing in it at all — which looks identical to a button whose
	text was deleted and never replaced.
]]
for _, id in { "Fire", "Reload", "Switch", "View" } do
	local node = controls[id]
	if node then
		local icon = node:FindFirstChild("Icon")
		check(icon ~= nil, `{id} has an icon`)
		if icon then
			check(#icon:GetChildren() >= 2, `{id}'s icon is actually drawn ({#icon:GetChildren()} pieces)`)
		end

		local words = nil
		for _, descendant in node:GetDescendants() do
			if descendant:IsA("TextLabel") and descendant.Text ~= "" then
				words = descendant.Text
			end
		end
		check(words == nil, `{id} carries no text (found {tostring(words)})`)
	end
end

--------------------------------------------------------------------------------
-- The aiming rule
--
-- This is the one that decides whether the game is playable. On a phone you aim
-- by dragging, and Roblox's camera only receives a drag no GUI has consumed. A
-- GuiButton consumes the touch that lands on it, so a fire BUTTON means you can
-- shoot or aim, never both.
--------------------------------------------------------------------------------

local fire = controls.Fire
if fire then
	check(not fire.Active, "the fire control does not consume its touch, so the camera still gets the drag")
	check(
		not fire:IsA("GuiButton"),
		`the fire control is not a button (it is a {fire.ClassName}) — a button would eat the drag`
	)
end

for _, id in { "Reload", "Switch", "View" } do
	local node = controls[id]
	if node then
		check(node:IsA("GuiButton"), `{id} is a real button; it is a tap, nothing is being aimed`)
	end
end

-- Sizes and positions are fractions of the VIEWPORT, not flat pixels. A phone's
-- Roblox viewport is about half the screen's pixel width, so pixel offsets read
-- off a screenshot come out roughly double: that is how the controls ended up
-- enormous and sitting over the crosshair.
local VIEWPORT = { x = 640, y = 294 }
local U = VIEWPORT.y

local rects = {}
for _, id in { "Fire", "Reload", "Switch", "View" } do
	local node = controls[id]
	if node then
		-- AnchorPoint is centred, so the offsets ARE the centre.
		local cx = VIEWPORT.x + node.Position.X.Offset
		local cy = VIEWPORT.y + node.Position.Y.Offset
		local half = node.Size.X.Offset / 2
		rects[id] = { left = cx - half, top = cy - half, right = cx + half, bottom = cy + half }

		check(
			node.Size.X.Offset > 0 and node.Size.X.Offset == node.Size.Y.Offset,
			`{id} is a round control with a real size (got {node.Size.X.Offset})`
		)
		-- Smaller than the fire circle on purpose, never smaller than a thumb.
		check(node.Size.X.Offset >= 44, `{id} is at least 44 px across on this phone (got {node.Size.X.Offset})`)
		check(
			rects[id].left >= 0
				and rects[id].top >= 0
				and rects[id].right <= VIEWPORT.x
				and rects[id].bottom <= VIEWPORT.y,
			`{id} is fully on a {VIEWPORT.x}x{VIEWPORT.y} viewport `
				.. `(x {math.floor(rects[id].left)}..{math.floor(rects[id].right)}, `
				.. `y {math.floor(rects[id].top)}..{math.floor(rects[id].bottom)})`
		)
	end
end

-- The complaint that started this: the controls were in the middle of the
-- screen and huge. Both are now measurable rather than a matter of opinion.
for _, id in { "Fire", "Reload", "Switch", "View" } do
	local r = rects[id]
	if r then
		check(
			r.left > VIEWPORT.x * 0.6,
			`{id} sits well into the right-hand side, not across the middle `
				.. `(left edge at {math.floor(r.left)} of {VIEWPORT.x})`
		)
		check(
			(r.right - r.left) <= U * 0.22,
			`{id} is not enormous ({math.floor(r.right - r.left)}px on a {U}-tall viewport)`
		)
	end
end

--[[
	And it has to REACH the right edge, not merely start right of centre.

	The version before this cleared Roblox's jump button by putting everything to
	the left of it. Every control passed "in the right half" and the cluster still
	looked centred, because it stopped 355 screen pixels short of the edge and the
	empty strip was what the eye read. Clearing an obstacle by backing away from it
	is not the same as going around it, so the gap itself is now the assertion.
]]
local rightmost = 0
for _, id in { "Fire", "Reload", "Switch", "View" } do
	if rects[id] then
		rightmost = math.max(rightmost, rects[id].right)
	end
end
check(
	VIEWPORT.x - rightmost <= VIEWPORT.x * 0.15,
	`the cluster reaches the right edge rather than stopping short of it `
		.. `(gap {math.floor(VIEWPORT.x - rightmost)} of {VIEWPORT.x})`
)

local function overlaps(a, b): boolean
	return a.left < b.right and b.left < a.right and a.top < b.bottom and b.top < a.bottom
end

local names = { "Fire", "Reload", "Switch", "View" }
for i = 1, #names do
	for j = i + 1, #names do
		local a, b = rects[names[i]], rects[names[j]]
		if a and b then
			check(not overlaps(a, b), `{names[i]} and {names[j]} do not overlap`)
		end
	end
end

-- Roblox's own jump button, measured off a real phone and expressed in the same
-- viewport-relative units: ~0.16u across, centred 0.31u from the right edge and
-- 0.14u up from the bottom. It is not ours to move, so we keep out of its way.
local JUMP = {
	left = VIEWPORT.x - 0.39 * U,
	right = VIEWPORT.x - 0.22 * U,
	top = VIEWPORT.y - 0.22 * U,
	bottom = VIEWPORT.y - 0.05 * U,
}
for _, id in names do
	if rects[id] then
		check(not overlaps(rects[id], JUMP), `{id} keeps clear of Roblox's own jump button`)
	end
end

local fireSize = rects.Fire and (rects.Fire.right - rects.Fire.left) or 0
local viewSize = rects.View and (rects.View.right - rects.View.left) or 0
check(fireSize > viewSize, `fire is the biggest control (fire {math.floor(fireSize)}, view {math.floor(viewSize)})`)

--------------------------------------------------------------------------------
-- The buttons do what they are labelled
--------------------------------------------------------------------------------

heading("Pressing things")

-- Lune has no layout engine, so the control has to be placed before a touch can
-- be hit-tested against it. These are the numbers the real layout produces on
-- the phone-sized viewport used above.
if fire and rects.Fire then
	Env.placeGui(fire, rects.Fire.left, rects.Fire.top, 128, 128)
end

local centreX = (rects.Fire.left + rects.Fire.right) / 2
local centreY = (rects.Fire.top + rects.Fire.bottom) / 2

-- Held, not tapped: an automatic weapon whose trigger only registers on release
-- would pass a press-and-let-go check and be useless in a fight.
local touch = Env.touchBegan(centreX, centreY)
check(InputController.isFireHeld(), "a thumb on the fire control holds the trigger")
check(MobileControls.isTriggerHeld(), "the control owns that touch")

-- THE POINT OF ALL OF THIS. A second finger lifting elsewhere must not release
-- the trigger, and neither does the first one wandering off the control — that
-- is what aiming while firing looks like.
Env.touchEnded({ UserInputType = touch.UserInputType, Position = touch.Position })
check(InputController.isFireHeld(), "a DIFFERENT touch ending does not release the trigger")

Env.touchEnded(touch)
check(not InputController.isFireHeld(), "lifting the finger that pressed it releases the trigger")

-- A touch the engine reports as already consumed by a GuiButton is a tap on
-- reload, not on the trigger.
local consumed = Env.touchBegan(centreX, centreY, true)
check(not InputController.isFireHeld(), "a touch already consumed by a button does not fire")
Env.touchEnded(consumed)

-- And a touch nowhere near it does nothing, or the whole screen is a trigger.
local elsewhere = Env.touchBegan(40, 40)
check(not InputController.isFireHeld(), "a touch away from the control does not fire")
Env.touchEnded(elsewhere)

local reloadSeen = false
local reloadConn = InputController.ReloadPressed:Connect(function()
	reloadSeen = true
end)
tap("Reload")
check(reloadSeen, "the reload button asks for a reload")
reloadConn:Disconnect()

local slotSeen: number? = nil
local slotConn = InputController.SlotPressed:Connect(function(slot: number)
	slotSeen = slot
end)
tap("Switch")
check(
	slotSeen ~= nil and slotSeen ~= ClientState.currentSlot,
	`the switch button picks another slot (got {tostring(slotSeen)})`
)
slotConn:Disconnect()

--[[
	Two quick taps.

	The switch button used to compute the next slot from ClientState.currentSlot,
	which only moves when the server's answer arrives. A second tap inside that
	round trip therefore asked for the same slot as the first, the weapon client
	dropped it as "already holding that", and a player tapping twice for the lance
	got the pistol. Run against the real weapon client, with no server echo
	between the taps, because the echo is exactly what is missing.
]]
heading("Switching quickly")

local WeaponClient = Env.load("src/client/Controllers/WeaponClient")
local weaponInitOk, weaponInitErr = pcall(WeaponClient.init)
check(weaponInitOk, `the weapon client initialises on a phone: {tostring(weaponInitErr)}`)

if weaponInitOk then
	local body = roblox.Instance.new("Model")
	local bodyHumanoid = roblox.Instance.new("Humanoid")
	bodyHumanoid.MaxHealth = 100
	bodyHumanoid.Health = 100
	bodyHumanoid.Parent = body
	player.Character = body
	ClientState.isDead = false
	ClientState.match.phase = "InProgress"
	player:SetAttribute("CurrentWeapon", "Rifle")

	check(WeaponClient.getWeaponId() == "Rifle", "the rifle is in hand")
	tap("Switch")
	check(WeaponClient.getWeaponId() == "Pistol", `one tap goes to the pistol (holding {WeaponClient.getWeaponId()})`)
	check(ClientState.currentSlot == 1, "and the server has not answered yet")
	tap("Switch")
	check(
		WeaponClient.getWeaponId() == "Lance",
		`a second tap before the answer goes on to the lance (holding {WeaponClient.getWeaponId()})`
	)
	tap("Switch")
	check(
		WeaponClient.getWeaponId() == "Rifle",
		`and a third wraps round to the rifle (holding {WeaponClient.getWeaponId()})`
	)

	WeaponClient.stop()
	player.Character = nil
end

-- The one that was cosmetic. It flipped the saved preference and moved nothing,
-- so the stored setting disagreed with the screen and followed the player to
-- their desktop. Assert the camera, not the preference.
local beforeMode = player.CameraMode
local beforeZoom = player.CameraMaxZoomDistance
tap("View")
check(
	PerspectiveController.get() == PerspectiveController.FIRST,
	`the view button switches the perspective (got {PerspectiveController.get()})`
)
check(
	player.CameraMaxZoomDistance ~= beforeZoom,
	`the view button MOVES THE CAMERA, not just the setting ({cameraState()})`
)
check(
	player.CameraMode == roblox.Enum.CameraMode.LockFirstPerson,
	`first person on a phone means LockFirstPerson ({cameraState()})`
)
tap("View")
check(PerspectiveController.get() == PerspectiveController.THIRD, "the view button switches back")
check(
	player.CameraMode == beforeMode and player.CameraMaxZoomDistance == beforeZoom,
	`switching back restores the camera exactly ({cameraState()})`
)

--------------------------------------------------------------------------------
-- Recoil
--
-- Roblox exposes no sensitivity for the touch camera, so the only lever that
-- makes a phone easier to aim is the kick itself. Correcting recoil with a
-- thumb dragging across glass is far slower than with a wrist on a mouse, and
-- it is the same thumb holding the trigger.
--------------------------------------------------------------------------------

heading("Recoil")

local RecoilController = Env.load("src/client/Controllers/RecoilController")
local CameraController = Env.load("src/client/Controllers/CameraController")
local SprayPatterns = Env.load("src/shared/Config/SprayPatterns")

local recoilOk = pcall(function()
	CameraController.init()
	RecoilController.init()
end)
check(recoilOk, "the recoil and camera controllers initialise on a phone")

if recoilOk then
	local weaponId = "Rifle"
	local index = RecoilController.onShot(weaponId, 1000)
	local raw = SprayPatterns.getKick(weaponId, index)
	local pitch = select(1, CameraController.getRecoilOffset())

	check(
		math.abs(pitch) < math.abs(raw.pitch),
		`a phone gets less camera kick than the raw pattern `
			.. `(applied {string.format("%.3f", pitch)}, pattern {string.format("%.3f", raw.pitch)})`
	)
	-- Softened, not removed: recoil is still the thing you fight.
	check(
		math.abs(pitch) > math.abs(raw.pitch) * 0.4,
		`the kick is softened, not deleted (kept {string.format("%.0f", math.abs(pitch) / math.abs(raw.pitch) * 100)}%)`
	)
end

--------------------------------------------------------------------------------
-- Picking a side
--
-- The question has to actually arrive. A screen that is built correctly and
-- never opened is the same to the player as one that does not exist, and that
-- is the failure this whole scenario keeps being written to catch.
--------------------------------------------------------------------------------

heading("Pick a side")

local SideScreen = Env.load("src/client/UI/Screens/SideScreen")
local sideOk, sideErr = pcall(SideScreen.init)
check(sideOk, `the side picker initialises: {tostring(sideErr)}`)

if sideOk then
	local sides = SideScreen.buttons()
	for _, teamId in { "A", "B" } do
		check(sides[teamId] ~= nil, `the picker offers team {teamId}`)
	end

	-- It was already in a match before this screen existed, so re-enter to
	-- produce the transition the screen listens for.
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	check(SideScreen.isOpen(), "entering a match asks which side to play")

	-- And the touch controls must not sit on top of the question.
	check(not MobileControls.areButtonsBound(), "the fire control is hidden while the side question is on screen")

	player:SetAttribute("InMatch", "")
	check(not SideScreen.isOpen(), "leaving the match takes the question away")

	--[[
		THE ONE THAT MADE THE GAME LOOK BROKEN FOR THE FIRST MINUTE.

		A panel's own X button calls Panel:close() directly. UIController never
		hears about it, so MenuVisibilityChanged does not fire — and that signal
		is what puts the touch controls back and frees the mouse. Closing the
		side question with its X therefore left a phone player with NO fire
		button, until some unrelated menu happened to open and close and shook
		everything loose. Which is exactly what "the buttons show up after a
		minute" is.

		Worse on the side question than anywhere else, because in a small match
		the X is the only exit: a 1v1 refuses both sides by the balance rule, so
		there is no side to pick and no way forward except the button that broke
		everything.

		Asserted through the panel's own close, not UIController.closeMenu —
		testing the tidy path would have gone on passing throughout.
	]]
	player:SetAttribute("InMatch", "Dust")
	check(SideScreen.isOpen(), "the question is open again")
	check(not MobileControls.areButtonsBound(), "and the controls are hidden while it is")

	local sidePanel = SideScreen.panel()
	check(sidePanel ~= nil, "the side question exposes its panel")
	if sidePanel then
		sidePanel:close()
		check(not SideScreen.isOpen(), "the panel's own close shuts it")
		check(MobileControls.areButtonsBound(), "closing it with its OWN button hands the fire control back")
	end

	--[[
		And exactly once, either way round.

		The panel now reports every close, including the ones UIController asked
		for — so the tidy path had two mouths and one event. Firing "closed"
		twice is not harmless: everything listening does its restore work twice,
		and the second one lands after whatever opened next.
	]]
	local closeEvents = 0
	local counting = UIController.MenuVisibilityChanged:Connect(function(name: string, visible: boolean)
		if name == "Side" and not visible then
			closeEvents += 1
		end
	end)

	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	check(SideScreen.isOpen(), "the question opens for the counting pass")
	UIController.closeMenu("Side")
	check(closeEvents == 1, `closing through UIController reports it once, not twice (got {closeEvents})`)

	closeEvents = 0
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	local countingPanel = SideScreen.panel()
	if countingPanel then
		countingPanel:close()
	end
	check(closeEvents == 1, `closing with the panel's own button reports it once (got {closeEvents})`)
	counting:Disconnect()

	--[[
		THE OTHER HALF OF THE SAME REPORT.

		The balance rule refuses a move that would leave the sides more than one
		apart, and in a 1v1 — which is what nearly every match starts as, and
		exactly what the screenshot showed — that is BOTH sides. So the two team
		buttons were the whole screen and neither could be pressed. A question
		with no acceptable answer, over a match the player had just walked into.

		Two ways out, and both are checked here rather than assumed: a button
		that asks the server for nothing and so can never be refused, and a
		countdown that answers for a player who taps nothing at all.
	]]
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	check(SideScreen.isOpen(), "the question is open for the 1v1 case")

	local stayButton = SideScreen.stayButton()
	check(stayButton ~= nil, "there is a way out that is not the ✕")
	if stayButton then
		check(stayButton:isEnabled(), "and it is pressable")
		stayButton.instance.Activated:Fire()
		check(not SideScreen.isOpen(), "pressing it answers the question")
		check(MobileControls.areButtonsBound(), "and hands the fire control back")
	end

	--[[
		The countdown, stepped rather than slept through: Env.advance moves the
		harness clock and resumes whatever came due, so ten seconds of waiting
		is exercised in full and instantly.

		Both halves matter, and only asserting the second one is the feature. A
		countdown of zero would close the question too — on the frame it opened,
		which is a menu that flashes and a question nobody was asked. So the
		check is that it is STILL up after four seconds and gone after twelve.
	]]
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	check(SideScreen.isOpen(), "the question comes back for the next match")

	Env.advance(4)
	check(SideScreen.isOpen(), "four seconds in, the question is still there to be read")

	Env.advance(8)
	check(not SideScreen.isOpen(), "a player who taps nothing at all is let into the match anyway")
	check(MobileControls.areButtonsBound(), "and gets the fire control without having pressed anything")

	-- Back into a match, and past the question, for the sections below.
	player:SetAttribute("InMatch", "")
	player:SetAttribute("InMatch", "Dust")
	UIController.closeMenu("Side")
	check(MobileControls.areButtonsBound(), "closing the question hands the controls back")
end

--------------------------------------------------------------------------------
-- Controls get out of the way
--------------------------------------------------------------------------------

heading("Menus and match end")

local heldTouch = Env.touchBegan(centreX, centreY)
check(InputController.isFireHeld(), "trigger held before the menu opens")

-- A stand-in for a real screen: UIController only ever asks a handle whether it
-- is open, so this exercises the same path the shop does.
local shopOpen = false
UIController.registerMenu("Shop", {
	open = function()
		shopOpen = true
	end,
	close = function()
		shopOpen = false
	end,
	isOpen = function()
		return shopOpen
	end,
})

UIController.openMenu("Shop")
check(UIController.isAnyMenuOpen(), "the stand-in menu counts as open")
check(not MobileControls.areButtonsBound(), "the touch buttons go away while a menu is open")
check(
	not InputController.isFireHeld(),
	"the trigger is released when the buttons vanish, so the gun does not fire behind the shop"
)

UIController.closeMenu("Shop")
check(MobileControls.areButtonsBound(), "the touch buttons come back when the menu closes")

-- The finger that was down when the menu opened never got a touch-ended for the
-- control, because the control vanished underneath it. Lifting it now must not
-- resurrect a trigger nobody is holding.
Env.touchEnded(heldTouch)
check(not InputController.isFireHeld(), "lifting a finger stranded by the menu does not fire")

player:SetAttribute("InMatch", "")
check(not ClientState.isInMatch(), "clearing the attribute leaves the match")
check(not MobileControls.areButtonsBound(), "no fire button in the hub")

--------------------------------------------------------------------------------
-- The scoreboard on a phone
--
-- It opened on Tab and nothing else, so a phone player never saw it for a
-- whole match. Tapping the score at the top is the way in now.
--------------------------------------------------------------------------------

heading("Scoreboard on a phone")

local ScoreboardScreen = Env.load("src/client/UI/Screens/ScoreboardScreen")
local boardOk, boardErr = pcall(ScoreboardScreen.init)
check(boardOk, `the scoreboard initialises on a phone: {tostring(boardErr)}`)

player:SetAttribute("InMatch", "Dust")
UIController.closeMenu("Side")

-- The screen's content parent, not the ScreenGui: on a scaled screen the two
-- differ, and the widgets are in the first.
local boardGui = UIController.getScreenRoot("Scoreboard")
local scoreTap = boardGui and boardGui:FindFirstChild("ScoreTap")
local board = boardGui and boardGui:FindFirstChild("Board")
check(scoreTap ~= nil and scoreTap.Visible, "in a match the score at the top can be tapped")
if scoreTap and board then
	scoreTap.Activated:Fire()
	check(board.Visible, "tapping the score opens the scoreboard")
	scoreTap.Activated:Fire()
	check(not board.Visible, "tapping it again closes it")

	scoreTap.Activated:Fire()
	Env.advance(6)
	check(not board.Visible, "left alone, it closes itself — there is no key to let go of")

	player:SetAttribute("InMatch", "")
	check(not scoreTap.Visible, "in the hub there is nothing to tap: the board is for a match")
end

--------------------------------------------------------------------------------
-- The scoreboard with a full lobby
--
-- Rows were a plain Frame with no clipping and no cap. On a 640x294 phone the
-- board has room for four of them, so a 10v10 match drew the rest below the
-- panel, over the HUD and off the bottom of the screen, and the players at the
-- bottom of a list are the ones who most want to see where they stand.
--------------------------------------------------------------------------------

heading("Scoreboard with a full lobby")

do
	local PlayersService = Env.service("Players")
	local realGetPlayers = PlayersService.GetPlayers

	local function fakePlayer(name: string, team: string, kills: number)
		return {
			DisplayName = name,
			GetAttribute = function(_self, key: string)
				if key == "InMatch" then
					return "Dust"
				elseif key == "TeamId" then
					return team
				elseif key == "MatchKills" then
					return kills
				end
				return nil
			end,
		}
	end

	local function lobby(localKills: number)
		player:SetAttribute("InMatch", "Dust")
		-- Entering a match asks which side to take; the board waits for menus.
		UIController.closeMenu("Side")
		player:SetAttribute("TeamId", "A")
		player:SetAttribute("MatchKills", localKills)
		local roster = { player }
		for index = 1, 9 do
			table.insert(roster, fakePlayer(`Alpha{index}`, "A", index))
		end
		for index = 1, 10 do
			table.insert(roster, fakePlayer(`Bravo{index}`, "B", index))
		end
		PlayersService.GetPlayers = function()
			return roster
		end
	end

	local function rowsOf(teamId: string): any
		return board and board:FindFirstChild(teamId) and board[teamId]:FindFirstChild("Rows")
	end

	local function visibleRows(list: any): number
		local count = 0
		for _, row in list:GetChildren() do
			if row.Name == "Row" and row.Visible then
				count += 1
			end
		end
		return count
	end

	local function canvasTop(list: any): number
		local ok, position = pcall(function()
			return list.CanvasPosition.Y
		end)
		return if ok then position else -1
	end

	local step = 30 + 4 -- a row and the gap under it

	if board and scoreTap then
		-- The last place on the team: nine others out-kill the local player.
		lobby(0)
		player:SetAttribute("InMatch", "Dust")
		scoreTap.Activated:Fire()
		check(board.Visible, "the board opens for a full lobby")

		local listA, listB = rowsOf("A"), rowsOf("B")
		check(listA ~= nil and listB ~= nil, "both teams have a list of rows")
		if listA and listB then
			for name, list in { A = listA, B = listB } do
				check(list.ClassName == "ScrollingFrame", `team {name}'s rows scroll (they are a {list.ClassName})`)
				check(
					list.ClassName == "ScrollingFrame" and list.ScrollingDirection == roblox.Enum.ScrollingDirection.Y,
					`team {name}'s rows scroll vertically only`
				)
				check(
					list.ClassName == "ScrollingFrame" and list.AutomaticCanvasSize == roblox.Enum.AutomaticSize.Y,
					`team {name}'s canvas grows with its rows`
				)
			end
			check(board.ClipsDescendants, "nothing the board holds can be drawn outside it")

			check(visibleRows(listA) == 10, `all ten of team A are listed (got {visibleRows(listA)})`)
			check(visibleRows(listB) == 10, `all ten of team B are listed (got {visibleRows(listB)})`)

			-- The local player is 10th of 10; opening the board scrolls to them
			-- rather than leaving them below the fold.
			local expected = 9 * step * UIController.scale
			check(
				math.abs(canvasTop(listA) - expected) < 1,
				`the board scrolls to the local player's row (canvas at {canvasTop(listA)}, wanted {expected})`
			)
			check(canvasTop(listB) == 0, "and leaves the other team's list at the top")
		end

		scoreTap.Activated:Fire()
		check(not board.Visible, "tapping again closes it")

		-- First place: nothing to scroll to.
		lobby(50)
		scoreTap.Activated:Fire()
		local listA2 = rowsOf("A")
		check(listA2 ~= nil and canvasTop(listA2) == 0, "a player at the top of their team sees the top of the list")
		scoreTap.Activated:Fire()

		-- Far enough down to scroll, near enough that the row is on the first page.
		lobby(8)
		scoreTap.Activated:Fire()
		local listA3 = rowsOf("A")
		check(
			listA3 ~= nil and canvasTop(listA3) == 0,
			"a player who is on the first page of the list is not scrolled away from the top"
		)
		scoreTap.Activated:Fire()
	end

	PlayersService.GetPlayers = realGetPlayers
	player:SetAttribute("InMatch", "")
	player:SetAttribute("MatchKills", nil)
end

--------------------------------------------------------------------------------
-- The scoreboard does not sit on top of a menu
--
-- It draws above the menus (its ScreenGui outranks them), so a Tab held with the
-- shop open put the roster over the shop, and on a phone the tap zone over the
-- timer stayed live over every panel and opened it from the panel's title bar.
--------------------------------------------------------------------------------

heading("Scoreboard and menus")

if board and scoreTap then
	player:SetAttribute("InMatch", "Dust")
	UIController.closeMenu("Side")
	InputController.ScoreboardHeld:Fire(false)
	check(scoreTap.Visible, "in a match with nothing open the score can be tapped")

	UIController.openMenu("Shop")
	check(UIController.isAnyMenuOpen(), "the shop is open")
	check(not scoreTap.Visible, "with a menu open the tap zone is out of the way")

	scoreTap.Activated:Fire()
	check(not board.Visible, "a tap that arrives anyway does not draw the board on an open menu")
	InputController.ScoreboardHeld:Fire(true)
	check(not board.Visible, "and neither does Tab held over it")
	InputController.ScoreboardHeld:Fire(false)

	UIController.closeMenu("Shop")
	check(scoreTap.Visible, "closing the menu gives the score back its tap")
	InputController.ScoreboardHeld:Fire(true)
	check(board.Visible, "and Tab works again")
	InputController.ScoreboardHeld:Fire(false)
	check(not board.Visible, "letting go closes it")

	-- The other order was already right, and stays right.
	InputController.ScoreboardHeld:Fire(true)
	UIController.openMenu("Shop")
	check(not board.Visible, "a menu opening takes the board away")
	UIController.closeMenu("Shop")
	InputController.ScoreboardHeld:Fire(false)

	-- A panel that closes itself (its own X) says so through notifyClosed, not
	-- closeMenu; the tap zone has to come back for that path too.
	UIController.openMenu("Shop")
	shopOpen = false
	UIController.notifyClosed("Shop")
	check(scoreTap.Visible, "a menu that closed itself also gives the tap back")
end
player:SetAttribute("InMatch", "")

--------------------------------------------------------------------------------
-- A touchscreen laptop is not a phone
--
-- The device test is "touch AND no mouse", not "touch". Someone on a Surface or
-- a touchscreen MacBook has a cursor and expects to keep it; treating them as a
-- phone would take the mouse away from a player who is holding one. This is the
-- regression the phone work is most likely to cause, so it gets its own boot.
--------------------------------------------------------------------------------

heading("Touchscreen laptop")

Env.setDevice("touchLaptop")
Env.reset()

local laptopOk, laptopErr = pcall(function()
	Env.enableClientRuntime()
	local State = Env.load("src/client/ClientState")
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Settings = Env.load("src/client/Controllers/SettingsController")
	local MouseLock = Env.load("src/client/Controllers/MouseLockController")

	State.init()
	Perspective.init()
	Settings.init()
	MouseLock.init()

	check(State.isTouch, "a touchscreen laptop still reports touch")
	check(MouseLock.isEnabled(), "a touchscreen laptop keeps its cursor manager")

	--[[
		The same person sees the desktop chrome. ClientState.isTouch is plain
		TouchEnabled, which is true here, and the side buttons and the welcome
		card used to read it: no key badges, no cursor-release hint, a folded
		hamburger and a card describing a thumbstick, to someone holding a mouse
		and keyboard that the cursor manager above is already treating as one.
	]]
	check(type(State.isTouchOnly) == "function", "ClientState has one shared touch-only test")
	check(
		type(State.isTouchOnly) == "function" and not State.isTouchOnly(),
		"a touchscreen laptop is not a touch-only device"
	)

	local LaptopUI = Env.load("src/client/UI/UIController")
	LaptopUI.init()
	local LaptopSide = Env.load("src/client/UI/Screens/SideButtonsScreen")
	LaptopSide.init()
	local LaptopWelcome = Env.load("src/client/UI/Screens/WelcomeScreen")
	LaptopWelcome.init()
	local LaptopHUD = Env.load("src/client/UI/Screens/HUDScreen")
	LaptopHUD.init()

	-- The hotbar of the desktop HUD carries its key badges; the phone's, which
	-- has no keys to press, does not.
	local badges = 0
	for _, descendant in LaptopUI.getScreenRoot("HUD"):GetDescendants() do
		if descendant.Name == "KeyHint" then
			badges += 1
		end
	end
	check(badges > 0, "the laptop's hotbar carries key badges: it got the desktop HUD, not the phone's")

	local sideRoot = LaptopUI.getScreenRoot("SideButtons"):FindFirstChild("Root")
	local menu = sideRoot:FindFirstChild("Menu")
	local list = menu:FindFirstChild("Buttons")
	check(sideRoot:FindFirstChild("MouseHint").Visible, "the cursor-release hint is shown to a laptop")
	check(LaptopSide.isExpanded(), "the side stack starts open on a laptop")
	check(list.Visible, "and is on screen")
	check(list:FindFirstChild("Shop"):FindFirstChild("KeyHint") ~= nil, "the buttons carry their key badges")
	check(menu.AnchorPoint.Y == 0.5, "the stack is centred down the edge, not pinned to the corner")
	check(list.Size.X.Offset == list.Shop.Size.X.Offset, "and runs down the edge, not along it")

	local words = {}
	for _, descendant in LaptopUI.getScreenRoot("WelcomeMenu"):GetDescendants() do
		if descendant.ClassName == "TextLabel" then
			words[descendant.Text] = true
		end
	end
	check(words["W A S D  ·  Space"] == true, "the welcome card explains WASD to a laptop")
	check(words["Левый стик"] == nil, "and does not describe a thumbstick")

	-- Asked when used: a keyboard plugged into a tablet after boot changes the
	-- answer, and nothing cached the old one.
	local Input = Env.service("UserInputService")
	Input.TouchEnabled, Input.MouseEnabled, Input.KeyboardEnabled = true, false, false
	check(State.isTouchOnly(), "touch and nothing else is touch-only")
	Input.KeyboardEnabled = true
	check(not State.isTouchOnly(), "a keyboard makes it not touch-only, as soon as it is there")
	Input.KeyboardEnabled, Input.MouseEnabled = false, true
	check(not State.isTouchOnly(), "and so does a mouse")
end)
check(laptopOk, `the touchscreen laptop boots: {tostring(laptopErr)}`)

--------------------------------------------------------------------------------
-- A touchscreen laptop keeps the desktop's screen
--
-- It has a mouse and a keyboard, so the fire circle over the arena is for a
-- finger that has not touched the glass yet: the cluster waits for the first
-- touch and gives way again the moment a key or the mouse is used.
--------------------------------------------------------------------------------

heading("Touchscreen laptop: the fire cluster")

Env.setDevice("touchLaptop")
Env.reset()

local clusterOk, clusterErr = pcall(function()
	Env.enableClientRuntime()
	local State = Env.load("src/client/ClientState")
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Settings = Env.load("src/client/Controllers/SettingsController")
	local MouseLock = Env.load("src/client/Controllers/MouseLockController")

	State.init()
	Perspective.init()
	Settings.init()
	MouseLock.init()

	local Input = Env.load("src/client/Controllers/InputController")
	local UI = Env.load("src/client/UI/UIController")
	local Touch = Env.load("src/client/Controllers/MobileControlsController")
	Input.init()
	UI.init()
	Touch.init()
	local laptopPlayer = Env.service("Players").LocalPlayer
	laptopPlayer:SetAttribute("InMatch", "Dust")

	check(Touch.isActive(), "a touchscreen laptop can show touch controls")
	check(not Touch.isTouchInUse(), "but it starts as a desktop: nobody has touched the glass")
	check(not Touch.areButtonsBound(), "so the arena has no fire circles over it")

	Env.setLastInputType("Touch")
	check(Touch.isTouchInUse() and Touch.areButtonsBound(), "the first touch brings the cluster up")

	Env.setLastInputType("MouseMovement")
	check(not Touch.areButtonsBound(), "moving the mouse takes it away again")
	Env.setLastInputType("Touch")
	check(Touch.areButtonsBound(), "and touching the glass brings it back")
	Env.setLastInputType("Keyboard")
	check(not Touch.areButtonsBound(), "as does pressing a key")

	-- A trigger held on the glass must not outlive the controls that hold it.
	Env.setLastInputType("Touch")
	local laptopFire = Touch.controls().Fire
	Env.placeGui(laptopFire, 100, 100, 100, 100)
	local laptopTouch = Env.touchBegan(150, 150)
	check(Input.isFireHeld(), "a finger on the fire circle holds the trigger")
	Env.setLastInputType("MouseMovement")
	check(not Input.isFireHeld(), "switching to the mouse lets go of it")
	Env.touchEnded(laptopTouch)
end)
check(clusterOk, `the touchscreen laptop fire cluster runs: {tostring(clusterErr)}`)

--------------------------------------------------------------------------------
-- Facing on a phone
--
-- The body follows the camera in third person on every device, but a phone has
-- no cursor manager, so "a menu is open" has to come from the UI itself.
--------------------------------------------------------------------------------

heading("Facing on a phone")

Env.setDevice("phone")
Env.reset()

local facingOk, facingErr = pcall(function()
	Env.enableClientRuntime()
	local State = Env.load("src/client/ClientState")
	local Input = Env.load("src/client/Controllers/InputController")
	local Perspective = Env.load("src/client/Controllers/PerspectiveController")
	local Settings = Env.load("src/client/Controllers/SettingsController")
	local UI = Env.load("src/client/UI/UIController")
	local MouseLock = Env.load("src/client/Controllers/MouseLockController")
	local Animator = Env.load("src/client/Controllers/CharacterAnimator")

	local phonePlayer = Env.service("Players").LocalPlayer
	local body = roblox.Instance.new("Model")
	local humanoid = roblox.Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Sit = false
	humanoid.AutoRotate = true
	humanoid.Parent = body
	local root = roblox.Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Position = roblox.Vector3.new(0, 5, 0)
	root.Parent = body
	phonePlayer.Character = body

	State.init()
	Input.init()
	Perspective.init()
	Settings.init()
	UI.init()
	MouseLock.init()
	Animator.init()
	Animator.start()
	phonePlayer:SetAttribute("InMatch", "Dust")

	local phoneCamera = Env.service("Workspace").CurrentCamera
	local function look(yawDegrees: number)
		local yaw = math.rad(yawDegrees)
		local from = roblox.Vector3.new(0, 8, 0)
		phoneCamera.CFrame = roblox.CFrame.lookAt(from, from + roblox.Vector3.new(-math.sin(yaw), 0, -math.cos(yaw)))
	end
	local function facing(): number
		local a, b = root.CFrame.LookVector, phoneCamera.CFrame.LookVector
		return a.X * b.X + a.Z * b.Z
	end

	root.CFrame = roblox.CFrame.lookAt(roblox.Vector3.new(0, 5, 0), roblox.Vector3.new(5, 5, 0))
	look(0)
	for _ = 1, 3 do
		Env.stepRender()
	end
	check(facing() > 0.999, "a phone player's body turns to where the camera looks")
	check(not humanoid.AutoRotate, "and the humanoid stops turning to its walk")

	local open = false
	UI.registerMenu("Shop", {
		open = function()
			open = true
		end,
		close = function()
			open = false
		end,
		isOpen = function()
			return open
		end,
	})
	UI.openMenu("Shop")
	look(120)
	for _ = 1, 3 do
		Env.stepRender()
	end
	check(humanoid.AutoRotate, "with a menu open on a phone the humanoid is handed back")
	check(facing() < 0.5, "and the body is not spun round behind the menu")
	UI.closeMenu("Shop")
	Env.stepRender()
	check(facing() > 0.999, "closing it picks the aim up again")

	Animator.stop()
	check(humanoid.AutoRotate, "stopping hands the humanoid back")
end)
check(facingOk, `the phone facing scenario runs: {tostring(facingErr)}`)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

-- Spawned work runs on its own thread now, so a thread that dies takes its
-- timer or its poll with it and says nothing. This is where it says something.
check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} mobile check(s) failed`, 0)
end
print("  All mobile checks passed.")
