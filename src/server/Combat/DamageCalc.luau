--!nonstrict
--[[
	DamageCalc.luau
	The damage arithmetic for a single laser hit. Pure — no Roblox API and no
	module state — so tests/DamageCalc.spec.luau requires it directly off Roblox.

	The head-part set is mirrored here instead of required from WeaponConfig: a
	server module can only reach ReplicatedStorage.Shared through the Roblox API,
	which the off-Roblox runner does not have (the same constraint src/shared/
	MapDefs works under). Callers on the server therefore pass
	WeaponConfig.HEAD_PARTS explicitly so the config stays authoritative at
	runtime, and the spec asserts the two tables agree so the fallback cannot
	drift away from it.
]]

local DamageCalc = {}

-- Mirrors WeaponConfig.HEAD_PARTS; see the note above.
DamageCalc.HEAD_PARTS = {
	Head = true,
}

-- Every landed shot costs the victim something. Without this floor a weapon
-- tuned below 1 damage — or a future armour multiplier — would resolve to 0, and
-- hits would register on the shooter's screen while doing nothing at all.
local MINIMUM_DAMAGE = 1

-- Local copy of MathUtil.isFinite for the same reason the head parts are local.
local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	How much of its damage a weapon keeps at `distance` studs.

	Without this every weapon hits equally hard at every range, and the only
	things separating them are rate of fire and magazine — which is what made the
	rifle the correct pick at every distance on every map, since it led on both.
	Falloff is what gives each weapon a band it owns: full damage out to
	`falloff.start`, then a straight line down to `falloff.minFactor`, reached at
	`falloff.finish` and held beyond it.

	A weapon with no `falloff` block never fades. That is a design statement
	rather than an oversight — it is what makes the marksman weapon the only
	honest answer at long range.
]]
function DamageCalc.rangeFactor(weaponDef: any, distance: any): number
	local falloff = weaponDef and weaponDef.falloff
	if type(falloff) ~= "table" then
		return 1
	end

	-- An unknown distance must not silently weaken a shot: a mangled raycast
	-- result would otherwise read as "very far away" and quietly halve damage.
	if not isFiniteNumber(distance) then
		return 1
	end

	local startAt = falloff.start
	local finishAt = falloff.finish
	local minFactor = falloff.minFactor
	if not (isFiniteNumber(startAt) and isFiniteNumber(finishAt) and isFiniteNumber(minFactor)) then
		return 1
	end

	if distance <= startAt or finishAt <= startAt then
		return 1
	end
	if distance >= finishAt then
		return math.clamp(minFactor, 0, 1)
	end

	local travelled = (distance - startAt) / (finishAt - startAt)
	return math.clamp(1 - travelled * (1 - minFactor), 0, 1)
end

--[[
	Damage one shot from `weaponDef` deals, before any part-specific lookup.

	`distance` is how far the shot travelled, in studs; omit it and the shot is
	treated as point blank, which is what every caller that predates falloff
	expects.

	Floored rather than rounded: a 59.5 pistol headshot must not become 60, which
	would silently turn the pistol's advertised two-headshot kill into a
	different number if MAX_HEALTH ever moved to 120.
]]
function DamageCalc.perShot(weaponDef: any, isHeadshot: boolean, distance: number?): number
	local base = weaponDef and weaponDef.damage
	if not isFiniteNumber(base) then
		return MINIMUM_DAMAGE
	end

	local raw = base
	if isHeadshot then
		local multiplier = weaponDef.headshotMultiplier
		raw = base * (if isFiniteNumber(multiplier) and multiplier > 0 then multiplier else 1)
	end

	raw *= DamageCalc.rangeFactor(weaponDef, distance)

	return math.max(MINIMUM_DAMAGE, math.floor(raw))
end

--[[
	Whether a hit on `hitPartName` counts as a headshot. Anything not listed in
	`headParts` — including a nil or a non-string, which is what a mangled
	raycast result looks like — is a body hit, so an unknown part name can never
	be more rewarding than a known one.
]]
function DamageCalc.isHeadshot(hitPartName: any, headParts: { [string]: boolean }?): boolean
	local parts = headParts or DamageCalc.HEAD_PARTS
	return type(hitPartName) == "string" and parts[hitPartName] == true
end

--[[
	Damage and headshot flag for one hit.
	`headParts` defaults to DamageCalc.HEAD_PARTS; the server passes
	WeaponConfig.HEAD_PARTS.
]]
function DamageCalc.compute(
	weaponDef: any,
	hitPartName: string,
	headParts: { [string]: boolean }?,
	distance: number?
): (number, boolean)
	local headshot = DamageCalc.isHeadshot(hitPartName, headParts)
	return DamageCalc.perShot(weaponDef, headshot, distance), headshot
end

--[[
	How many hits of this kind it takes to drop a target on `health`.
	Returns 0 for a target that is already down, so callers can treat the result
	as "shots still required" without a special case.
]]
function DamageCalc.shotsToKill(weaponDef: any, health: number, headshot: boolean, distance: number?): number
	if not isFiniteNumber(health) or health <= 0 then
		return 0
	end

	return math.ceil(health / DamageCalc.perShot(weaponDef, headshot, distance))
end

return DamageCalc
