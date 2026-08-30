--!nonstrict
--[[
	Settings.spec.luau
	The rules a settings payload goes through before it reaches a saved profile.

	Settings are cosmetic — sensitivity, volume and field of view are all applied
	client-side and none of them changes what the server believes about a shot.
	That makes them low-stakes to get wrong in gameplay terms and high-stakes to
	get wrong in storage terms: the remote's whole job is "write this table into
	my persisted profile", which is free storage for anyone who cares to use it
	unless the sanitiser is total.

	So the property this file cares about most is that `sanitize` returns a
	complete, in-range table for ANY input, with no key the config does not
	define.
]]

local SettingsConfig = require("../src/shared/Config/SettingsConfig")

--[[
	Every value in `settings` is one this setting may legally hold — a finite
	number inside a slider's bounds, or one of a choice's option ids — and there
	is exactly one entry per definition. Returns a reason string when it does
	not hold, so a failure names the offending key.
]]
local function violation(settings: any): string?
	if type(settings) ~= "table" then
		return `not a table: {typeof(settings)}`
	end

	local seen = 0
	for key, value in settings do
		local definition = SettingsConfig.get(key)
		if not definition then
			return `unknown key "{tostring(key)}"`
		end

		if definition.kind == "choice" then
			local known = false
			for _, option in definition.options do
				if option.id == value then
					known = true
					break
				end
			end
			if not known then
				return `"{key}" is not one of its options: {tostring(value)}`
			end
		else
			if type(value) ~= "number" or value ~= value then
				return `"{key}" is not a number: {tostring(value)}`
			end
			if value < definition.min or value > definition.max then
				return `"{key}" is out of range: {value} not in {definition.min}..{definition.max}`
			end
		end

		seen += 1
	end

	if seen ~= #SettingsConfig.Definitions then
		return `expected {#SettingsConfig.Definitions} settings, got {seen}`
	end
	return nil
end

return function(t)
	-- The definitions themselves ------------------------------------------

	t.expect(#SettingsConfig.Definitions > 0, "there are settings to change")

	local ids = {}
	for _, definition in SettingsConfig.Definitions do
		t.expect(type(definition.id) == "string" and #definition.id > 0, "every setting has an id")
		t.expect(ids[definition.id] == nil, `{definition.id} is defined once`)
		ids[definition.id] = true

		t.expect(type(definition.label) == "string" and #definition.label > 0, `{definition.id} has a label`)
		t.expect(type(definition.hint) == "string" and #definition.hint > 0, `{definition.id} explains itself`)

		if definition.kind == "choice" then
			t.expect(
				type(definition.options) == "table" and #definition.options >= 2,
				`{definition.id} offers a choice`
			)

			local optionIds = {}
			local defaultIsAnOption = false
			for _, option in definition.options do
				t.expect(type(option.id) == "string" and #option.id > 0, `{definition.id} option has an id`)
				t.expect(type(option.label) == "string" and #option.label > 0, `{definition.id} option has a label`)
				t.expect(optionIds[option.id] == nil, `{definition.id} option {option.id} appears once`)
				optionIds[option.id] = true
				if option.id == definition.default then
					defaultIsAnOption = true
				end
			end

			-- A default that is not on the list would make every fresh profile
			-- invalid the moment it was read back.
			t.expect(defaultIsAnOption, `{definition.id} defaults to one of its own options`)
			t.expect(SettingsConfig.isChoice(definition.id), `{definition.id} reports itself as a choice`)
		else
			t.expect(definition.max > definition.min, `{definition.id} has a range`)
			t.expect(definition.step > 0, `{definition.id} has a positive step`)
			t.expect(
				definition.default >= definition.min and definition.default <= definition.max,
				`{definition.id} defaults inside its own range`
			)

			-- A step that does not divide the range leaves a value at one end the
			-- slider can approach but never actually land on.
			t.expect(
				definition.step <= definition.max - definition.min,
				`{definition.id} step is smaller than its range`
			)
			t.expect(not SettingsConfig.isChoice(definition.id), `{definition.id} is not a choice`)
		end

		t.equal(SettingsConfig.get(definition.id), definition, `{definition.id} is reachable by id`)
	end

	t.equal(SettingsConfig.get("NotASetting"), nil, "an unknown id has no definition")
	t.equal(SettingsConfig.get(nil), nil, "a nil id has no definition")
	t.equal(SettingsConfig.get(42), nil, "a non-string id has no definition")

	-- Defaults --------------------------------------------------------------

	local defaults = SettingsConfig.defaults()
	t.equal(violation(defaults), nil, "the defaults are themselves valid")

	-- A shared table would let one caller's edit become every future profile's
	-- starting point.
	local first = SettingsConfig.defaults()
	local second = SettingsConfig.defaults()
	t.expect(first ~= second, "defaults() hands out a fresh table each call")
	first.Sensitivity = 999
	t.equal(SettingsConfig.defaults().Sensitivity, defaults.Sensitivity, "editing one copy does not affect the next")

	-- Clamping --------------------------------------------------------------

	local sens = SettingsConfig.get("Sensitivity")
	t.equal(SettingsConfig.clamp("Sensitivity", sens.min - 5), sens.min, "a value below the range clamps up")
	t.equal(SettingsConfig.clamp("Sensitivity", sens.max + 5), sens.max, "a value above the range clamps down")
	t.equal(SettingsConfig.clamp("Sensitivity", sens.min), sens.min, "the bottom of the range is reachable")
	t.equal(SettingsConfig.clamp("Sensitivity", sens.max), sens.max, "the top of the range is reachable")

	-- A mangled number means "no opinion", and the default is the honest answer
	-- to that; clamping would silently pick an extreme instead.
	t.equal(SettingsConfig.clamp("Sensitivity", 0 / 0), sens.default, "NaN resolves to the default, not a bound")
	t.equal(SettingsConfig.clamp("Sensitivity", math.huge), sens.default, "infinity resolves to the default")
	t.equal(SettingsConfig.clamp("Sensitivity", -math.huge), sens.default, "negative infinity resolves to the default")
	t.equal(SettingsConfig.clamp("Sensitivity", "1.5"), sens.default, "a string resolves to the default")
	t.equal(SettingsConfig.clamp("Sensitivity", nil), sens.default, "nil resolves to the default")
	t.equal(SettingsConfig.clamp("Sensitivity", {}), sens.default, "a table resolves to the default")

	t.equal(SettingsConfig.clamp("NotASetting", 1), nil, "an unknown setting cannot be clamped")

	-- Values snap to the step, so a client cannot store a number the slider can
	-- never return to.
	for _, definition in SettingsConfig.Definitions do
		if definition.kind == "choice" then
			continue
		end
		local midpoint = (definition.min + definition.max) / 2
		local clamped = SettingsConfig.clamp(definition.id, midpoint) :: number
		local steps = (clamped - definition.min) / definition.step
		t.expect(math.abs(steps - math.floor(steps + 0.5)) < 1e-6, `{definition.id} snaps to its step (got {clamped})`)
	end

	-- Sanitising ------------------------------------------------------------
	-- The property this file exists for: any input at all becomes a complete,
	-- in-range table with no keys the config does not define.

	local HOSTILE = {
		nil,
		42,
		"settings",
		true,
		{},
		{ Sensitivity = math.huge },
		{ Sensitivity = 0 / 0, Volume = -50, FieldOfView = 1e9 },
		{ Sensitivity = "fast" },
		{ NotASetting = 1, AlsoNot = { nested = true } },
		{ Sensitivity = 1.5, Extra = "junk" },
	}

	for index = 1, 10 do
		local result = SettingsConfig.sanitize(HOSTILE[index])
		t.equal(violation(result), nil, `hostile input {index} sanitises to a valid table`)
	end

	-- A value that was already fine survives untouched.
	local kept = SettingsConfig.sanitize({ Sensitivity = 1.5, Volume = 0.5, FieldOfView = 90 })
	t.equal(kept.Sensitivity, 1.5, "a valid sensitivity is kept")
	t.equal(kept.Volume, 0.5, "a valid volume is kept")
	t.equal(kept.FieldOfView, 90, "a valid field of view is kept")

	-- A partial table is completed from the defaults rather than left short.
	local partial = SettingsConfig.sanitize({ Volume = 0.25 })
	t.equal(partial.Volume, 0.25, "the supplied key is kept")
	t.equal(partial.Sensitivity, defaults.Sensitivity, "a missing key falls back to its default")
	t.equal(violation(partial), nil, "a partial table still sanitises complete")

	-- Sanitising is idempotent: running it on its own output changes nothing.
	local once = SettingsConfig.sanitize({ Sensitivity = 99, Volume = -1 })
	local twice = SettingsConfig.sanitize(once)
	for id, value in once do
		t.equal(twice[id], value, `sanitize is idempotent for {id}`)
	end

	-- Fractions -------------------------------------------------------------
	-- These are what the slider maps a click position through, in both
	-- directions, so a round trip has to land back where it started.

	for _, definition in SettingsConfig.Definitions do
		if definition.kind == "choice" then
			continue
		end

		t.equal(SettingsConfig.toFraction(definition.id, definition.min), 0, `{definition.id} min is fraction 0`)
		t.equal(SettingsConfig.toFraction(definition.id, definition.max), 1, `{definition.id} max is fraction 1`)

		t.equal(
			SettingsConfig.fromFraction(definition.id, 0),
			definition.min,
			`{definition.id} fraction 0 is the minimum`
		)
		t.equal(
			SettingsConfig.fromFraction(definition.id, 1),
			definition.max,
			`{definition.id} fraction 1 is the maximum`
		)

		-- Out-of-range fractions are the normal case, not an error: a drag that
		-- leaves the track sends positions past both ends.
		t.equal(
			SettingsConfig.fromFraction(definition.id, -3),
			definition.min,
			`{definition.id} clamps a fraction below zero`
		)
		t.equal(
			SettingsConfig.fromFraction(definition.id, 4),
			definition.max,
			`{definition.id} clamps a fraction above one`
		)
		t.equal(
			SettingsConfig.fromFraction(definition.id, 0 / 0),
			definition.min,
			`{definition.id} treats a NaN fraction as the bottom`
		)

		-- Round trip through both directions.
		for _, fraction in { 0, 0.25, 0.5, 0.75, 1 } do
			local value = SettingsConfig.fromFraction(definition.id, fraction) :: number
			local back = SettingsConfig.fromFraction(definition.id, SettingsConfig.toFraction(definition.id, value))
			t.equal(back, value, `{definition.id} survives a fraction round trip at {fraction}`)
		end
	end

	t.equal(SettingsConfig.toFraction("NotASetting", 1), 0, "an unknown setting has no fraction")
	t.equal(SettingsConfig.fromFraction("NotASetting", 0.5), nil, "an unknown setting has no value")

	-- Display ---------------------------------------------------------------

	for _, definition in SettingsConfig.Definitions do
		local text = SettingsConfig.display(definition.id, definition.default)
		t.expect(type(text) == "string" and #text > 0, `{definition.id} renders a readout`)
	end

	t.equal(SettingsConfig.display("Volume", 1), "100%", "volume reads as a percentage")
	t.equal(SettingsConfig.display("Volume", 0), "0%", "silence reads as zero percent")
	t.equal(SettingsConfig.display("Sensitivity", 1), "1.00x", "sensitivity reads as a multiplier")
	t.equal(SettingsConfig.display("NotASetting", 1), "", "an unknown setting renders nothing")

	-- A garbage value still renders something rather than erroring mid-frame.
	t.expect(#SettingsConfig.display("Sensitivity", 0 / 0) > 0, "a NaN value still renders")

	-- Choices -----------------------------------------------------------------
	-- A choice stores a string, which is the one thing every other setting is
	-- guaranteed not to be, so each numeric assumption above is re-checked here
	-- from the other side.

	local PERSPECTIVE = "Perspective"
	t.expect(SettingsConfig.isChoice(PERSPECTIVE), "the perspective setting is a choice")
	t.expect(not SettingsConfig.isChoice("NotASetting"), "an unknown setting is not a choice")

	local options = SettingsConfig.optionsFor(PERSPECTIVE)
	t.expect(type(options) == "table" and #options == 2, "perspective offers first and third person")
	t.equal(SettingsConfig.optionsFor("Sensitivity"), nil, "a slider has no options")
	t.equal(SettingsConfig.optionsFor("NotASetting"), nil, "an unknown setting has no options")

	t.equal(SettingsConfig.clamp(PERSPECTIVE, "First"), "First", "a known option is kept")
	t.equal(SettingsConfig.clamp(PERSPECTIVE, "Third"), "Third", "the other known option is kept")

	-- Everything else is "no opinion", and the honest answer to that is the
	-- default. A choice has no bounds, so there is nothing to clamp toward.
	local DEFAULT_PERSPECTIVE = SettingsConfig.get(PERSPECTIVE).default
	for _, hostile in { "first", "FIRST", "", "Fourth", 1, 0 / 0, true, {}, nil } do
		t.equal(
			SettingsConfig.clamp(PERSPECTIVE, hostile),
			DEFAULT_PERSPECTIVE,
			`an unrecognised perspective ({tostring(hostile)}) falls back to the default`
		)
	end

	-- The display is the option's label, not its id: the id is a storage key and
	-- the player should never see it.
	t.equal(SettingsConfig.display(PERSPECTIVE, "First"), options[2].label, "a choice renders its option's label")
	t.equal(
		SettingsConfig.display(PERSPECTIVE, "nonsense"),
		options[1].label,
		"a bad choice renders the default's label"
	)

	-- It is never rendered as a slider, and asking would otherwise divide by a
	-- range it does not have.
	t.equal(SettingsConfig.toFraction(PERSPECTIVE, "First"), 0, "a choice has no slider fraction")
	t.equal(SettingsConfig.fromFraction(PERSPECTIVE, 0.5), nil, "a choice cannot be read off a slider")

	-- And the whole point: a payload mixing both kinds survives intact.
	local mixed = SettingsConfig.sanitize({ Perspective = "First", Sensitivity = 2, Volume = 0.5, FieldOfView = 90 })
	t.equal(violation(mixed), nil, "a payload of both kinds sanitises cleanly")
	t.equal(mixed.Perspective, "First", "the chosen perspective survives sanitising")
	t.equal(mixed.Sensitivity, 2, "a slider beside a choice is untouched")

	local hostileMix = SettingsConfig.sanitize({ Perspective = 42, Sensitivity = "Third" })
	t.equal(violation(hostileMix), nil, "swapping the two kinds' value types still sanitises")
	t.equal(hostileMix.Perspective, DEFAULT_PERSPECTIVE, "a number for a choice falls back")
	t.equal(hostileMix.Sensitivity, SettingsConfig.get("Sensitivity").default, "a string for a slider falls back")
end
