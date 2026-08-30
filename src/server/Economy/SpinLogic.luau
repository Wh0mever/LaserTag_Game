--!nonstrict
--[[
	SpinLogic.luau
	The reward wheel's arithmetic: when a spin is free, which segment a roll
	lands on, and what a segment does to a profile. Pure — no Roblox API, no
	clock and no Player — so tests/SpinLogic.spec.luau exercises every band
	boundary and the pity guarantee off Roblox.

	Config is INJECTED for the same reason ShopLogic's catalog is: a module under
	src/server cannot reach src/shared without the DataModel, and duplicating the
	segment weights here would let the published odds drift from the ones the
	wheel actually rolls. SpinService injects the real SpinConfig and SkinCatalog
	at boot; the spec injects those same modules by relative path.

	Randomness is supplied by the caller as `rngValue` in [0, 1). Keeping the RNG
	outside means a test can name an exact point on the wheel, and the server
	stays the only thing that ever produces the number.
]]

local SpinLogic = {}

SpinLogic.RewardKinds = {
	None = "none",
	Coins = "coins",
	Skin = "skin",
	Duplicate = "duplicate",
}

local Kinds = SpinLogic.RewardKinds

local NOTHING_LABEL = "Пусто"

local spinConfig: any = nil
local catalog: any = nil

--[[
	Supply the wheel config and skin catalog.
	`config` expects the SpinConfig interface: `Segments`, `FREE_SPIN_INTERVAL`,
	`PITY_THRESHOLD` and `DUPLICATE_REFUND_RATIO`.
]]
function SpinLogic.configure(config: any, skinCatalog: any)
	spinConfig = config
	catalog = skinCatalog
end

local function isFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

--[[
	Server time at which this profile's next free spin unlocks.

	Returns math.huge when nothing has been configured yet, so an unconfigured
	module reports "never free" rather than handing out an unlimited free spin.
]]
function SpinLogic.nextFreeAt(spinState: any): number
	if not spinConfig then
		return math.huge
	end

	local last = if type(spinState) == "table" then spinState.LastFreeSpinAt else nil
	if not isFiniteNumber(last) then
		last = 0
	end

	return last + spinConfig.FREE_SPIN_INTERVAL
end

--[[
	Whether the free spin is available at `now` (a workspace:GetServerTimeNow()
	value on the server). A profile that has never spun has LastFreeSpinAt = 0,
	which is decades in the past, so a new player's first spin is always free.
]]
function SpinLogic.canSpinFree(spinState: any, now: any): boolean
	if not isFiniteNumber(now) then
		return false
	end

	return now >= SpinLogic.nextFreeAt(spinState)
end

--[[
	Record that the free spin has just been taken. Separate from applyResult
	because only the caller knows whether this spin was the free one or a paid
	extra, and only the caller owns a clock.
]]
function SpinLogic.markFreeSpin(spinState: any, now: any): boolean
	if type(spinState) ~= "table" or not isFiniteNumber(now) then
		return false
	end

	spinState.LastFreeSpinAt = now
	return true
end

--[[
	Collect the segments eligible for a roll, with their index on the wheel so
	the client can animate to the right slot. `onlyKind` restricts the set, which
	is how pity narrows the wheel to skins.
]]
local function collect(segments: any, onlyKind: string?): ({ any }, number)
	local entries, total = {}, 0

	for index, segment in ipairs(segments) do
		local weight = segment.weight
		if isFiniteNumber(weight) and weight > 0 and (onlyKind == nil or segment.kind == onlyKind) then
			total += weight
			table.insert(entries, { segment = segment, index = index, weight = weight })
		end
	end

	return entries, total
end

--[[
	The first entry whose cumulative weight strictly exceeds the scaled roll.

	Bands are half-open: with weights 30, 25, ... a roll in [0, 0.30) is the
	first segment and [0.30, 0.55) the second. Strict `<` is what keeps the two
	from overlapping, so no weight is counted twice and the published percentages
	are the real ones.
]]
local function pickWeighted(entries: { any }, totalWeight: number, rngValue: number): (any, number)
	local roll = rngValue * totalWeight
	local cumulative = 0

	for _, entry in ipairs(entries) do
		cumulative += entry.weight
		if roll < cumulative then
			return entry.segment, entry.index
		end
	end

	-- Only reachable for rngValue >= 1, or a float sum that lands a hair under
	-- the total. The last band owns the top of the wheel either way.
	local last = entries[#entries]
	return last.segment, last.index
end

--[[
	Pick a segment for one spin.
	`rngValue` is in [0, 1); `pity` is the profile's consecutive-spins-without-a-
	skin counter. Returns the segment table and its 1-based index in
	SpinConfig.Segments, or (nil, 0) if the wheel is unusable.

	At or above SpinConfig.PITY_THRESHOLD the roll is restricted to the skin
	segments, so the guarantee is exact rather than merely likely.
]]
function SpinLogic.roll(rngValue: any, pity: any): (any, number)
	if not spinConfig or type(spinConfig.Segments) ~= "table" then
		return nil, 0
	end

	-- A negative or non-finite roll resolves to the bottom of the wheel rather
	-- than falling through pickWeighted's loop to the rarest segment.
	local value = if isFiniteNumber(rngValue) then math.max(rngValue, 0) else 0
	local counter = if isFiniteNumber(pity) then pity else 0

	local entries, total = {}, 0
	if counter >= spinConfig.PITY_THRESHOLD then
		entries, total = collect(spinConfig.Segments, "skin")
	end

	-- A wheel with no skin segments at all cannot satisfy pity; roll the full
	-- wheel instead of returning nothing and swallowing the spin.
	if #entries == 0 then
		entries, total = collect(spinConfig.Segments, nil)
	end

	if #entries == 0 or total <= 0 then
		return nil, 0
	end

	return pickWeighted(entries, total, value)
end

--[[
	Apply one segment to a profile.
	Returns (rewardKind, coinsAwarded, label) where rewardKind is one of
	SpinLogic.RewardKinds.

	A skin the player already owns pays SpinConfig.DUPLICATE_REFUND_RATIO of its
	price instead, so the rarest segments never resolve to nothing.

	Pity resets on any skin segment — a duplicate is still the wheel paying out
	the thing pity exists to guarantee — and advances on everything else.
]]
function SpinLogic.applyResult(data: any, segment: any): (string, number, string)
	if not spinConfig or not catalog or type(segment) ~= "table" then
		return Kinds.None, 0, NOTHING_LABEL
	end

	if
		type(data) ~= "table"
		or type(data.Coins) ~= "number"
		or type(data.OwnedSkins) ~= "table"
		or type(data.Spin) ~= "table"
	then
		return Kinds.None, 0, NOTHING_LABEL
	end

	local spin = data.Spin
	local pity = if isFiniteNumber(spin.Pity) then spin.Pity else 0
	spin.TotalSpins = (if isFiniteNumber(spin.TotalSpins) then spin.TotalSpins else 0) + 1

	if segment.kind == "coins" then
		local amount = if isFiniteNumber(segment.coins) then math.max(math.floor(segment.coins), 0) else 0
		data.Coins += amount
		spin.Pity = pity + 1
		return Kinds.Coins, amount, segment.label or `{amount} Coins`
	end

	if segment.kind == "skin" then
		local skin = catalog.get(segment.skinId)
		if not skin then
			-- A segment naming a skin that has been retired must not silently
			-- eat the spin: advance pity so the next one is closer to a payout.
			spin.Pity = pity + 1
			return Kinds.None, 0, NOTHING_LABEL
		end

		spin.Pity = 0

		if not data.OwnedSkins[segment.skinId] then
			data.OwnedSkins[segment.skinId] = true
			return Kinds.Skin, 0, segment.label or skin.displayName
		end

		local price = if isFiniteNumber(skin.price) then skin.price else 0
		local refund = math.max(math.floor(price * spinConfig.DUPLICATE_REFUND_RATIO), 0)
		data.Coins += refund
		return Kinds.Duplicate, refund, `{skin.displayName} duplicate — +{refund} Coins`
	end

	spin.Pity = pity + 1
	return Kinds.None, 0, NOTHING_LABEL
end

return SpinLogic
