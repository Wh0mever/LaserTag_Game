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
Env.renderBindings = {}

-- Desktop unless a scenario says otherwise; see Env.setDevice.
Env.device = { TouchEnabled = false, KeyboardEnabled = true, MouseEnabled = true }
Env.boundActions = {}

local function record(what: string)
	recorded[what] = (recorded[what] or 0) + 1
end

function Env.calls(): { [string]: number }
	return recorded
end

--[[
	Runs every render-step binding once, lowest priority first, the way Roblox
	orders them. Nothing here renders — the point is the ordering, which is the
	whole mechanism behind bindings that exist to overwrite what an engine
	binding at a lower priority just wrote.

	Returns the bindings that threw, as { name, err }. A binding that errors on
	a real client stops running for the rest of the session, so swallowing that
	here would be the exact "green test over broken code" this harness exists to
	prevent — the caller is expected to assert the list is empty.
]]
function Env.stepRender(): { { name: string, err: string } }
	local ordered = {}
	for name, binding in Env.renderBindings do
		table.insert(ordered, { name = name, priority = binding.priority, callback = binding.callback })
	end
	table.sort(ordered, function(a, b)
		if a.priority ~= b.priority then
			return a.priority < b.priority
		end
		return a.name < b.name
	end)

	local failures = {}
	for _, entry in ordered do
		if type(entry.callback) == "function" then
			local ok, err = pcall(entry.callback, 1 / 60)
			if not ok then
				table.insert(failures, { name = entry.name, err = tostring(err) })
			end
		end
	end
	return failures
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

--------------------------------------------------------------------------------
-- Runtime methods Lune's data model does not carry
--
-- Lune models the Roblox *file format*, so Instances have properties but no
-- signals. Code that listens for a property change is perfectly ordinary and
-- would otherwise fail here for a reason that has nothing to do with it being
-- wrong. These are implemented once, for every class, and never fire — nothing
-- in this sandbox changes on its own.
--------------------------------------------------------------------------------

local function inertSignal()
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

Env.inertSignal = inertSignal

--[[
	A signal that actually fires.

	Everything else in this sandbox hands out inertSignal, which remembers the
	handler and never calls it. That is fine for a module that merely has to
	survive connecting to something, and useless for testing anything that
	reacts to a change — which on a phone is most of what matters, because the
	touch buttons appear and disappear with the match state.
]]
local function liveSignal()
	local handlers = {}
	local sig
	sig = {
		Connect = function(_self, fn)
			record("event:Connect")
			local conn = { Connected = true, fn = fn }
			conn.Disconnect = function()
				conn.Connected = false
			end
			table.insert(handlers, conn)
			return conn
		end,
		Once = function(_self, fn)
			local conn
			conn = sig:Connect(function(...)
				conn:Disconnect()
				fn(...)
			end)
			return conn
		end,
		Wait = function()
			error("[harness] Wait() would block forever; drive the signal instead", 2)
		end,
		Fire = function(_self, ...)
			-- Copied first: a handler that disconnects itself would otherwise
			-- reshape the list mid-iteration.
			local snapshot = table.clone(handlers)
			for _, conn in snapshot do
				if conn.Connected then
					conn.fn(...)
				end
			end
		end,
	}
	return sig
end

Env.liveSignal = liveSignal

-- Attribute-changed signals, per instance and per attribute name. Keyed weakly
-- so a discarded character does not pin its signals for the run.
local attributeSignals = setmetatable({}, { __mode = "k" })

local function attributeSignal(instance: any, name: string)
	local perInstance = attributeSignals[instance]
	if not perInstance then
		perInstance = {}
		attributeSignals[instance] = perInstance
	end
	if not perInstance[name] then
		perInstance[name] = liveSignal()
	end
	return perInstance[name]
end

--[[
	Sets an attribute AND fires the listeners, which raw SetAttribute cannot do
	here: Lune has no attribute change events, so a test that writes the
	attribute directly leaves every controller watching it none the wiser.
	Scenarios should always go through this.
]]
function Env.setAttribute(instance: any, name: string, value: any)
	instance:SetAttribute(name, value)
	attributeSignal(instance, name):Fire(value)
end

--[[
	Roblox's typeof(), which Lune does not provide.

	Every Lune Roblox value is plain `userdata`, with nothing on the metatable to
	tell them apart, so plain `type()` reports "userdata" for all of them. That
	matters because guard clauses across this codebase are written as
	`typeof(x) == "Instance"` — with the fallback those asserts fail on perfectly
	good arguments, and the harness reports bugs that are its own.

	Each kind is identified by a property only it answers to.
]]
local function probe(value: any, property: string): boolean
	local ok, result = pcall(function()
		return (value :: any)[property]
	end)
	return ok and result ~= nil
end

local function harnessTypeof(value: any): string
	local basic = type(value)
	if basic ~= "userdata" then
		return basic
	end

	if probe(value, "ClassName") then
		return "Instance"
	end
	if probe(value, "EnumType") then
		return "EnumItem"
	end
	if probe(value, "LookVector") then
		return "CFrame"
	end
	if probe(value, "Magnitude") then
		return if probe(value, "Z") then "Vector3" else "Vector2"
	end
	if probe(value, "R") and probe(value, "B") then
		return "Color3"
	end
	if probe(value, "Scale") and probe(value, "Offset") then
		return "UDim"
	end
	if probe(value, "X") and probe(value, "Y") then
		return "UDim2"
	end
	if probe(value, "Keypoints") then
		return "NumberSequence"
	end
	if probe(value, "Direction") then
		return "Ray"
	end

	return "userdata"
end

roblox.implementMethod("Instance", "GetPropertyChangedSignal", function()
	return inertSignal()
end)

roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(self, name: string)
	return attributeSignal(self, name)
end)

--[[
	Events are read as properties (`button.Activated:Connect(...)`), so they need
	implementProperty rather than implementMethod. Declared on the base classes so
	every button, frame and label inherits them.

	Each is a live signal, cached per instance and per event name. Both halves of
	that matter and neither used to hold: the old version handed back a fresh
	inertSignal on every access, so a handler connected to button.Activated went
	onto a signal nobody kept and nothing could ever fire. Connecting to a button
	was a no-op that looked exactly like a working one, which is why no UI
	interaction in this game had ever actually been exercised.
]]
local instanceEventSignals = setmetatable({}, { __mode = "k" })

local function instanceEvent(instance: any, eventName: string)
	local perInstance = instanceEventSignals[instance]
	if not perInstance then
		perInstance = {}
		instanceEventSignals[instance] = perInstance
	end
	if not perInstance[eventName] then
		perInstance[eventName] = liveSignal()
	end
	return perInstance[eventName]
end

Env.instanceEvent = instanceEvent

for _, entry in
	{
		{ class = "GuiButton", events = { "Activated", "MouseButton1Click", "MouseButton1Down", "MouseButton1Up" } },
		{ class = "GuiObject", events = { "MouseEnter", "MouseLeave", "InputBegan", "InputEnded", "InputChanged" } },
		{ class = "Instance", events = { "Changed", "ChildAdded", "ChildRemoved", "AncestryChanged", "Destroying" } },
	}
do
	for _, eventName in entry.events do
		roblox.implementProperty(entry.class, eventName, function(self)
			return instanceEvent(self, eventName)
		end)
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
	-- Real service classes, not stand-in Folders. Lune validates every property
	-- against Roblox's class database, so `Lighting.Technology` and
	-- `Workspace.CurrentCamera` are checked for real — and a typo in one fails
	-- here instead of silently doing nothing in Studio.
	services.Workspace = makeInstanceService("Workspace")
	services.Lighting = makeInstanceService("Lighting")
	services.Teams = makeInstanceService("Teams")
	services.ServerStorage = makeInstanceService("ServerStorage")
	services.StarterGui = makeInstanceService("StarterGui")
	services.SoundService = makeInstanceService("SoundService")

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
		-- The callback is kept, not discarded: a binding that exists is not the
		-- same claim as a binding that does the right thing when a frame passes,
		-- and Env.stepRender() is how a scenario asks for that second one.
		BindToRenderStep = function(_self, name: string, priority: number?, callback: any)
			record("RunService:BindToRenderStep")
			Env.renderBindings[name] = { priority = priority or 0, callback = callback }
		end,
		UnbindFromRenderStep = function(_self, name: string)
			Env.renderBindings[name] = nil
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

	----------------------------------------------------------------------------
	-- Client side
	--
	-- Enough of a local player for client modules to evaluate. There is no
	-- rendering here, so nothing that draws is verified — but a misspelled
	-- property or a bad require fails, and those are the faults that stop a
	-- client booting at all.
	----------------------------------------------------------------------------

	local camera = roblox.Instance.new("Camera")
	camera.Name = "Camera"
	services.Workspace.CurrentCamera = camera

	local playerGui = roblox.Instance.new("Folder")
	playerGui.Name = "PlayerGui"

	--[[
		Attributes on the local player are real state, not stubs.

		They used to be a black hole: GetAttribute always nil, SetAttribute a
		no-op, GetAttributeChangedSignal a fresh inert signal on every call — so
		connecting to one was not merely useless, it was a different dead signal
		each time. Every client check therefore ran against a player who was
		permanently not loaded, on no team, and never in a match. That is a large
		part of the game whose behaviour could not be observed at all, and it is
		why the touch controls — which appear only during a match — were never
		once exercised.

		SetAttribute fires the change signal, as Roblox's does.
	]]
	local attributes = {}

	local localPlayer = {
		Name = "HarnessPlayer",
		DisplayName = "HarnessPlayer",
		UserId = 1,
		Character = nil,
		PlayerGui = playerGui,
		CharacterAdded = signal(),
		CharacterRemoving = signal(),
		GetAttribute = function(_self, name: string)
			return attributes[name]
		end,
		SetAttribute = function(self, name: string, value: any)
			if attributes[name] == value then
				return
			end
			attributes[name] = value
			attributeSignal(self, name):Fire(value)
		end,
		GetAttributeChangedSignal = function(self, name: string)
			return attributeSignal(self, name)
		end,
		FindFirstChild = function(_self, name: string)
			if name == "PlayerGui" then
				return playerGui
			end
			return nil
		end,
		WaitForChild = function(_self, name: string)
			if name == "PlayerGui" then
				return playerGui
			end
			return nil
		end,
		IsFriendsWith = function()
			return false
		end,
	}
	services.Players.LocalPlayer = localPlayer

	services.UserInputService = {
		Name = "UserInputService",
		TouchEnabled = Env.device.TouchEnabled,
		KeyboardEnabled = Env.device.KeyboardEnabled,
		MouseEnabled = Env.device.MouseEnabled,
		GamepadEnabled = false,
		-- Live, not inert: the touch controls are driven entirely through these,
		-- and a scenario has to be able to put a finger on the glass.
		InputBegan = liveSignal(),
		InputEnded = liveSignal(),
		InputChanged = liveSignal(),
		WindowFocusReleased = signal(),
		GetMouseDelta = function()
			return roblox.Vector2.new(0, 0)
		end,
	}

	--[[
		ContextActionService that remembers.

		The previous stub counted BindAction and threw everything else away,
		which made every touch button in the game untestable: a button bound
		with no title, positioned off screen, or never bound at all looked
		exactly like a working one. On a phone those buttons ARE the controls,
		so the thing worth asserting is what the player can reach — and that
		needs the bindings kept.

		Env.boundActions is the touch control surface as the engine would build
		it. Env.pressAction drives a handler the way a thumb would.
	]]
	Env.boundActions = {}

	services.ContextActionService = {
		Name = "ContextActionService",
		BindAction = function(_self, name: string, handler, createTouchButton: boolean, ...)
			record("ContextActionService:BindAction")
			Env.boundActions[name] = {
				name = name,
				handler = handler,
				touchButton = createTouchButton == true,
				keys = { ... },
				title = nil,
				position = nil,
				image = nil,
			}
		end,
		UnbindAction = function(_self, name: string)
			Env.boundActions[name] = nil
		end,
		SetPosition = function(_self, name: string, position)
			local action = Env.boundActions[name]
			if action then
				action.position = position
			end
		end,
		SetTitle = function(_self, name: string, title)
			local action = Env.boundActions[name]
			if action then
				action.title = title
			end
		end,
		SetImage = function(_self, name: string, image)
			local action = Env.boundActions[name]
			if action then
				action.image = image
			end
		end,
		--[[
			A real ImageButton, so anything the game writes to it is validated
			against Roblox's class database the way every other Instance in this
			sandbox is. Returns nil for an unbound action, as the engine does —
			callers have to cope with that, because the button does not exist
			until the touch frame has been built.
		]]
		GetButton = function(_self, name: string)
			local action = Env.boundActions[name]
			if not action or not action.touchButton then
				return nil
			end
			if not action.button then
				local button = roblox.Instance.new("ImageButton")
				button.Name = name
				action.button = button
			end
			return action.button
		end,
	}

	services.TweenService = {
		Name = "TweenService",
		Create = function()
			return {
				Play = function() end,
				Cancel = function() end,
				Completed = signal(),
			}
		end,
	}

	--[[
		GetGuiInset reports the strip Roblox's own top bar occupies. Every screen
		in this game sets IgnoreGuiInset = true, so our GUI starts at y = 0 and
		anything placed near the top would otherwise sit UNDER the Roblox bar and
		be invisible. The numbers are a phone's: 36 tall on the top edge, nothing
		on the bottom.
	]]
	services.GuiService = {
		Name = "GuiService",
		Select = function() end,
		GetGuiInset = function()
			return roblox.Vector2.new(0, 36), roblox.Vector2.new(0, 0)
		end,
	}
	services.Debris = { Name = "Debris", AddItem = function() end }
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
	services.CollectionService = {
		Name = "CollectionService",
		GetTagged = function()
			return {}
		end,
	}
	services.AnalyticsService = { Name = "AnalyticsService" }
end

--------------------------------------------------------------------------------
-- CFrame.lookAt, corrected
--
-- Lune's CFrame.lookAt does not agree with Roblox's, and not uniformly: it is
-- right for a target along +/-X and inverted for one along +/-Z.
--
--   lookAt(origin, +X)  Lune Look = (1,0,0)   Roblox (1,0,0)    agree
--   lookAt(origin, +Z)  Lune Look = (0,0,-1)  Roblox (0,0,1)    opposite
--
-- Roblox defines it as: the CFrame sits at `at` with .LookVector pointing toward
-- `target`, and .LookVector is the NEGATIVE local Z axis. So the local +Z column
-- is -forward, and NormalId.Front — the local -Z face — is the face that looks
-- at the target.
--
-- Under Lune's version every part built with a +/-Z lookAt comes out yawed 180
-- degrees, which turns a one-sided sign to face the wall. Nothing in the harness
-- caught it because nothing asserted a facing; that is now what
-- tests/harness/world.luau checks, and it needs this to be true first.
--
-- Rebuilt from the definition rather than by patching the result, so it is right
-- for every direction and not just the two that were checked by hand.
--------------------------------------------------------------------------------

local DEFAULT_UP = roblox.Vector3.new(0, 1, 0)
local FALLBACK_UP = roblox.Vector3.new(0, 0, 1)

local function correctedLookAt(at, target, up)
	up = up or DEFAULT_UP

	local forward = (target - at).Unit
	local back = -forward

	-- A forward parallel to the up hint leaves the cross product at zero and no
	-- rotation defined; Roblox picks another axis rather than returning NaN.
	local right = up:Cross(back)
	if right.Magnitude < 1e-6 then
		right = FALLBACK_UP:Cross(back)
	end
	right = right.Unit

	local realUp = back:Cross(right)

	return roblox.CFrame.new(
		at.X,
		at.Y,
		at.Z,
		right.X,
		realUp.X,
		back.X,
		right.Y,
		realUp.Y,
		back.Y,
		right.Z,
		realUp.Z,
		back.Z
	)
end

--[[
	`roblox.CFrame` with lookAt replaced. Everything else forwards to the real
	implementation, including the callable `CFrame.new`, so modules see a normal
	CFrame library.
]]
local CFrameShim = setmetatable({
	lookAt = correctedLookAt,
}, {
	__index = roblox.CFrame,
})

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
		CFrame = CFrameShim,
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

		-- Also a property bag: nothing tweens here, but the UI builds its whole
		-- timing table at module scope, so this has to exist for any screen to
		-- load at all.
		TweenInfo = {
			new = function(time, style, direction, repeatCount, reverses, delayTime)
				return {
					Time = time or 1,
					EasingStyle = style,
					EasingDirection = direction,
					RepeatCount = repeatCount or 0,
					Reverses = reverses or false,
					DelayTime = delayTime or 0,
				}
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
		typeof = harnessTypeof,
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

	-- On failure the cache entry is cleared. Leaving the cycle guard behind
	-- would hand `false` to every later requirer, so one broken module would
	-- report as a dozen confusing "attempt to index boolean" failures elsewhere
	-- and bury its own error.
	local ok, result = pcall(chunk)
	if not ok then
		moduleResults[file] = nil
		error(result, 0)
	end

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

--[[
	Swap in runtime-shaped stand-ins for the client scenario.

	Lune models Roblox's *data*, not its runtime: there are no signals, and
	properties that only exist while a game is running — a camera's ViewportSize
	above all — have no value to read. Server code barely notices, because it
	mostly builds Instances. Client code is made of exactly those things.

	So for the client the Workspace and LocalPlayer become plain tables that
	answer the runtime questions. Everything the UI actually creates is still a
	real Instance, so a bad property in a Frame or TextLabel still fails.
]]
-- implementMethod patches the class globally and refuses to do it twice, so the
-- method stubs below are installed once per process while everything else here
-- is rebuilt on each call. Without this, a scenario that boots a second device
-- to check it behaves differently dies on the second boot.
local clientMethodsInstalled = false

function Env.enableClientRuntime()
	local signal = inertSignal

	-- A real Camera, not a stand-in: client code parents things to it and hands
	-- it to functions that demand an Instance. ViewportSize only exists while a
	-- game runs, so it has no stored default — writing one makes it readable.
	local camera = roblox.Instance.new("Camera")
	camera.Name = "Camera"
	camera.ViewportSize = roblox.Vector2.new(1920, 1080)
	camera.CFrame = roblox.CFrame.new()
	camera.FieldOfView = 70
	camera.Parent = services.Workspace
	services.Workspace.CurrentCamera = camera

	-- No physics engine here. Raycast answering "nothing was hit" is honest:
	-- what a ray would have struck is decided by the pure damage and spread
	-- maths the unit tests already cover.
	if not clientMethodsInstalled then
		clientMethodsInstalled = true

		roblox.implementMethod("Workspace", "Raycast", function()
			record("workspace:Raycast")
			return nil
		end)
		roblox.implementMethod("Workspace", "GetPartBoundsInBox", function()
			return {}
		end)
		roblox.implementMethod("Workspace", "GetServerTimeNow", function()
			return os.clock()
		end)
	end

	-- The server creates ReplicatedStorage.Remotes at boot, so on a real client
	-- it always exists by the time anything waits for it. Here nothing has
	-- booted, and a client that hangs on WaitForChild would report as a failure
	-- of the module rather than of the sandbox. Any name resolves: the point is
	-- to let client code wire itself up, and the payload contracts are checked
	-- on the server side instead.
	local remoteCache: { [string]: any } = {}
	local function fakeRemote(name: string)
		local existing = remoteCache[name]
		if existing then
			return existing
		end

		local remote
		remote = {
			Name = name,
			ClassName = "RemoteEvent",
			OnClientEvent = signal(),
			FireServer = function()
				record("remote:FireServer")
			end,
			InvokeServer = function()
				record("remote:InvokeServer")
				return nil
			end,
			IsA = function(_self, className: string)
				return className == "RemoteEvent" or className == "Instance"
			end,
		}
		remoteCache[name] = remote
		return remote
	end

	local remotesFolder = {
		Name = "Remotes",
		FindFirstChild = function(_self, name: string)
			return fakeRemote(name)
		end,
		WaitForChild = function(_self, name: string)
			return fakeRemote(name)
		end,
		GetChildren = function()
			local all = {}
			for _, remote in remoteCache do
				table.insert(all, remote)
			end
			return all
		end,
	}
	rawset(services.ReplicatedStorage, "Remotes", remotesFolder)

	local localPlayer = services.Players.LocalPlayer
	localPlayer.FindFirstChildOfClass = function(_self, className: string)
		if className == "PlayerGui" then
			return localPlayer.PlayerGui
		end
		return nil
	end
	localPlayer.WaitForChildOfClass = localPlayer.FindFirstChildOfClass
	localPlayer.GetChildren = function()
		return { localPlayer.PlayerGui }
	end
	localPlayer.Kick = function() end
end

function Env.service(name: string)
	return services[name]
end

--[[
	Which device the sandbox pretends to be. Desktop by default, so every
	scenario written before this existed keeps the machine it was written for.

	Call before Env.enableClientRuntime(): the flags are read when the services
	are built, and a controller that has already decided it is on a PC does not
	revisit that.
]]
function Env.setDevice(profile: string)
	if profile == "phone" then
		-- A phone: touch and nothing else. This is the combination
		-- MouseLockController calls isTouchOnly, and the one every mobile bug
		-- in this game has hidden behind.
		Env.device = { TouchEnabled = true, KeyboardEnabled = false, MouseEnabled = false }
	elseif profile == "desktop" then
		Env.device = { TouchEnabled = false, KeyboardEnabled = true, MouseEnabled = true }
	elseif profile == "touchLaptop" then
		-- Touch AND a mouse. Must keep desktop behaviour: treating this as a
		-- phone would take the cursor away from someone who has one.
		Env.device = { TouchEnabled = true, KeyboardEnabled = true, MouseEnabled = true }
	else
		error(`[harness] unknown device profile "{profile}"`, 2)
	end
	buildServices()
end

--[[
	Presses a touch button the way a thumb does: Begin, then End.

	`hold` leaves the finger down, which is how the fire button is tested —
	an automatic weapon that only fires on release would pass a Begin-then-End
	check and be useless in a fight.
]]
function Env.pressAction(name: string, hold: boolean?): boolean
	local action = Env.boundActions[name]
	if not action then
		return false
	end

	action.handler(name, roblox.Enum.UserInputState.Begin, nil)
	if not hold then
		action.handler(name, roblox.Enum.UserInputState.End, nil)
	end
	return true
end

--[[
	A finger on the glass.

	Returns the InputObject stand-in so a scenario can move and lift the SAME
	touch — which matters, because the fire control identifies its trigger by
	the input object and must ignore a second finger elsewhere.

	`gameProcessed` mirrors what the engine reports: true when a GuiButton has
	already consumed the touch. The touch controls read it, so a test that
	always passed false would be testing a kinder engine than the real one.
]]
function Env.touchBegan(x: number, y: number, gameProcessed: boolean?): any
	local input = {
		UserInputType = roblox.Enum.UserInputType.Touch,
		UserInputState = roblox.Enum.UserInputState.Begin,
		Position = roblox.Vector3.new(x, y, 0),
	}
	services.UserInputService.InputBegan:Fire(input, gameProcessed == true)
	return input
end

function Env.touchEnded(input: any)
	input.UserInputState = roblox.Enum.UserInputState.End
	services.UserInputService.InputEnded:Fire(input, false)
end

--[[
	Lays out a GuiObject the way Roblox would.

	Lune has no layout engine, so AbsolutePosition and AbsoluteSize have no
	value at all until something writes one — reading them raises. Scenarios
	that hit-test against a control have to place it first.
]]
function Env.placeGui(gui: any, x: number, y: number, width: number, height: number)
	gui.AbsolutePosition = roblox.Vector2.new(x, y)
	gui.AbsoluteSize = roblox.Vector2.new(width, height)
end

function Env.releaseAction(name: string): boolean
	local action = Env.boundActions[name]
	if not action then
		return false
	end
	action.handler(name, roblox.Enum.UserInputState.End, nil)
	return true
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
