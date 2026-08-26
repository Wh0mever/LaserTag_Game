--!nonstrict
local SprayPatterns = require("../src/shared/Config/SprayPatterns")
local WeaponConfig = require("../src/shared/Config/WeaponConfig")

return function(t)
	-- Pattern length must match magazine size so a full spray is covered.
	t.equal(#SprayPatterns.Kick.Rifle, WeaponConfig.Weapons.Rifle.magSize, "rifle pattern covers a full magazine")
	t.equal(#SprayPatterns.Kick.Pistol, WeaponConfig.Weapons.Pistol.magSize, "pistol pattern covers a full magazine")

	-- Phase 1 of the rifle spray is a strictly rising vertical climb.
	for index = 2, 8 do
		local previous = SprayPatterns.getKick("Rifle", index - 1)
		local current = SprayPatterns.getKick("Rifle", index)
		t.expect(current.pitch > previous.pitch, `rifle climbs on shot {index}`)
	end

	-- Phase 2 sways right (positive yaw), phase 3 sways left (negative yaw).
	for index = 10, 18 do
		t.expect(SprayPatterns.getKick("Rifle", index).yaw > 0, `rifle sways right on shot {index}`)
	end
	for index = 19, 30 do
		t.expect(SprayPatterns.getKick("Rifle", index).yaw < 0, `rifle sways left on shot {index}`)
	end

	-- Vertical climb is front-loaded: the first 8 shots carry most of the rise.
	local firstPhase = SprayPatterns.accumulate("Rifle", 8)
	local fullSpray = SprayPatterns.accumulate("Rifle", 30)
	t.expect(firstPhase.pitch > fullSpray.pitch * 0.35, "the initial climb dominates the vertical recoil")

	-- The pistol is essentially vertical: tiny horizontal drift.
	for index = 1, 12 do
		local kick = SprayPatterns.getKick("Pistol", index)
		t.expect(math.abs(kick.yaw) <= 0.1, `pistol stays near-vertical on shot {index}`)
		t.expect(kick.pitch > 0, `pistol always kicks upward on shot {index}`)
	end

	-- Index clamping: past the end of the table we reuse the final entry, and a
	-- zero/negative index never errors.
	local last = SprayPatterns.getKick("Rifle", 30)
	local past = SprayPatterns.getKick("Rifle", 999)
	t.equal(past.pitch, last.pitch, "kick clamps to the last entry past the magazine")
	t.equal(SprayPatterns.getKick("Rifle", 0).pitch, SprayPatterns.getKick("Rifle", 1).pitch, "kick clamps at 1")
	t.equal(SprayPatterns.getKick("Unknown", 1).pitch, 0, "an unknown weapon yields no kick")

	-- Server spread grows with the spray and never shrinks.
	local previousSpread = 0
	for index = 1, 30 do
		local spread = SprayPatterns.getServerSpreadDeg("Rifle", index)
		t.expect(spread >= previousSpread, `rifle spread never shrinks at index {index}`)
		previousSpread = spread
	end
	t.equal(SprayPatterns.getServerSpreadDeg("Rifle", 1), 0.2, "first rifle shot is accurate")
	t.equal(SprayPatterns.getServerSpreadDeg("Rifle", 30), 2.2, "deep spray is inaccurate")
	t.equal(SprayPatterns.getServerSpreadDeg("Rifle", 999), 2.2, "spread caps at the last tier")
	t.equal(SprayPatterns.getServerSpreadDeg("Unknown", 1), 0, "an unknown weapon has no spread table")

	-- The first pistol shot must be more accurate than a deep rifle spray;
	-- that is what makes tapping a real tactical choice.
	t.expect(
		SprayPatterns.getServerSpreadDeg("Pistol", 1) < SprayPatterns.getServerSpreadDeg("Rifle", 20),
		"a first pistol shot beats a deep rifle spray"
	)

	-- nextIndex: continues while firing, resets after a pause.
	local resetTime = WeaponConfig.Weapons.Rifle.sprayResetTime
	t.equal(SprayPatterns.nextIndex("Rifle", 0, math.huge, resetTime), 1, "a fresh magazine starts at index 1")
	t.equal(SprayPatterns.nextIndex("Rifle", 4, 0.05, resetTime), 5, "holding the trigger advances the pattern")
	t.equal(SprayPatterns.nextIndex("Rifle", 12, resetTime + 0.01, resetTime), 1, "a pause resets the pattern")
	t.equal(SprayPatterns.nextIndex("Rifle", 12, resetTime - 0.01, resetTime), 13, "a short pause does not reset")
	t.equal(SprayPatterns.nextIndex("Rifle", 30, 0.05, resetTime), 30, "index saturates at the pattern length")
	t.equal(SprayPatterns.nextIndex("Pistol", 12, 0.05, 0.5), 12, "pistol index saturates too")
end
