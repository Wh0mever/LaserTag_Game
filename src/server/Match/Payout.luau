--!nonstrict
--[[
	Payout.luau
	What one player is paid, and credited with, when a match ends.

	Pure — no Roblox API, no Player — so the rules are testable off Roblox
	(tests/Payout.spec.luau) and MatchRuntime only has to gather the inputs.

	The award used to depend on the scoreline alone. That paid the full win
	bonus to a player seated five seconds before the clock ran out, and to the
	lone survivor of a 1v1 whose opponent disconnected thirty seconds in — two
	accounts could take turns at either for 400 coins a time. The rule now is that
	the bonus is for having taken part in the result:

	  * PRESENCE. A win or draw bonus needs `minSeconds` in the match, or all of
	    it if the match was shorter than that (a score limit can end one in well
	    under a minute, and everyone there from the start took part in all of it).
	    Anyone else is paid for taking part.

	  * FORFEIT. When the other side left and the win was handed over, the bonus
	    is scaled by how much of the match had been played: it runs from the
	    participation award at the start to the full win at the very end. A forfeit
	    needs the full `minSeconds` even in a short match, because a short match is
	    exactly how this is farmed. Someone who stayed through most of a match
	    whose opponents then quit still gets nearly all of the win.

	Nothing here is ever more than the configured win, or less than the
	participation award, so a bad input can only under-pay.
]]

local Payout = {}

export type Input = {
	winnerTeam: string?,
	teamId: string,
	reason: string?, -- "forfeit" when the win was handed over by the other side leaving
	playedSeconds: number?, -- how long this player was in the match
	matchSeconds: number?, -- how long the match ran
	matchDuration: number?, -- how long it was scheduled to run
	rewards: { MATCH_WIN: number, MATCH_DRAW: number, MATCH_PARTICIPATION: number },
	minSeconds: number?,
}

export type Result = {
	amount: number,
	-- "win" | "draw" | "played"
	outcome: string,
	-- Whether this counts towards the player's wins.
	won: boolean,
}

local DEFAULT_MIN_SECONDS = 60

local function finite(value: any): number?
	if type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge then
		return value
	end
	return nil
end

function Payout.compute(input: Input): Result
	local rewards = input.rewards
	local participation = rewards.MATCH_PARTICIPATION
	local ordinary: Result = { amount = participation, outcome = "played", won = false }

	local played = finite(input.playedSeconds)
	local matchSeconds = finite(input.matchSeconds)
	if not played or not matchSeconds then
		-- Without the times there is nothing to show the bonus was earned.
		return ordinary
	end

	local minSeconds = finite(input.minSeconds) or DEFAULT_MIN_SECONDS
	local forfeit = input.reason == "forfeit"

	local needed = if forfeit then minSeconds else math.min(minSeconds, matchSeconds)
	if played < needed then
		return ordinary
	end

	if input.winnerTeam == nil then
		return { amount = rewards.MATCH_DRAW, outcome = "draw", won = false }
	end
	if input.teamId ~= input.winnerTeam then
		return ordinary
	end

	if not forfeit then
		return { amount = rewards.MATCH_WIN, outcome = "win", won = true }
	end

	local duration = finite(input.matchDuration)
	if not duration or duration <= 0 then
		return ordinary
	end

	local share = math.clamp(matchSeconds / duration, 0, 1)
	local amount = participation + math.floor((rewards.MATCH_WIN - participation) * share)
	return { amount = amount, outcome = "win", won = true }
end

return Payout
