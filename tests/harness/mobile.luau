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
end)
check(laptopOk, `the touchscreen laptop boots: {tostring(laptopErr)}`)

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
