--!nonstrict
--[[
	ShootValidation.luau
	The admission checks the three combat remotes have to survive, one function
	per rule. ShootRequest gets the five-step pipeline; ReloadRequest and
	EquipWeaponRequest get the short validators at the bottom of the file.

	Every step returns (ok, reason) instead of raising. CombatService drops a
	failed request in silence — telling the client which rule it broke turns the
	handler into an oracle an exploiter can tune a payload against — while the
	reason string still reaches the server log for anti-cheat review.

	Steps are ordered cheapest-first: the pure type checks run before anything
	touches the workspace, and nothing here mutates state, so a rejected request
	leaves the player's weapon state exactly as it found it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local Validators = require(script.Parent.Parent.Net.Validators)
local WeaponConfig = require(Shared.Config.WeaponConfig)
local WeaponState = require(script.Parent.WeaponState)

local ShootValidation = {}

local ARG_SCHEMA = { "string", "number", "Vector3", "Vector3" }

local matchService: any = nil
local matchServiceResolved = false

--[[
	MatchService is written by a sibling agent and loads at priority 5. It is
	required on first use rather than at module scope so a missing or broken
	module degrades this step to "cannot verify" instead of taking every shot in
	the game down with it.
]]
local function getMatchService(): any
	if matchServiceResolved then
		return matchService
	end
	matchServiceResolved = true

	local services = script.Parent.Parent:FindFirstChild("Services")
	local moduleScript = services and services:FindFirstChild("MatchService")
	if not moduleScript then
		return nil
	end

	local ok, result = pcall(require, moduleScript)
	matchService = if ok and type(result) == "table" then result else nil
	return matchService
end

--[[
	Step (a): argument types and enums. Takes the raw vararg so extra arguments
	are rejected too — a caller sending more values than the schema declares is
	probing, not playing.
]]
function ShootValidation.checkArguments(...): (boolean, string?)
	local ok, err = Validators.checkTypes(table.pack(...), ARG_SCHEMA)
	if not ok then
		return false, `bad-args: {err}`
	end

	local weaponId, seq, _origin, direction = ...

	if not WeaponConfig.exists(weaponId) then
		return false, `unknown-weapon: {tostring(weaponId)}`
	end

	if not Validators.isPositiveInteger(seq) then
		return false, "seq-is-not-a-positive-integer"
	end

	-- A "direction" of magnitude 1e9 would turn the range-limited raycast into a
	-- world-spanning one, so length is checked, not just finiteness.
	if not Validators.isUnitVector(direction) then
		return false, "direction-is-not-unit-length"
	end

	return true, nil
end

--[[
	Step (b): the shooter exists in the world and is alive.
]]
function ShootValidation.checkAlive(player: Player): (boolean, string?)
	if not Validators.isAlive(player) then
		return false, "shooter-is-not-alive"
	end

	if not Validators.getRootPart(player) then
		return false, "shooter-has-no-root-part"
	end

	return true, nil
end

--[[
	Step (c): the shooter is in a live match holding the weapon the server
	believes they are holding. Both attributes are server-written, so trusting
	them is trusting the server, not the client.
]]
function ShootValidation.checkMatch(player: Player, weaponId: string): (boolean, string?)
	local mapId = player:GetAttribute("InMatch")
	if type(mapId) ~= "string" or mapId == "" then
		return false, "shooter-is-not-in-a-match"
	end

	local service = getMatchService()
	if service and type(service.isInProgress) == "function" and not service.isInProgress(mapId) then
		return false, `match-is-not-in-progress: {mapId}`
	end

	if player:GetAttribute("CurrentWeapon") ~= weaponId then
		return false, `weapon-is-not-equipped: {weaponId}`
	end

	return true, nil
end

--[[
	Step (d): the claimed shot origin is near where the SERVER believes the
	player's eyes are. This is the check that stops origin spoofing — shooting
	from behind a wall, or from across the map — and the tolerance is what buys
	an honest player room for latency.
]]
function ShootValidation.checkOrigin(player: Player, origin: Vector3): (boolean, string?)
	local eye = Validators.getHeadPosition(player)
	if not eye then
		return false, "no-server-known-eye-position"
	end

	local deviation = (origin - eye).Magnitude
	if deviation > WeaponConfig.MAX_ORIGIN_DEVIATION then
		return false, `origin-deviation: {string.format("%.1f", deviation)} studs`
	end

	return true, nil
end

--[[
	Step (e): replay protection. Sequence numbers are per weapon and strictly
	increasing, so a ShootRequest captured off the wire is worthless the moment
	the shot it belonged to has been processed.
]]
function ShootValidation.checkSequence(player: Player, weaponId: string, seq: number): (boolean, string?)
	local entry = WeaponState.get(player, weaponId)
	if seq <= entry.lastSeq then
		return false, `replayed-seq: {seq} is not above {entry.lastSeq}`
	end

	return true, nil
end

--[[
	Run every step in order. This is the function CombatService hands to
	Remotes.register as the ShootRequest validator, so the handler only ever runs
	for a shot that has already cleared all five.
]]
function ShootValidation.validate(player: Player, ...): (boolean, string?)
	local ok, reason = ShootValidation.checkArguments(...)
	if not ok then
		return false, reason
	end

	local weaponId, seq, origin = ...

	ok, reason = ShootValidation.checkAlive(player)
	if not ok then
		return false, reason
	end

	ok, reason = ShootValidation.checkMatch(player, weaponId)
	if not ok then
		return false, reason
	end

	ok, reason = ShootValidation.checkOrigin(player, origin)
	if not ok then
		return false, reason
	end

	return ShootValidation.checkSequence(player, weaponId, seq)
end

--[[
	ReloadRequest: (weaponId). A reload is only meaningful for the weapon the
	server currently has the player holding, so the equipped check is part of
	admission rather than something the handler discovers later.
]]
function ShootValidation.validateReload(player: Player, ...): (boolean, string?)
	local ok, err = Validators.checkTypes(table.pack(...), { "string" })
	if not ok then
		return false, `bad-args: {err}`
	end

	local weaponId = ...
	if not WeaponConfig.exists(weaponId) then
		return false, `unknown-weapon: {tostring(weaponId)}`
	end

	if not Validators.isAlive(player) then
		return false, "player-is-not-alive"
	end

	if player:GetAttribute("CurrentWeapon") ~= weaponId then
		return false, `weapon-is-not-equipped: {weaponId}`
	end

	return true, nil
end

--[[
	EquipWeaponRequest: (slot). The slot is mapped through WeaponConfig rather
	than range-checked, so adding a third weapon later cannot leave a slot number
	that validates here but resolves to nothing in the handler.
]]
function ShootValidation.validateEquip(player: Player, ...): (boolean, string?)
	local ok, err = Validators.checkTypes(table.pack(...), { "number" })
	if not ok then
		return false, `bad-args: {err}`
	end

	local slot = ...
	if not WeaponConfig.fromSlot(slot) then
		return false, `unknown-slot: {tostring(slot)}`
	end

	if not Validators.isAlive(player) then
		return false, "player-is-not-alive"
	end

	return true, nil
end

return ShootValidation
