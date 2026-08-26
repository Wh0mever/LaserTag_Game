--!nonstrict
--[[
	tests/harness/modules.luau
	Loads every server and shared module once, outside Roblox.

	Requiring a module runs its whole body: the service lookups, the top-level
	requires, the constant tables it builds. A typo there is invisible to the
	linter (which sees a valid name) and to the unit tests (which never reach
	these files) — in Studio it surfaces as the game silently failing to start.

	This is deliberately shallow. It proves each module evaluates and hands back
	what it claims to, not that its logic is right; the unit tests do that for
	the pure modules, and the world and model harnesses exercise the two big
	Instance builders.

	Run:  lune run tests/harness/modules
]]

local Env = require("./env")
local fs = require("@lune/fs")

local loaded = 0
local failedCount = 0
local failures: { { path: string, err: string } } = {}
local exportsNothing: { string } = {}
local sideEffects: { { path: string, effects: string } } = {}

--------------------------------------------------------------------------------
-- Collect
--------------------------------------------------------------------------------

--[[
	Client modules are excluded: they require Players.LocalPlayer and a PlayerGui
	that only exist on a real client. Pretending otherwise would mean stubbing
	the very things their code is about.
]]
local ROOTS = { "src/shared", "src/server" }
local SKIP = {
	["src/server/Vendor/ProfileService"] = "third-party, exercised through DataService",
	-- init.server.luau is the bootstrap: requiring it would start the game.
	["src/server/init.server"] = "bootstrap, starts the whole server",
}

local function collect(dir: string, out: { string })
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			collect(full, out)
		elseif entry:match("%.luau$") then
			-- Parenthesised: gsub also returns a count, which table.insert would
			-- otherwise take as a position argument.
			table.insert(out, (full:gsub("%.luau$", "")))
		end
	end
	return out
end

local modules: { string } = {}
for _, root in ROOTS do
	collect(root, modules)
end
table.sort(modules)

--------------------------------------------------------------------------------
-- Load
--------------------------------------------------------------------------------

-- Loaded first, deliberately. ProfileService starts its auto-save loop, connects
-- PlayerRemoving and registers BindToClose the moment it is required — correct
-- for that library, but it would otherwise be charged to whichever of our
-- services pulled it in first and make the report below meaningless.
Env.load("src/server/Vendor/ProfileService")

print(`Loading {#modules} modules`)
print(string.rep("-", 60))

for _, path in modules do
	local reason = SKIP[path]
	if reason then
		print(`  skip  {path}  ({reason})`)
		continue
	end

	-- Snapshot the sandbox counters around the load. A module that connects an
	-- event, spawns a task or registers BindToClose while merely being required
	-- is doing work before the loader's init/start phases, which is the
	-- discipline this codebase adopted precisely so boot order stays knowable.
	local before = table.clone(Env.calls())

	local ok, result = pcall(function()
		return Env.load(path)
	end)

	local effects = {}
	for name, count in Env.calls() do
		local delta = count - (before[name] or 0)
		if delta > 0 then
			table.insert(effects, `{name}x{delta}`)
		end
	end
	if #effects > 0 then
		table.sort(effects)
		table.insert(sideEffects, { path = path, effects = table.concat(effects, " ") })
	end

	if ok then
		loaded += 1
		-- A ModuleScript that returns nothing is almost always an unfinished
		-- file; the only legitimate case here is a types-only module.
		if result == nil then
			table.insert(exportsNothing, path)
		end
	else
		failedCount += 1
		table.insert(failures, { path = path, err = tostring(result) })
	end
end

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

print("")
print(`Loaded: {loaded}   Failed: {failedCount}`)

if #exportsNothing > 0 then
	print("")
	print("Returned nil (fine for a types-only module):")
	for _, path in exportsNothing do
		print("  " .. path)
	end
end

if #sideEffects > 0 then
	print("")
	print("Side effects while merely being required:")
	for _, entry in sideEffects do
		print(`  {entry.path}  ->  {entry.effects}`)
	end
end

if failedCount > 0 then
	print("")
	for _, failure in failures do
		print(`  FAIL  {failure.path}`)
		print(`        {failure.err}`)
	end
	print("")
	error(`{failedCount} module(s) failed to load`, 0)
end

print("")
print("Every module loaded.")
