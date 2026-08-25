--!nonstrict
--[[
	WeaponClient.luau
	The firing loop and the client's prediction of it.

	Prediction, not authority. Every trigger pull does two things at once: it
	sends a ShootRequest carrying the camera's position and look vector, and it
	plays the whole local feedback stack — beam, muzzle flash, recoil, sound —
	without waiting for a reply. The server's answer (HitConfirmed) only ever
	*adds* the hitmarker and the damage number; it never has to arrive for the
	shot to feel like it happened. That is the entire reason a 90 ms ping is
	playable.

	The magazine is predicted the same way and corrected by AmmoSync, which is
	the server's WeaponState speaking. The one subtlety is ordering: a sync that
	left the server before our most recent shots arrived would visibly hand
	rounds back. Each sync therefore carries the last shot it accounts for, and a
	count HIGHER than ours is accepted as soon as that reaches the last shot we
	sent — at that point nothing is in flight, so the server is correcting a shot
	it refused rather than lagging behind. Until then the higher count waits out
	a short grace. A LOWER count is always accepted immediately.

	`seq` is a strictly increasing per-shot counter. Combat/ShootValidation drops
	any ShootRequest whose seq is not above the last one it accepted, so a packet
	captured off the wire is worthless the moment its shot has been processed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local ClientState = require(script.Parent.Parent.ClientState)
local Constants = require(Shared.Constants)
local InputController = require(script.Parent.InputController)
local RecoilController = require(script.Parent.RecoilController)
local RemoteNames = require(Shared.RemoteNames)
local Signal = require(Shared.Util.Signal)
local Trove = require(Shared.Util.Trove)
local UIController = require(script.Parent.Parent.UI.UIController)
local VFXController = require(script.Parent.VFXController)
local ViewmodelController = require(script.Parent.ViewmodelController)
local WeaponConfig = require(Shared.Config.WeaponConfig)

local WeaponClient = {}
-- After VFXController (8), whose shot feedback this module drives.
WeaponClient.Priority = 9

-- How long a weapon swap locks out firing. Matches ViewmodelController's raise
-- animation so the gun is fireable exactly when it finishes coming up.
local SWITCH_TIME = 0.35

-- How long after a local shot a HIGHER server magazine count is treated as
-- stale. Roughly one generous round trip: long enough that a burst never sees
-- its own rounds handed back, short enough that a genuine correction (a shot
-- the server refused) lands within a frame or two of the player noticing.
local RECONCILE_GRACE = 0.35

-- Rate limit for the empty-magazine click so holding the trigger on an empty
-- gun does not machine-gun the sound.
local EMPTY_CLICK_INTERVAL = 0.35

local NEVER = -math.huge

local player = Players.LocalPlayer
local trove = Trove.new()

-- weaponId -> predicted state. magSize is seeded from config and replaced by
-- whatever the server reports.
local predicted: { [string]: { mag: number, magSize: number, reloading: boolean, reloadUntil: number, lastShotAt: number } } =
	{}

local currentWeaponId = Constants.SLOTS[Constants.DEFAULT_SLOT]
local seq = 0
local switchUntil = 0
local lastLocalShotAt = NEVER
local lastEmptyClickAt = NEVER

local shootRemote: RemoteEvent? = nil
local reloadRemote: RemoteEvent? = nil
local equipRemote: RemoteEvent? = nil

-- Ammo tables this module put into ClientState. ClientState re-fires
-- AmmoChanged for both server syncs and our own writes, so without this the
-- reconcile handler would immediately re-consume its own publication. Weak keys
-- so a superseded table is still collectable.
local locallyPublished: { [any]: boolean } = setmetatable({}, { __mode = "k" })

-- (weaponId) whenever the gun in hand actually changes, from either the local
-- prediction or the server's CurrentWeapon attribute.
WeaponClient.WeaponChanged = Signal.new()
-- (weaponId, origin, direction, shotIndex) for every shot this client fires.
WeaponClient.Fired = Signal.new()

--------------------------------------------------------------------------------
-- Predicted state
--------------------------------------------------------------------------------

local function stateFor(weaponId: string)
	local state = predicted[weaponId]
	if not state then
		local weapon = WeaponConfig.get(weaponId)
		state = {
			mag = if weapon then weapon.magSize else 0,
			magSize = if weapon then weapon.magSize else 0,
			reloading = false,
			reloadUntil = 0,
			lastShotAt = NEVER,
		}
		predicted[weaponId] = state
	end
	return state
end

local function publish()
	local state = stateFor(currentWeaponId)
	local ammo = {
		weaponId = currentWeaponId,
		mag = state.mag,
		magSize = state.magSize,
		reloading = state.reloading,
	}

	locallyPublished[ammo] = true
	ClientState.ammo = ammo
	ClientState.AmmoChanged:Fire(ammo)
end

--------------------------------------------------------------------------------
-- Gating
--------------------------------------------------------------------------------

local function isAlive(): boolean
	if ClientState.isDead then
		return false
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[
	Whether the weapon may be used at all: alive, in a match, no menu on screen.
	MouseLockController already suppresses fire input while a menu is open, but
	it is disabled entirely on touch-only devices, so the menu test is repeated
	here rather than assumed.
]]
local function canAct(): boolean
	return isAlive() and ClientState.isInMatch() and not UIController.isAnyMenuOpen()
end

function WeaponClient.canFire(): boolean
	if not canAct() or os.clock() < switchUntil then
		return false
	end
	return not stateFor(currentWeaponId).reloading
end

--------------------------------------------------------------------------------
-- Reload
--------------------------------------------------------------------------------

--[[
	Start a reload. Refused for exactly the reasons the server refuses one
	(WeaponState.beginReload) so a refusal never leaves the HUD spinning on a
	reload that is not happening.
]]
function WeaponClient.reload(): boolean
	local weapon = WeaponConfig.get(currentWeaponId)
	local state = stateFor(currentWeaponId)
	if not weapon or state.reloading or state.mag >= state.magSize or not canAct() then
		return false
	end

	local now = os.clock()
	state.reloading = true
	state.reloadUntil = now + weapon.reloadTime

	if reloadRemote then
		reloadRemote:FireServer(currentWeaponId)
	end

	ViewmodelController.playReload(weapon.reloadTime)
	VFXController.playReloadSound()
	publish()
	return true
end

--------------------------------------------------------------------------------
-- Firing
--------------------------------------------------------------------------------

local function tryFire(now: number)
	local weapon = WeaponConfig.get(currentWeaponId)
	if not weapon or not WeaponClient.canFire() then
		return
	end

	local state = stateFor(currentWeaponId)
	if state.mag <= 0 then
		if now - lastEmptyClickAt >= EMPTY_CLICK_INTERVAL then
			lastEmptyClickAt = now
			VFXController.playEmptySound()
		end
		WeaponClient.reload()
		return
	end

	-- The client gates on the exact fire rate while the server allows a small
	-- grace on top (WeaponState.FIRE_RATE_GRACE), so an honest client is never
	-- the one whose shot gets dropped for arriving early.
	if now - state.lastShotAt < weapon.fireRate then
		return
	end

	local camera = workspace.CurrentCamera
	if not camera then
		return
	end

	local cameraCF = camera.CFrame
	local origin = cameraCF.Position
	local direction = cameraCF.LookVector

	seq += 1
	state.mag -= 1
	state.lastShotAt = now
	lastLocalShotAt = now

	if shootRemote then
		shootRemote:FireServer(currentWeaponId, seq, origin, direction)
	end

	-- Recoil is applied AFTER the direction is captured: the kick moves the aim
	-- for the NEXT shot, never for the one that caused it.
	local shotIndex = RecoilController.onShot(currentWeaponId, now)
	VFXController.playLocalShot(currentWeaponId, origin, direction)
	publish()

	WeaponClient.Fired:Fire(currentWeaponId, origin, direction, shotIndex)

	if state.mag <= 0 then
		WeaponClient.reload()
	end
end

--------------------------------------------------------------------------------
-- Slot switching
--------------------------------------------------------------------------------

--[[
	Adopt a weapon locally. `announce` sends the EquipWeaponRequest; it is false
	when the change came FROM the server (the CurrentWeapon attribute) and
	echoing it back would loop.
]]
local function adoptWeapon(weaponId: string, announce: boolean)
	if not WeaponConfig.exists(weaponId) or weaponId == currentWeaponId then
		return
	end

	-- Switching away abandons a reload in flight and leaves the magazine where it
	-- was, matching CombatService.onEquipWeaponRequest — "reload, swap, swap
	-- back" must not be a free instant refill.
	local previous = stateFor(currentWeaponId)
	previous.reloading = false
	previous.reloadUntil = 0

	currentWeaponId = weaponId
	switchUntil = os.clock() + SWITCH_TIME

	if announce and equipRemote then
		local weapon = WeaponConfig.get(weaponId)
		equipRemote:FireServer(weapon.slot)
	end

	ViewmodelController.setWeapon(weaponId)
	ViewmodelController.cancelReload()
	VFXController.playSwitchSound()
	publish()

	WeaponClient.WeaponChanged:Fire(weaponId)
end

--[[
	Public slot switch (also the touch HUD's entry point).
	`ClientState.currentSlot` is deliberately NOT written here: ClientState owns
	it and updates it from the server's CurrentWeapon attribute, so a swap the
	server refuses cannot leave the HUD highlighting the wrong slot forever.
]]
function WeaponClient.equipSlot(slot: number)
	local weaponId = WeaponConfig.fromSlot(slot)
	if not weaponId or weaponId == currentWeaponId or not canAct() then
		return
	end
	adoptWeapon(weaponId, true)
end

--------------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------------

local function reconcile(ammo)
	if type(ammo) ~= "table" or not WeaponConfig.exists(ammo.weaponId) then
		return
	end

	local weapon = WeaponConfig.get(ammo.weaponId)
	local state = stateFor(ammo.weaponId)

	state.magSize = if type(ammo.magSize) == "number" and ammo.magSize > 0 then ammo.magSize else state.magSize
	state.reloading = ammo.reloading == true
	-- The sync only says "reloading", not how much is left, so the local clock
	-- restarts from now. It runs slightly long by the latency of this packet,
	-- which the completion sync then corrects.
	state.reloadUntil = if state.reloading then os.clock() + weapon.reloadTime else 0

	-- A server count higher than ours is either a correction for a shot it
	-- refused, or a sync that left before our latest shots arrived. `ackSeq`
	-- separates them: once the server has processed everything we have sent,
	-- there is nothing in flight and its count is simply the truth.
	local caughtUp = type(ammo.ackSeq) == "number" and ammo.ackSeq >= seq
	local stale = ammo.mag > state.mag and not caughtUp and (os.clock() - lastLocalShotAt) < RECONCILE_GRACE
	if not stale then
		state.mag = ammo.mag
	end

	-- Published unconditionally: a sync for the stowed weapon must still leave
	-- ClientState.ammo describing the weapon actually in hand.
	publish()
end

--------------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------------

local function onHeartbeat()
	local now = os.clock()
	local state = stateFor(currentWeaponId)

	-- Local reload completion. The server's AmmoSync is authoritative and will
	-- overwrite this, but finishing on the local clock means the HUD stops
	-- showing "reloading" even if that packet is lost or the server refused the
	-- reload outright.
	if state.reloading and now >= state.reloadUntil then
		state.reloading = false
		state.reloadUntil = 0
		state.mag = state.magSize
		RecoilController.resetSpray(currentWeaponId)
		publish()
	end

	local weapon = WeaponConfig.get(currentWeaponId)
	if weapon and weapon.automatic and InputController.isFireHeld() then
		tryFire(now)
	end
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

function WeaponClient.getWeaponId(): string
	return currentWeaponId
end

--[[
	Predicted (mag, magSize, reloading) for a weapon, defaulting to the one in
	hand. The HUD reads ClientState.ammo instead; this is for anything that needs
	the *other* weapon's count.
]]
function WeaponClient.getAmmo(weaponId: string?): (number, number, boolean)
	local state = stateFor(weaponId or currentWeaponId)
	return state.mag, state.magSize, state.reloading
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

local function resetLoadout()
	for _, weaponId in WeaponConfig.Order do
		local weapon = WeaponConfig.get(weaponId)
		local state = stateFor(weaponId)
		state.mag = weapon.magSize
		state.magSize = weapon.magSize
		state.reloading = false
		state.reloadUntil = 0
		state.lastShotAt = NEVER
	end

	switchUntil = 0
	lastLocalShotAt = NEVER
	publish()
end

function WeaponClient.init()
	ClientState.init()

	local attributeWeapon = player:GetAttribute("CurrentWeapon")
	if WeaponConfig.exists(attributeWeapon) then
		currentWeaponId = attributeWeapon
	end
	for _, weaponId in WeaponConfig.Order do
		stateFor(weaponId)
	end

	trove:Add(InputController.FirePressed:Connect(function()
		-- Semi-automatic weapons fire here and nowhere else; automatics take
		-- their first shot here too so the burst starts on the same frame as the
		-- click instead of on the next Heartbeat.
		tryFire(os.clock())
	end))

	trove:Add(InputController.ReloadPressed:Connect(function()
		WeaponClient.reload()
	end))

	trove:Add(InputController.SlotPressed:Connect(WeaponClient.equipSlot))

	trove:Add(ClientState.AmmoChanged:Connect(function(ammo)
		if locallyPublished[ammo] then
			return
		end
		reconcile(ammo)
	end))

	-- The server's own view of what is in hand, which wins over the prediction.
	trove:Add(ClientState.SlotChanged:Connect(function(_slot: number, weaponId: string)
		adoptWeapon(weaponId, false)
	end))

	trove:Add(ClientState.Died:Connect(function()
		local state = stateFor(currentWeaponId)
		state.reloading = false
		state.reloadUntil = 0
		ViewmodelController.cancelReload()
	end))

	-- A new character means WeaponState.reset ran on the server: full magazines,
	-- clean spray, sequence counter back to zero (ours only ever grows, which is
	-- still strictly greater than a reset server counter).
	trove:Add(ClientState.Respawned:Connect(resetLoadout))

	trove:Connect(RunService.Heartbeat, onHeartbeat)
end

function WeaponClient.start()
	-- getRemote yields on the first lookup for a name, which is why this is here
	-- and not in init(); the handlers above all null-check until it lands.
	shootRemote = ClientState.getRemote(RemoteNames.ShootRequest)
	reloadRemote = ClientState.getRemote(RemoteNames.ReloadRequest)
	equipRemote = ClientState.getRemote(RemoteNames.EquipWeaponRequest)

	publish()
end

function WeaponClient.stop()
	trove:Clean()
	WeaponClient.WeaponChanged:DisconnectAll()
	WeaponClient.Fired:DisconnectAll()
end

return WeaponClient
