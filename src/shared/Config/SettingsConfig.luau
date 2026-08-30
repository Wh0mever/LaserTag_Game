--!nonstrict
--[[
	SettingsConfig.luau
	The player-adjustable settings: what they are, what they may be, and what
	they are when nobody has touched them.

	Pure data and pure functions — no Roblox API — so the server can sanitise an
	incoming settings table with the exact same code the client uses to build the
	sliders, and tests/Settings.spec.luau can exercise every bound off Roblox.

	The server treats anything a client sends as a suggestion: `sanitize` is
	TOTAL, meaning it returns a complete, valid table for any input at all,
	including nil, a string, or a table with hostile values. A setting is a
	cosmetic preference, but it is still a value the client chooses and the
	server stores, so it goes through the same "never trust the payload" door as
	everything else.
]]

local SettingsConfig = {}

--[[
	Each entry:
	  id        key in the stored table and in the profile
	  label     what the player reads
	  hint      one line under the label; why they would touch it
	  min/max   inclusive bounds, enforced server-side
	  default   value for a profile that has never set it
	  step      slider granularity; also what the value is rounded to
	  format    how the number is rendered next to the slider
]]
SettingsConfig.Definitions = {
	{
		id = "Sensitivity",
		label = "ЧУВСТВИТЕЛЬНОСТЬ МЫШИ",
		hint = "Насколько поворачивается вид при том же движении мыши",
		min = 0.2,
		max = 3,
		default = 1,
		step = 0.05,
		format = "%.2fx",
	},
	{
		id = "Volume",
		label = "ГРОМКОСТЬ",
		hint = "Оружие, попадания и колесо наград",
		min = 0,
		max = 1,
		default = 1,
		step = 0.05,
		format = "%d%%",
		-- Rendered as a percentage, so the raw 0-1 value is scaled for display.
		displayScale = 100,
	},
	{
		id = "FieldOfView",
		label = "ПОЛЕ ЗРЕНИЯ",
		hint = "Шире — видно фланги; уже — легче читать дистанцию",
		min = 60,
		max = 100,
		default = 70,
		step = 1,
		format = "%d°",
	},
}

-- id -> definition, built once so lookups are not a linear scan per keystroke.
local byId: { [string]: any } = {}
for _, definition in SettingsConfig.Definitions do
	byId[definition.id] = definition
end

SettingsConfig.ById = byId

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function SettingsConfig.get(id: any)
	return if type(id) == "string" then byId[id] else nil
end

--[[
	Snap `value` to the setting's step and clamp it into range.

	Rounding to the step matters beyond tidiness: it is what stops a client
	storing 0.7311827956989247 and the label rendering something the slider can
	never return to.

	Anything that is not a finite number resolves to the default rather than to a
	bound — a mangled value means "no opinion", and the default is the honest
	answer to that, where clamping would silently pick an extreme.
]]
function SettingsConfig.clamp(id: any, value: any): number?
	local definition = SettingsConfig.get(id)
	if not definition then
		return nil
	end

	if not isFiniteNumber(value) then
		return definition.default
	end

	local snapped = math.floor(value / definition.step + 0.5) * definition.step
	snapped = math.clamp(snapped, definition.min, definition.max)

	-- Steps like 0.05 do not divide cleanly in binary, so the multiply above can
	-- leave 0.35000000000000003. Round to a sane number of decimals for the same
	-- reason the snap exists.
	return tonumber(string.format("%.4f", snapped)) or definition.default
end

--[[
	A complete table of defaults. Fresh each call: handing out a shared table
	would let one caller's edit become every future profile's starting point.
]]
function SettingsConfig.defaults(): { [string]: number }
	local out = {}
	for _, definition in SettingsConfig.Definitions do
		out[definition.id] = definition.default
	end
	return out
end

--[[
	A valid settings table from any input whatsoever.

	Unknown keys are dropped rather than carried through: the profile is a
	persisted structure, and letting a client write arbitrary keys into it is how
	a cosmetic remote turns into free storage.
]]
function SettingsConfig.sanitize(input: any): { [string]: number }
	local out = SettingsConfig.defaults()
	if type(input) ~= "table" then
		return out
	end

	for _, definition in SettingsConfig.Definitions do
		local raw = input[definition.id]
		if raw ~= nil then
			out[definition.id] = SettingsConfig.clamp(definition.id, raw) :: number
		end
	end

	return out
end

--[[
	The label shown beside a slider, e.g. "1.25x" or "85%".
]]
function SettingsConfig.display(id: any, value: any): string
	local definition = SettingsConfig.get(id)
	if not definition then
		return ""
	end

	local resolved = SettingsConfig.clamp(id, value) :: number
	return string.format(definition.format, resolved * (definition.displayScale or 1))
end

--[[
	Where `value` sits between min and max, as 0..1. This is the slider's fill
	fraction, and its inverse is how a click position becomes a value.
]]
function SettingsConfig.toFraction(id: any, value: any): number
	local definition = SettingsConfig.get(id)
	if not definition then
		return 0
	end

	local span = definition.max - definition.min
	if span <= 0 then
		return 0
	end

	local resolved = SettingsConfig.clamp(id, value) :: number
	return math.clamp((resolved - definition.min) / span, 0, 1)
end

--[[
	The value at `fraction` (0..1) along the slider, snapped and clamped.
]]
function SettingsConfig.fromFraction(id: any, fraction: any): number?
	local definition = SettingsConfig.get(id)
	if not definition then
		return nil
	end

	local alpha = if isFiniteNumber(fraction) then math.clamp(fraction, 0, 1) else 0
	return SettingsConfig.clamp(id, definition.min + alpha * (definition.max - definition.min))
end

return SettingsConfig
