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
	Damage one shot from `weaponDef` deals, before any part-specific lookup.

	Floored rather than rounded: a 59.5 pistol headshot must not become 60, which
	would silently turn the pistol's advertised two-headshot kill into a
	different number if MAX_HEALTH ever moved to 120.
]]
function DamageCalc.perShot(weaponDef: any, isHeadshot: boolean): number
	local base = weaponDef and weaponDef.damage
	if not isFiniteNumber(base) then
		return MINIMUM_DAMAGE
	end

	local raw = base
	if isHeadshot then
		local multiplier = weaponDef.headshotMultiplier
		raw = base * (if isFiniteNumber(multiplier) and multiplier > 0 then multiplier else 1)
	end

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
function DamageCalc.compute(weaponDef: any, hitPartName: string, headParts: { [string]: boolean }?): (number, boolean)
	local headshot = DamageCalc.isHeadshot(hitPartName, headParts)
	return DamageCalc.perShot(weaponDef, headshot), headshot
end

--[[
	How many hits of this kind it takes to drop a target on `health`.
	Returns 0 for a target that is already down, so callers can treat the result
	as "shots still required" without a special case.
]]
function DamageCalc.shotsToKill(weaponDef: any, health: number, headshot: boolean): number
	if not isFiniteNumber(health) or health <= 0 then
		return 0
	end

	return math.ceil(health / DamageCalc.perShot(weaponDef, headshot))
end

return DamageCalc
