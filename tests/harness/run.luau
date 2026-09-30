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
	{ name = "lighting", what = "the rig and the palettes agree on what may glow" },
	{ name = "client", what = "every client module loads and boots" },
	{ name = "mobile", what = "a phone can aim, shoot, reload and switch view" },
	{ name = "match", what = "the match runtime's own rules: sides, late joins, results" },
	{ name = "vfx", what = "beams, viewmodel, sparks, hitmarker, crosshair, death view" },
	{ name = "sides", what = "the side question answers a refusal or a dropped request with a rest and a reason" },
	{ name = "notice", what = "the notice banner sits above the menus, centred, clear of the controls" },
	{ name = "deaths", what = "a reset or a fall after being shot is credited to the shooter and recorded" },
	{ name = "reset", what = "the escape menu's reset button is off in a match and on in the hub" },
	{ name = "queue", what = "the portal sign reads a match in its last minute as ending, not going" },
	{ name = "results", what = "the results screen says whether the player won, lost or drew, and why" },
	{ name = "net", what = "the remote pipeline: who is kicked, and what a client can make the log say" },
	{ name = "economy", what = "analytics, profiles, leaderboard and friends against strict stand-ins" },
	{ name = "friends", what = "the friends panel lists who is online elsewhere, and says so when it cannot tell" },
	{ name = "combat", what = "fire rate, reloads, swaps, hit resolution and who hears a shot" },
	{ name = "weapon", what = "the client's firing loop at 30 to 240 fps, reloads and server syncs" },
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
