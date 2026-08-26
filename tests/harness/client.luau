--!nonstrict
--[[
	tests/harness/client.luau
	Loads every client module and runs the controllers' lifecycle.

	Client code is the half of this game that no other check reaches. The unit
	tests cover pure modules, the world and model harnesses cover the two big
	Instance builders, and all of that is server-side. Meanwhile the client owns
	everything the player actually feels — input, camera, recoil, the HUD — and
	a typo there means a client that boots into a black screen.

	Nothing is rendered here, so this proves the modules evaluate, expose the
	lifecycle the loader expects, and survive init() and start() without a
	running game. It does not prove anything looks right; only a playtest can.

	Run:  lune run tests/harness/client
]]

local Env = require("./env")
local fs = require("@lune/fs")

-- Client code lives on the runtime side of Roblox — cameras, viewports, signals
-- — which Lune's data model does not carry. This swaps in stand-ins for those
-- before anything is required.
Env.enableClientRuntime()

local passed = 0
local failed = 0
local failures: { string } = {}

local function check(ok: boolean, message: string)
	if ok then
		passed += 1
	else
		failed += 1
		table.insert(failures, message)
	end
end

local function heading(text: string)
	print("")
	print(text)
	print(string.rep("-", 60))
end

--------------------------------------------------------------------------------
-- Collect
--------------------------------------------------------------------------------

local SKIP = {
	-- The bootstrap: requiring it would start the whole client.
	["src/client/init.client"] = true,
}

local function collect(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collect(full, out)
		elseif entry:match("%.luau$") then
			table.insert(out, (full:gsub("%.luau$", "")))
		end
	end
	return out
end

local modules = collect("src/client", {})
table.sort(modules)

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------

heading(`Loading {#modules} client modules`)

local loadedModules: { { path: string, value: any } } = {}

for _, path in modules do
	if SKIP[path] then
		print(`  skip  {path}`)
		continue
	end

	local ok, result = pcall(function()
		return Env.load(path)
	end)

	check(ok, `{path} loads{if ok then "" else ": " .. tostring(result)}`)
	if ok and type(result) == "table" then
		table.insert(loadedModules, { path = path, value = result })
	end
end

print(`  {#loadedModules} modules returned a table`)

--------------------------------------------------------------------------------
-- Lifecycle contract
--
-- The loader calls init() on everything, then start(). A controller that names
-- one of them something else is silently never run.
--------------------------------------------------------------------------------

heading("Lifecycle")

local withInit = 0
local withStart = 0

for _, entry in loadedModules do
	local module = entry.value

	if module.Priority ~= nil then
		check(type(module.Priority) == "number", `{entry.path} Priority is a number`)
	end

	if type(module.init) == "function" then
		withInit += 1
	end
	if type(module.start) == "function" then
		withStart += 1
	end
end

print(`  {withInit} modules define init(), {withStart} define start()`)

--------------------------------------------------------------------------------
-- Run init() and start()
--
-- This is where a nil index or a missing service surfaces. Each call is isolated
-- so one broken controller does not hide the rest.
--------------------------------------------------------------------------------

heading("Running init()")

for _, entry in loadedModules do
	local module = entry.value
	if type(module.init) ~= "function" then
		continue
	end

	local ok, err = pcall(module.init)
	check(ok, `{entry.path}.init(){if ok then "" else " -> " .. tostring(err)}`)
end

heading("Running start()")

for _, entry in loadedModules do
	local module = entry.value
	if type(module.start) ~= "function" then
		continue
	end

	local ok, err = pcall(module.start)
	check(ok, `{entry.path}.start(){if ok then "" else " -> " .. tostring(err)}`)
end

--------------------------------------------------------------------------------
-- Every weapon must make a noise
--
-- A missing sound key returns silently, so a weapon added without one simply
-- fires without a sound and nothing anywhere complains. That is exactly the
-- kind of gap that survives to production, so it is asserted rather than left
-- to be noticed.
--------------------------------------------------------------------------------

heading("Weapon sounds")

local WeaponConfig = Env.load("src/shared/Config/WeaponConfig")
local VFXSound = Env.load("src/client/Controllers/VFX/VFXSound")

for _, weaponId in WeaponConfig.Order do
	check(VFXSound.has(weaponId), `{weaponId} has a firing sound`)
end

--------------------------------------------------------------------------------
-- What the run left behind
--------------------------------------------------------------------------------

heading("After start()")

local bindings = {}
for name in Env.renderBindings do
	table.insert(bindings, name)
end
table.sort(bindings)
if #bindings > 0 then
	print("  render bindings: " .. table.concat(bindings, ", "))
end

local calls = Env.calls()
local summary = {}
for name, count in calls do
	table.insert(summary, `{name}={count}`)
end
table.sort(summary)
if #summary > 0 then
	print("  sandbox calls: " .. table.concat(summary, "  "))
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")
print(`  Passed: {passed}   Failed: {failed}`)

if failed > 0 then
	print("")
	for _, failure in failures do
		print("  FAIL  " .. failure)
	end
	print("")
	error(`{failed} client check(s) failed`, 0)
end

print("  All client checks passed.")
