--!nonstrict
--[[
	tests/run.luau
	Minimal test runner for the pure (Roblox-free) modules of LaserTag.

	Run with the Luau CLI from the repository root:
		luau tests/run.luau

	Pure modules under src/shared/Config, src/shared/Util, src/shared/MapDefs,
	src/server/Match/MatchStateMachine, src/server/Combat/DamageCalc,
	src/server/Economy/* and src/server/Net/RateLimiterCore must not touch any
	Roblox API so they can be required directly here.
]]

local Runner = {}

local totalPassed = 0
local totalFailed = 0
local failures = {}

local currentSuite = "?"

local function formatValue(value: any): string
	if type(value) == "table" then
		local parts = {}
		for key, entry in pairs(value) do
			table.insert(parts, tostring(key) .. "=" .. tostring(entry))
		end
		table.sort(parts)
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

local function record(ok: boolean, message: string)
	if ok then
		totalPassed += 1
	else
		totalFailed += 1
		table.insert(failures, currentSuite .. " :: " .. message)
		print("  FAIL  " .. message)
	end
end

function Runner.expect(condition: any, message: string)
	record(condition and true or false, message)
end

function Runner.equal(actual: any, expected: any, message: string)
	local ok = actual == expected
	if not ok then
		message = `{message} (expected {formatValue(expected)}, got {formatValue(actual)})`
	end
	record(ok, message)
end

function Runner.near(actual: number, expected: number, tolerance: number, message: string)
	local ok = type(actual) == "number" and math.abs(actual - expected) <= tolerance
	if not ok then
		message = `{message} (expected ~{expected} +/- {tolerance}, got {formatValue(actual)})`
	end
	record(ok, message)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not deepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function Runner.deepEqual(actual: any, expected: any, message: string)
	record(deepEqual(actual, expected), message)
end

Runner.isDeepEqual = deepEqual

-- Every spec file returns a function(t) where `t` is this runner.
local SPECS = {
	"TableUtil",
	"MathUtil",
	"SprayPatterns",
	"WeaponConfig",
	"DamageCalc",
	"Balance",
	"MatchStateMachine",
	"ShopLogic",
	"SpinLogic",
	"RateLimiterCore",
	"MapDefs",
}

print("Running LaserTag unit tests\n")

local skipped = {}

for _, name in ipairs(SPECS) do
	-- Luau resolves relative requires against the requiring file, so specs are
	-- siblings of this runner regardless of the shell's working directory.
	local path = "./" .. name .. ".spec"
	local ok, specOrError = pcall(require, path)

	if not ok then
		local message = tostring(specOrError)
		-- A spec file that does not exist yet is reported loudly but does not
		-- fail the run; a spec that exists and errors while loading does.
		if string.find(message, "could not resolve child component", 1, true) then
			table.insert(skipped, name)
			print(name)
			print("  SKIP  spec file not written yet")
		else
			totalFailed += 1
			table.insert(failures, name .. " :: failed to load: " .. message)
			print(name)
			print("  FAIL  could not load spec: " .. message)
		end
		continue
	end

	currentSuite = name
	print(name)

	local runOk, err = pcall(specOrError, Runner)
	if not runOk then
		totalFailed += 1
		table.insert(failures, name .. " :: raised an error: " .. tostring(err))
		print("  FAIL  spec raised an error: " .. tostring(err))
	end
end

print("")
print(string.rep("-", 60))
print(`Passed: {totalPassed}   Failed: {totalFailed}   Skipped suites: {#skipped}`)

if #skipped > 0 then
	print("Missing spec files: " .. table.concat(skipped, ", "))
end

if totalFailed > 0 then
	print("")
	for _, failure in ipairs(failures) do
		print("  " .. failure)
	end
	print("")
	error(`{totalFailed} assertion(s) failed`, 0)
end

print("All tests passed.")
