--!nonstrict
local TextUtil = require("../src/shared/Util/TextUtil")

return function(t)
	-- The bug this exists for: the byte-wise upper leaves Cyrillic alone.
	t.equal(
		string.upper("Альфа"),
		"Альфа",
		"string.upper really does ignore Cyrillic (the reason for this module)"
	)
	t.equal(TextUtil.upper("Альфа"), "АЛЬФА", "Cyrillic is uppercased")
	t.equal(TextUtil.upper("Браво"), "БРАВО", "every Cyrillic letter, not just the first")
	t.equal(TextUtil.upper("ёж"), "ЁЖ", "ё, which sits outside the а-я block, is uppercased too")
	t.equal(TextUtil.upper("Dust 2"), "DUST 2", "Latin and digits still work")
	t.equal(
		TextUtil.upper("Скин «Багровый»"),
		"СКИН «БАГРОВЫЙ»",
		"punctuation passes through"
	)
	t.equal(TextUtil.upper(""), "", "empty stays empty")
	t.equal(TextUtil.upper(nil :: any), "", "a non-string gives an empty string, not an error")

	local broken = "a" .. string.char(0xD0) -- a lead byte with no continuation
	t.expect(pcall(TextUtil.upper, broken), "invalid UTF-8 does not raise")

	-- firstChar: the whole first letter, whatever its byte length.
	t.equal(TextUtil.firstChar("Никита"), "Н", "a Cyrillic initial is a whole letter")
	t.equal(#TextUtil.firstChar("Никита"), 2, "which is two bytes long, not one")
	t.equal(TextUtil.firstChar("Nurik"), "N", "a Latin initial is one byte")
	t.equal(TextUtil.firstChar(""), "", "an empty name has no initial")
	t.equal(TextUtil.firstChar(broken), "", "an invalid name has no initial rather than half of one")

	-- Russian plurals: three forms, chosen by the last digits.
	local function spins(n)
		return TextUtil.plural(n, "вращение", "вращения", "вращений")
	end
	t.equal(spins(1), "вращение", "1 вращение")
	t.equal(spins(3), "вращения", "3 вращения, not 3 вращений (the bug)")
	t.equal(spins(5), "вращений", "5 вращений")
	t.equal(spins(11), "вращений", "11 вращений, not 11 вращение")
	t.equal(spins(12), "вращений", "12 вращений, not 12 вращения")
	t.equal(spins(21), "вращение", "21 вращение")
	t.equal(spins(22), "вращения", "22 вращения")
	t.equal(spins(0), "вращений", "0 вращений")
	t.equal(spins(111), "вращений", "111 вращений")
end
