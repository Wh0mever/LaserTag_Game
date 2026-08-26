--!nonstrict
--[[
	tests/harness/env.luau
	A Roblox-shaped sandbox for running this game's server code outside Studio.

	Most of this repository can only execute inside Roblox: it calls
	game:GetService, builds Instances and requires sibling ModuleScripts through
	the DataModel. Those modules are the majority of the codebase and the unit
	tests cannot reach any of them, so until something actually runs them the
	first evidence that they work is a playtest.

	This closes that gap for the parts that are pure computation over the Roblox
	API — above all the world builder, which turns the map definitions into
	several thousand parts and had never been executed at all.

	It is deliberately NOT a Roblox emulator. Instances, Vector3, CFrame, Color3
	and Enum are the real implementations from Lune (backed by Roblox's own class
	database, so a misspelled property or class fails here exactly as it would in
	Studio). Everything else is a stand-in that is honest about what it does:
	services are plain containers, the module tree resolves to files on disk, and
	anything that would need a running game (players, replication, DataStores)
	is absent by design rather than faked into looking like it works.

	Run it with Lune:  lune run tests/harness/world
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local task = require("@lune/task")

local Env = {}

local REPO_ROOT = "."

-- Declared before anything uses it: a `local function` further down would be a
-- different variable, and the sandbox would silently call a nil global.
local recorded: { [string]: number } = {}

Env.collisionGroups = {}
Env.collisionRules = {}

local function record(what: string)
	recorded[what] = (recorded[what] or 0) + 1
end

function Env.calls(): { [string]: number }
	return recorded
end

--------------------------------------------------------------------------------
-- Module tree
--
-- `require(Shared.Config.WeaponConfig)` has to resolve to src/shared/Config/
-- WeaponConfig.luau. Rather than mirror the DataModel, each node is a handle
-- that knows its own directory and hands out child handles on demand, so
-- indexing, WaitForChild and script.Parent all behave the way the code expects.
--------------------------------------------------------------------------------

local handleCache: { [string]: any } = {}
local moduleResults: { [string]: any } = {}

-- Lune's filesystem calls are async and cannot run inside a metamethod, and
-- resolving a module handle happens inside __index. So the tree is walked once,
-- up front, into a plain lookup that indexing can consult freely.
local pathKind: { [string]: string } = {}

local function indexTree(dir: string)
	pathKind[dir] = "dir"
	for _, entry in fs.readDir(dir) do
		local full = dir .. "/" .. entry
		if fs.isDir(full) then
			indexTree(full)
		elseif entry:match("%.luau$") then
			pathKind[full:gsub("%.luau$", "")] = "file"
		end
	end
end

local Handle = {}
Handle.__index = function(self, key)
	local own = rawget(Handle, key)
	if own then
		return own
	end

	local child = Env.handleFor(self.__dir .. "/" .. key)
	if not child then
		error(`{key} is not a valid member of {self.__name}`, 2)
	end
	return child
end

Handle.__tostring = function(self)
	return self.__name
end

function Handle:WaitForChild(name: string, _timeout: number?)
	-- Explicitly attached children win: a service node may be mounted under a
	-- name that does not match its directory (ReplicatedStorage.Shared lives at
	-- src/shared), and the DataModel name is the one the code asks for.
	local child = rawget(self, name) or Env.handleFor(self.__dir .. "/" .. name)
	if not child then
		error(`Infinite yield possible on {self.__name}:WaitForChild("{name}")`, 2)
	end
	return child
end

function Handle:FindFirstChild(name: string)
	return rawget(self, name) or Env.handleFor(self.__dir .. "/" .. name)
end

function Handle:GetChildren()
	local children = {}
	local prefix = self.__dir .. "/"
	for path, _ in pathKind do
		-- Direct children only: the segment after the prefix must be the last.
		if path:sub(1, #prefix) == prefix and not path:sub(#prefix + 1):find("/") then
			local child = Env.handleFor(path)
			if child then
				table.insert(children, child)
			end
		end
	end
	return children
end

--[[
	A handle for a path that may be either a directory or a .luau file. Returns
	nil when neither exists, which is what lets FindFirstChild answer honestly.
]]
function Env.handleFor(path: string): any?
	path = path:gsub("//", "/")

	local cached = handleCache[path]
	if cached then
		return cached
	end

	local kind = pathKind[path]
	if not kind then
		return nil
	end

	local isFile = kind == "file"
	local filePath = path .. ".luau"

	local name = path:match("([^/]+)$") or path
	local parentDir = path:match("^(.*)/[^/]+$")

	local handle = setmetatable({
		__dir = path,
		__file = if isFile then filePath else nil,
		__name = name,
		__parentDir = parentDir,
	}, Handle)

	rawset(handle, "Name", name)
	handleCache[path] = handle

	-- `script.Parent` is by far the most common way this codebase reaches a
	-- sibling module, and `script.Parent.Parent` is common too, so the parent is
	-- a full handle rather than a stub — it needs its own parent in turn. Cached
	-- before recursing, so a directory that is its own ancestor cannot loop.
	if parentDir then
		rawset(handle, "Parent", Env.handleFor(parentDir))
	end

	return handle
end

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------

local services: { [string]: any } = {}

local function makeInstanceService(className: string)
	local inst = roblox.Instance.new(className)
	return inst
end

local function buildServices()
	-- Real Instances: the world builder parents actual parts into these.
	services.Workspace = makeInstanceService("Folder")
	services.Workspace.Name = "Workspace"
	services.Lighting = makeInstanceService("Folder")
	services.Lighting.Name = "Lighting"
	services.Teams = makeInstanceService("Folder")
	services.Teams.Name = "Teams"
	services.ServerStorage = makeInstanceService("Folder")
	services.ServerStorage.Name = "ServerStorage"
	services.StarterGui = makeInstanceService("Folder")
	services.StarterGui.Name = "StarterGui"
	services.SoundService = makeInstanceService("Folder")
	services.SoundService.Name = "SoundService"

	-- Module trees: these resolve to files rather than Instances.
	services.ReplicatedStorage = Env.handleFor(REPO_ROOT .. "/src")
	local rs = services.ReplicatedStorage
	rawset(rs, "Shared", Env.handleFor(REPO_ROOT .. "/src/shared"))
	rawset(rs, "Name", "ReplicatedStorage")

	services.ServerScriptService = Env.handleFor(REPO_ROOT .. "/src")
	rawset(services.ServerScriptService, "Server", Env.handleFor(REPO_ROOT .. "/src/server"))

	-- Recording rather than silent: collision groups are how the one-way spawn
	-- doors work, and a harness that swallowed these calls would report a
	-- working world while the doors let everyone through.
	services.PhysicsService = {
		RegisterCollisionGroup = function(_self, name: string)
			if Env.collisionGroups[name] then
				error(`collision group "{name}" is already registered`, 2)
			end
			Env.collisionGroups[name] = true
			record("PhysicsService:RegisterCollisionGroup")
		end,
		UnregisterCollisionGroup = function(_self, name: string)
			Env.collisionGroups[name] = nil
		end,
		IsCollisionGroupRegistered = function(_self, name: string)
			return Env.collisionGroups[name] == true
		end,
		CollisionGroupSetCollidable = function(_self, a: string, b: string, collidable: boolean)
			table.insert(Env.collisionRules, { a = a, b = b, collidable = collidable })
			record("PhysicsService:CollisionGroupSetCollidable")
		end,
		GetRegisteredCollisionGroups = function(_self)
			local groups = {}
			for name in Env.collisionGroups do
				table.insert(groups, { name = name })
			end
			return groups
		end,
	}

	-- Enough of Players to let modules evaluate and register handlers. There is
	-- nobody in this game, so GetPlayers is genuinely empty rather than faked.
	local function signal()
		return {
			Connect = function(_self, fn)
				record("event:Connect")
				return { Disconnect = function() end, Connected = true, fn = fn }
			end,
			Once = function(_self, fn)
				return { Disconnect = function() end, Connected = true, fn = fn }
			end,
			Wait = function()
				error("[harness] nothing will ever fire this event", 2)
			end,
		}
	end

	services.Players = {
		Name = "Players",
		CharacterAutoLoads = false,
		RespawnTime = 3,
		PlayerAdded = signal(),
		PlayerRemoving = signal(),
		GetPlayers = function()
			return {}
		end,
		GetPlayerFromCharacter = function()
			return nil
		end,
		GetNameFromUserIdAsync = function(_self, userId)
			return `Player{userId}`
		end,
	}

	services.RunService = {
		Name = "RunService",
		Heartbeat = signal(),
		Stepped = signal(),
		RenderStepped = signal(),
		IsServer = function()
			return true
		end,
		IsClient = function()
			return false
		end,
		IsStudio = function()
			return false
		end,
	}

	-- DataStores fail closed here: every call errors, which is exactly the
	-- branch production code must survive, and it keeps the harness from
	-- reporting persistence as working when nothing was stored.
	local function unavailable()
		error("[harness] DataStore is not available", 2)
	end

	services.DataStoreService = {
		Name = "DataStoreService",
		GetDataStore = function()
			return {
				GetAsync = unavailable,
				SetAsync = unavailable,
				UpdateAsync = unavailable,
				RemoveAsync = unavailable,
			}
		end,
		GetOrderedDataStore = function()
			return { GetSortedAsync = unavailable, SetAsync = unavailable }
		end,
	}

	services.TeleportService = { Name = "TeleportService" }
	services.HttpService = {
		Name = "HttpService",
		GenerateGUID = function(_self)
			return "00000000-0000-0000-0000-000000000000"
		end,
		JSONEncode = function(_self, value)
			return tostring(value)
		end,
	}
	services.MarketplaceService = { Name = "MarketplaceService" }
	services.TweenService = { Name = "TweenService" }
	services.CollectionService = {
		Name = "CollectionService",
		GetTagged = function()
			return {}
		end,
	}
	services.AnalyticsService = { Name = "AnalyticsService" }
end

--------------------------------------------------------------------------------
-- Globals
--------------------------------------------------------------------------------

local function buildEnvironment(scriptHandle: any)
	local game = {
		GetService = function(_self, name: string)
			local service = services[name]
			if not service then
				error(`[harness] service "{name}" is not provided by this sandbox`, 2)
			end
			return service
		end,
		BindToClose = function(_self, _fn)
			record("game:BindToClose")
		end,
	}

	local env
	env = {
		-- Real Roblox datatypes: a wrong property name or class fails here the
		-- same way it would in Studio.
		Instance = roblox.Instance,
		Vector3 = roblox.Vector3,
		Vector2 = roblox.Vector2,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Enum = roblox.Enum,
		Rect = roblox.Rect,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		NumberSequenceKeypoint = roblox.NumberSequenceKeypoint,
		ColorSequence = roblox.ColorSequence,
		ColorSequenceKeypoint = roblox.ColorSequenceKeypoint,
		BrickColor = roblox.BrickColor,
		Font = roblox.Font,
		Ray = roblox.Ray,
		Region3 = roblox.Region3,
		PhysicalProperties = roblox.PhysicalProperties,

		-- A property bag only. Nothing here casts a ray: there is no physics
		-- engine, so hit detection is covered by the unit tests over the pure
		-- damage and spread maths instead.
		RaycastParams = {
			new = function()
				return {
					FilterType = nil,
					FilterDescendantsInstances = {},
					IgnoreWater = false,
					CollisionGroup = "Default",
					RespectCanCollide = false,
				}
			end,
		},
		OverlapParams = {
			new = function()
				return { FilterType = nil, FilterDescendantsInstances = {}, MaxParts = 0 }
			end,
		},

		-- Lune has no Random. Seeded on purpose: a harness run that shuffles
		-- differently every time would report flaky results for deterministic
		-- code.
		Random = {
			new = function(seed: number?)
				local state = seed or 20260826
				local function nextValue()
					state = (state * 1103515245 + 12345) % 2147483648
					return state / 2147483648
				end
				return {
					NextNumber = function(_self, min: number?, max: number?)
						local value = nextValue()
						if min and max then
							return min + value * (max - min)
						end
						return value
					end,
					NextInteger = function(_self, min: number, max: number)
						return math.floor(min + nextValue() * (max - min + 1))
					end,
					Clone = function(_self)
						return _self
					end,
				}
			end,
		},

		game = game,
		workspace = services.Workspace,
		script = scriptHandle,

		task = {
			wait = function(_t)
				record("task.wait")
				return 0
			end,
			spawn = function(fn, ...)
				record("task.spawn")
				fn(...)
			end,
			defer = function(fn, ...)
				record("task.defer")
				fn(...)
			end,
			delay = function(_t, fn, ...)
				record("task.delay")
				return fn and fn(...)
			end,
			cancel = function() end,
		},

		require = function(target)
			return Env.requireHandle(target)
		end,

		warn = function(...)
			record("warn")
			local parts = {}
			for _, v in { ... } do
				table.insert(parts, tostring(v))
			end
			print("[warn] " .. table.concat(parts, " "))
		end,

		print = print,
		error = error,
		assert = assert,
		pcall = pcall,
		xpcall = xpcall,
		select = select,
		type = type,
		typeof = roblox.typeof or type,
		tostring = tostring,
		tonumber = tonumber,
		ipairs = ipairs,
		pairs = pairs,
		next = next,
		setmetatable = setmetatable,
		getmetatable = getmetatable,
		rawget = rawget,
		rawset = rawset,
		rawequal = rawequal,
		rawlen = rawlen,
		unpack = table.unpack,
		math = math,
		table = table,
		string = string,
		os = { time = os.time, clock = os.clock, date = os.date },
		coroutine = coroutine,
		utf8 = utf8,
		buffer = buffer,
		tick = os.clock,
		time = os.time,
	}
	env._G = env

	return env
end

--[[
	require() for a module handle. Results are cached, matching Roblox's
	one-instance-one-result behaviour, which several modules rely on for state.
]]
function Env.requireHandle(target: any): any
	if type(target) ~= "table" or not rawget(target, "__file") then
		error("[harness] require() expects a module handle from the sandbox tree", 2)
	end

	local file = target.__file
	local cached = moduleResults[file]
	if cached ~= nil then
		return cached
	end

	-- Guard against a require cycle rather than recursing until the stack dies.
	moduleResults[file] = false

	local source = fs.readFile(file)
	local chunk = luau.load(source, {
		debugName = file,
		environment = buildEnvironment(target),
	})

	local result = chunk()
	moduleResults[file] = result
	return result
end

--[[
	Load a module by repository path, e.g. "src/server/World/MapBuilder".
]]
function Env.load(modulePath: string): any
	local handle = Env.handleFor(REPO_ROOT .. "/" .. modulePath)
	if not handle then
		error(`[harness] no module at {modulePath}`)
	end
	return Env.requireHandle(handle)
end

function Env.workspace()
	return services.Workspace
end

function Env.service(name: string)
	return services[name]
end

function Env.reset()
	handleCache = {}
	moduleResults = {}
	recorded = {}
	buildServices()
end

indexTree(REPO_ROOT .. "/src")
buildServices()

return Env
