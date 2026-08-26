--!nonstrict
--[[
	tests/harness/run.luau
	Runs every harness scenario and fails if any of them does.

	Each scenario runs in its own process. They build Instances and populate a
	module cache, and sharing that between scenarios would let one leave state
	that quietly changes what the next one sees.

	Run:  lune run tests/harness/run
]]

local process = require("@lune/process")

local SCENARIOS = {
	{ name = "modules", what = "every server and shared module loads" },
	{ name = "world", what = "all three maps build and are playable" },
	{ name = "models", what = "every weapon builds in every skin" },
}

local failed = {}

for _, scenario in SCENARIOS do
	print("")
	print(string.rep("=", 60))
	print(`HARNESS: {scenario.name} — {scenario.what}`)
	print(string.rep("=", 60))

	local result = process.exec("lune", { "run", `tests/harness/{scenario.name}` }, {
		stdio = "inherit",
	})

	if not result.ok then
		table.insert(failed, scenario.name)
	end
end

print("")
print(string.rep("=", 60))

if #failed > 0 then
	print(`HARNESS FAILED: {table.concat(failed, ", ")}`)
	process.exit(1)
end

print(`HARNESS PASSED: {#SCENARIOS} scenarios`)
