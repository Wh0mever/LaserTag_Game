--!nonstrict
--[[
	tests/harness/economy.luau
	Runs the real economy services (analytics, profiles, leaderboard, friends)
	against stand-ins that are as strict as the engine.

	The Lune mock accepts anything, which is how AnalyticsService shipped with
	LogProgressionEvent's arguments in the wrong order: the call threw inside a
	pcall, the service switched itself off for the rest of the server's life, and
	nothing anywhere said so. So the analytics stand-in here checks every
	argument's type and range the way the documented signatures do, and a check
	asks whether the service is still switched on afterwards.

	Run:  lune run tests/harness/economy
]]

local Env = require("./env")
local roblox = require("@lune/roblox")

Env.enableClientRuntime()

local passed, failed = 0, 0
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

local Enum = roblox.Enum

--------------------------------------------------------------------------------
-- A strict AnalyticsService
--
-- Signatures are the documented ones (Roblox creator-docs, AnalyticsService):
--   LogCustomEvent(player, eventName, value?, customFields?)
--   LogEconomyEvent(player, flowType, currencyType, amount, endingBalance,
--                   transactionType, itemSku?, customFields?)
--   LogFunnelStepEvent(player, funnelName, funnelSessionId, step, stepName?, customFields?)
--   LogProgressionEvent(player, progressionPathName, status, level?, levelName?, customFields?)
-- customFields only honours the keys of Enum.AnalyticsCustomFieldKeys.
--------------------------------------------------------------------------------

local logged: { { method: string, args: { any } } } = {}

local function argError(method: string, position: number, expected: string, got: any)
	error(`{method}: argument {position} must be {expected}, got {type(got)} ({tostring(got)})`, 3)
end

local function expectString(method: string, position: number, value: any, optional: boolean?)
	if value == nil and optional then
		return
	end
	if type(value) ~= "string" or (not optional and value == "") then
		argError(method, position, "a non-empty string", value)
	end
end

local function expectNumber(method: string, position: number, value: any, optional: boolean?)
	if value == nil and optional then
		return
	end
	if type(value) ~= "number" or value ~= value then
		argError(method, position, "a number", value)
	end
end

local function expectEnum(method: string, position: number, value: any, enumType: any)
	if type(value) ~= "userdata" or value.EnumType ~= enumType then
		argError(method, position, `an {tostring(enumType)} item`, value)
	end
end

local function expectPlayer(method: string, value: any)
	if type(value) ~= "table" or type(value.UserId) ~= "number" then
		argError(method, 1, "a Player", value)
	end
end

local function expectFields(method: string, position: number, fields: any)
	if fields == nil then
		return
	end
	if type(fields) ~= "table" then
		argError(method, position, "a dictionary", fields)
	end
	for key, value in fields do
		local isKey = type(key) == "string" and Enum.AnalyticsCustomFieldKeys[key] ~= nil
		if not isKey then
			error(`{method}: customFields key {tostring(key)} is not an AnalyticsCustomFieldKeys name`, 3)
		end
		if type(value) ~= "string" then
			error(`{method}: customFields.{key} must be a string, got {type(value)}`, 3)
		end
	end
end

local function record(method: string, ...)
	table.insert(logged, { method = method, args = table.pack(...) })
end

local strictAnalytics = Env.service("AnalyticsService")

function strictAnalytics.LogCustomEvent(_self, player, eventName, value, customFields)
	expectPlayer("LogCustomEvent", player)
	expectString("LogCustomEvent", 2, eventName)
	expectNumber("LogCustomEvent", 3, value, true)
	expectFields("LogCustomEvent", 4, customFields)
	record("LogCustomEvent", player, eventName, value, customFields)
end

function strictAnalytics.LogEconomyEvent(
	_self,
	player,
	flowType,
	currencyType,
	amount,
	endingBalance,
	transactionType,
	itemSku,
	customFields
)
	expectPlayer("LogEconomyEvent", player)
	expectEnum("LogEconomyEvent", 2, flowType, Enum.AnalyticsEconomyFlowType)
	expectString("LogEconomyEvent", 3, currencyType)
	expectNumber("LogEconomyEvent", 4, amount)
	expectNumber("LogEconomyEvent", 5, endingBalance)
	if amount <= 0 or endingBalance < 0 then
		error("LogEconomyEvent: amount must be positive and endingBalance non-negative", 2)
	end
	expectString("LogEconomyEvent", 6, transactionType)
	expectString("LogEconomyEvent", 7, itemSku, true)
	expectFields("LogEconomyEvent", 8, customFields)
	record("LogEconomyEvent", player, flowType, currencyType, amount, endingBalance, transactionType, itemSku)
end

function strictAnalytics.LogFunnelStepEvent(_self, player, funnelName, funnelSessionId, step, stepName, customFields)
	expectPlayer("LogFunnelStepEvent", player)
	expectString("LogFunnelStepEvent", 2, funnelName)
	expectString("LogFunnelStepEvent", 3, funnelSessionId)
	expectNumber("LogFunnelStepEvent", 4, step)
	expectString("LogFunnelStepEvent", 5, stepName, true)
	expectFields("LogFunnelStepEvent", 6, customFields)
	record("LogFunnelStepEvent", player, funnelName, funnelSessionId, step, stepName)
end

function strictAnalytics.LogProgressionEvent(_self, player, pathName, status, level, levelName, customFields)
	expectPlayer("LogProgressionEvent", player)
	expectString("LogProgressionEvent", 2, pathName)
	if pathName:find("[,\"'\n\r]") then
		error("LogProgressionEvent: progressionPathName may not contain , \" ' or a newline", 2)
	end
	expectEnum("LogProgressionEvent", 3, status, Enum.AnalyticsProgressionType)
	expectNumber("LogProgressionEvent", 4, level, true)
	expectString("LogProgressionEvent", 5, levelName, true)
	expectFields("LogProgressionEvent", 6, customFields)
	record("LogProgressionEvent", player, pathName, status, level, levelName, customFields)
end

local function loggedCalls(method: string)
	local out = {}
	for _, entry in logged do
		if entry.method == method then
			table.insert(out, entry)
		end
	end
	return out
end

local nextUserId = 5000
local function fakePlayer(name: string)
	nextUserId += 1
	local attributes = {}
	return {
		Name = name,
		DisplayName = name,
		UserId = nextUserId,
		Parent = Env.service("Players"),
		GetAttribute = function(_self, key)
			return attributes[key]
		end,
		SetAttribute = function(_self, key, value)
			attributes[key] = value
		end,
		IsDescendantOf = function(self, ancestor)
			return self.Parent == ancestor
		end,
	}
end

--------------------------------------------------------------------------------
-- Analytics
--------------------------------------------------------------------------------

heading("Analytics")

local AnalyticsService = Env.load("src/server/Services/AnalyticsService")

do
	local player = fakePlayer("analyst")
	AnalyticsService.matchQueued(player, "Dust")
	AnalyticsService.matchStarted(player, "Dust")
	AnalyticsService.killScored(player)
	AnalyticsService.killScored(player)
	AnalyticsService.matchFinished(player, true, 54, 31)

	local progression = loggedCalls("LogProgressionEvent")
	check(#progression == 1, `a finished match reports exactly one progression event (got {#progression})`)
	check(
		AnalyticsService.isAvailable(),
		"the progression event is accepted by the engine's signature, so analytics stays switched on"
	)

	local entry = progression[1]
	if entry then
		local args = entry.args
		check(args[2] == "Dust", "the progression path is the map")
		check(args[3] == Enum.AnalyticsProgressionType.Complete, "a win is reported as Complete")
		check(args[4] == 1, `the level is the number 1 (got {tostring(args[4])})`)
		check(type(args[5]) == "string", `the level has a name (got {type(args[5])})`)
	end
end

do
	local player = fakePlayer("loser")
	AnalyticsService.matchQueued(player, "Dust")
	AnalyticsService.matchStarted(player, "Dust")
	AnalyticsService.matchFinished(player, false, 20, 54)
	local last = loggedCalls("LogProgressionEvent")
	local entry = last[#last]
	check(entry ~= nil and entry.args[3] == Enum.AnalyticsProgressionType.Fail, "a loss is reported as Fail")
end

-- The other three call shapes go through the same strict stand-in, so one
-- wrong argument anywhere shows up as the service having switched itself off.
do
	local player = fakePlayer("spender")
	AnalyticsService.coinsEarned(player, 25, 125, "Kill")
	AnalyticsService.coinsSpent(player, 100, 25, "Skin_Neon")
	AnalyticsService.spinResolved(player, 3, "Coins", 250)
	check(#loggedCalls("LogEconomyEvent") == 2, "coins earned and spent are both reported")
	check(#loggedCalls("LogCustomEvent") == 1, "a spin is reported")
	check(AnalyticsService.isAvailable(), "economy and spin events are accepted, so analytics stays switched on")

	local spin = loggedCalls("LogCustomEvent")[1]
	check(spin ~= nil and spin.args[4] ~= nil, "a spin carries its breakdown fields")
end

check(#Env.spawnErrors == 0, `no background thread died: {table.concat(Env.spawnErrors, " | ")}`)

--------------------------------------------------------------------------------
-- Result
--------------------------------------------------------------------------------

heading("Result")

print(`  Passed: {passed}   Failed: {failed}`)
if failed > 0 then
	for _, message in failures do
		print(`  FAIL  {message}`)
	end
	error(`{failed} economy check(s) failed`, 0)
end
print("  All economy checks passed.")
