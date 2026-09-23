--!nonstrict
--[[
	TextUtil.luau
	Text helpers that know the game's text is Russian.

	Luau's string functions work on BYTES. Cyrillic is two bytes a letter in
	UTF-8, so:

	  * string.upper("Альфа") returns "Альфа" unchanged — it only knows ASCII.
	    Every screen that asked for its team names in capitals got mixed case
	    beside the all-caps labels around them ("ПОБЕДА — Альфа").

	  * string.sub(name, 1, 1) returns HALF of the first letter of a Cyrillic
	    name, which is not valid text; the avatar initial in the friends list
	    rendered as a broken glyph for anyone whose name is not Latin.

	Pure: no Roblox API, tested off-Roblox by tests/TextUtil.spec.luau.
]]

local TextUtil = {}

-- Lowercase -> uppercase offsets, by code point range.
local function upperCode(code: number): number
	if code >= 0x61 and code <= 0x7A then -- a-z
		return code - 0x20
	elseif code >= 0x430 and code <= 0x44F then -- а-я
		return code - 0x20
	elseif code >= 0x450 and code <= 0x45F then -- ѐ-џ, including ё
		return code - 0x50
	end
	return code
end

--[[
	Uppercases Latin and Cyrillic. Anything else passes through untouched, and a
	string that is not valid UTF-8 falls back to the byte-wise string.upper
	rather than erroring — a garbled display name must not break a screen.
]]
function TextUtil.upper(text: string): string
	if type(text) ~= "string" then
		return ""
	end
	if utf8.len(text) == nil then
		return string.upper(text)
	end

	local out = {}
	for _, code in utf8.codes(text) do
		table.insert(out, utf8.char(upperCode(code)))
	end
	return table.concat(out)
end

--[[
	The first CHARACTER of `text`, not the first byte. Empty for an empty or
	invalid string.
]]
function TextUtil.firstChar(text: string): string
	if type(text) ~= "string" or text == "" or utf8.len(text) == nil then
		return ""
	end
	local nextStart = utf8.offset(text, 2)
	return if nextStart then string.sub(text, 1, nextStart - 1) else text
end

--[[
	The Russian form of a counted noun: plural(3, "вращение", "вращения",
	"вращений") -> "вращения".

	Russian picks one of three forms by the last digits, not "one or many":
	1, 21, 101 take the first; 2-4, 22-24 the second; 0, 5-20, 25-30 the
	third — with 11-14 always the third. The pity line had "через 3 вращений",
	which every player who spun the wheel a few times read.
]]
function TextUtil.plural(count: number, one: string, few: string, many: string): string
	local n = math.abs(math.floor(count))
	local lastTwo = n % 100
	local last = n % 10
	if lastTwo >= 11 and lastTwo <= 14 then
		return many
	elseif last == 1 then
		return one
	elseif last >= 2 and last <= 4 then
		return few
	end
	return many
end

return TextUtil
