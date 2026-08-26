--!nonstrict
--[[
	SpinService.luau
	The reward wheel. The client asks for a spin and gets back a SpinResult:

		{ok, err?, segmentId?, segmentIndex?, rewardKind?, rewardLabel?,
		 coins?, nextFreeAt?, pity?}

	`segmentIndex` is the 1-based slot in SpinConfig.Segments, which is what lets
	the client wheel land its animation on the segment the server actually rolled
	rather than picking its own.

	Two rules this file exists to enforce:

	  * The reward is written to the profile BEFORE the result is returned. A
	    reply-then-grant ordering loses the prize whenever a player disconnects
	    in the gap, and that gap is exactly when a client would choose to leave.
	  * One spin at a time per player. The in-flight lock below makes a
	    double-click cost one spin, not two.

	The RNG lives here and only here: Economy/SpinLogic takes the number as an
	argument so the odds stay testable and the client never supplies one.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Rojo places Shared under ReplicatedStorage at build time, so on the server it
-- is always already there; the timeout exists so a broken build fails loudly
-- instead of hanging this module body forever.
local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "ReplicatedStorage.Shared is missing — check default.project.json")

local AnalyticsService = require(script.Parent.AnalyticsService)
local DataService = require(script.Parent.DataService)
local RemoteNames = require(Shared.RemoteNames)
local Remotes = require(script.Parent.Parent.Net.Remotes)
local SkinCatalog = require(Shared.Config.SkinCatalog)
local SpinConfig = require(Shared.Config.SpinConfig)
local SpinLogic = require(script.Parent.Parent.Economy.SpinLogic)
local Trove = require(Shared.Util.Trove)
local Validators = require(script.Parent.Parent.Net.Validators)

local SpinService = {}
SpinService.Priority = 6

-- Rate limit from the network contract. Three per ten seconds is generous for a
-- wheel whose animation alone takes several seconds, and caps how fast a script
-- could burn a balance on extra spins.
local SPIN_RATE, SPIN_WINDOW = 3, 10

local ERRORS = {
	NoProfile = "Your data is still loading",
	InFlight = "Your wheel is still spinning",
	NeedCoins = `An extra spin costs {SpinConfig.EXTRA_SPIN_COST} coins`,
	Failed = "The wheel is unavailable right now",
}

local rng = Random.new()
local spinning: { [Player]: boolean } = {}
local serviceTrove = Trove.new()

local function stateOf(data: any)
	return {
		coins = data.Coins,
		nextFreeAt = SpinLogic.nextFreeAt(data.Spin),
		pity = if data.Spin then data.Spin.Pity else 0,
	}
end

local function failure(err: string, data: any)
	if not data then
		return { ok = false, err = err }
	end

	local state = stateOf(data)
	return { ok = false, err = err, coins = state.coins, nextFreeAt = state.nextFreeAt, pity = state.pity }
end

--[[
	One spin, start to finish, against live profile data.

	The coin award is rewound and re-granted through DataService for the same
	reason ShopService rewinds a purchase: SpinLogic mutates the profile table
	directly (it knows nothing about players), but DataService owns the Coins
	attribute, leaderstats and the CoinsChanged remote, and has no way to resync
	a balance that moved behind its back. Nothing between the rewind and the
	re-grant yields, so the intermediate balance is never observable.
]]
local function performSpin(player: Player, data: any)
	local now = workspace:GetServerTimeNow()
	local spin = data.Spin

	local free = SpinLogic.canSpinFree(spin, now)
	if not free and not DataService.trySpendCoins(player, SpinConfig.EXTRA_SPIN_COST, "ExtraSpin") then
		return failure(ERRORS.NeedCoins, data)
	end

	local segment, segmentIndex = SpinLogic.roll(rng:NextNumber(), spin.Pity)
	if not segment then
		-- A misconfigured wheel must not pocket the fee.
		if not free then
			DataService.addCoins(player, SpinConfig.EXTRA_SPIN_COST, "Spin refund")
		end
		return failure(ERRORS.Failed, data)
	end

	local coinsBefore = data.Coins
	local rewardKind, coinsAwarded, rewardLabel = SpinLogic.applyResult(data, segment)
	data.Coins = coinsBefore

	-- Consuming the free spin happens only once a segment has actually been
	-- applied, so a failed roll above never burns the day's free spin.
	if free then
		SpinLogic.markFreeSpin(spin, now)
	end

	if coinsAwarded > 0 then
		DataService.addCoins(player, coinsAwarded, "Spin")
	end

	-- Sent per spin rather than aggregated: spins are rare, and this is what
	-- makes it checkable that the wheel pays out the odds it advertises.
	AnalyticsService.spinResolved(player, segmentIndex, rewardKind, if free then 0 else SpinConfig.EXTRA_SPIN_COST)

	DataService.pushSnapshot(player)

	local state = stateOf(data)
	return {
		ok = true,
		segmentId = segment.id,
		segmentIndex = segmentIndex,
		rewardKind = rewardKind,
		rewardLabel = rewardLabel,
		coins = state.coins,
		nextFreeAt = state.nextFreeAt,
		pity = state.pity,
	}
end

local function onSpinRequest(player: Player)
	local data = DataService.getData(player)
	if not data or type(data.Spin) ~= "table" then
		return failure(ERRORS.NoProfile, nil)
	end

	-- One spin at a time. Without this a double-click lands two invocations on
	-- the same profile and the second one charges for a wheel already turning.
	if spinning[player] then
		return failure(ERRORS.InFlight, data)
	end

	spinning[player] = true
	-- pcall so an error inside the spin cannot leave the lock set and lock the
	-- player out of the wheel for the rest of the session.
	local ok, result = pcall(performSpin, player, data)
	spinning[player] = nil

	if not ok then
		warn(`[SpinService] spin failed for {player.Name}: {result}`)
		return failure(ERRORS.Failed, data)
	end

	return result
end

local function validateSpin(_player: Player, ...): (boolean, string?)
	-- SpinRequest carries no payload; anything sent with it is a probe.
	return Validators.checkTypes(table.pack(...), {})
end

function SpinService.onPlayerRemoving(player: Player)
	spinning[player] = nil
end

function SpinService.init()
	-- SpinLogic is Roblox-free by design and cannot require these itself; see
	-- the note at the top of that file.
	SpinLogic.configure(SpinConfig, SkinCatalog)

	Remotes.register({
		Name = RemoteNames.SpinRequest,
		Type = "Function",
		Handler = onSpinRequest,
		Validator = validateSpin,
		RateLimit = SPIN_RATE,
		WindowSeconds = SPIN_WINDOW,
	})

	serviceTrove:Connect(Players.PlayerRemoving, SpinService.onPlayerRemoving)
end

return SpinService
