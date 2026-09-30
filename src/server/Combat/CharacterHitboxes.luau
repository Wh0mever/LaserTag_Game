--!nonstrict
--[[
	CharacterHitboxes.luau
	Keeps what a character wears out of the way of the shots aimed at it.

	Accessories are parts, and a raycast hits parts. A hat or a fringe stands in
	front of the head it is worn on, so a shot at the middle of the head meets
	the hair first: that is a hit on "Handle", which is not the head, so it paid
	body damage. And a wide hat is a wider target than the head under it.

	The fix is to make accessories invisible to queries. With CanQuery off the
	ray passes through them and hits the body part that is really there. Roblox
	only honours CanQuery on a part that does not collide, so collision goes off
	first; an accessory handle has no business colliding anyway, the humanoid
	moves on its own body.

	Accessories arrive late -- the asset servers fill in a character's appearance
	after it exists, sometimes seconds after -- so this does not run once: it
	handles what is there and everything added afterwards.
]]

local CharacterHitboxes = {}

-- Accoutrement is the base class of Accessory and of the older Hat, so both are
-- covered.
local function isWorn(instance: Instance): boolean
	return instance:IsA("BasePart") and instance:FindFirstAncestorWhichIsA("Accoutrement") ~= nil
end

local function harden(instance: Instance)
	if isWorn(instance) then
		instance.CanCollide = false
		instance.CanQuery = false
	end
end

--[[
	Harden `character` now and whatever is put on it later. Returns the
	connection that watches for new parts, for the caller's Trove.
]]
function CharacterHitboxes.apply(character: Model): RBXScriptConnection
	for _, descendant in character:GetDescendants() do
		harden(descendant)
	end

	return character.DescendantAdded:Connect(harden)
end

return CharacterHitboxes
