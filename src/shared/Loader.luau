--!nonstrict
--[[
	Loader.luau
	Two-pass module loader shared by the server and client bootstraps.

	Modules are discovered automatically inside a container folder, so adding a
	new service or controller never requires editing a bootstrap script.

	Contract for loaded modules:
	  * The module body must NOT yield (no WaitForChild without timeout, no
	    task.wait, no DataStore calls). Yielding in a module body blocks every
	    other requirer.
	  * Optional `Module.Priority: number` (default 100) orders init/start;
	    lower runs first.
	  * Optional `Module.init()` runs synchronously in priority order and must
	    not yield either — it is for wiring state, not for waiting.
	  * Optional `Module.start()` runs in its own task and may yield freely.
]]

local Loader = {}

local DEFAULT_PRIORITY = 100

export type LoadedModule = {
	name: string,
	instance: ModuleScript,
	value: any,
	priority: number,
}

--[[
	Requires every ModuleScript directly inside `container` (and inside plain
	Folders within it), returning them sorted by priority.
]]
function Loader.load(container: Instance): { LoadedModule }
	local loaded: { LoadedModule } = {}

	local function collect(parent: Instance)
		for _, child in parent:GetChildren() do
			if child:IsA("ModuleScript") then
				local ok, result = pcall(require, child)
				if ok then
					local priority = DEFAULT_PRIORITY
					if type(result) == "table" and type(result.Priority) == "number" then
						priority = result.Priority
					end

					table.insert(loaded, {
						name = child.Name,
						instance = child,
						value = result,
						priority = priority,
					})
				else
					warn(`[Loader] Failed to require {child:GetFullName()}: {result}`)
				end
			elseif child:IsA("Folder") then
				collect(child)
			end
		end
	end

	collect(container)

	table.sort(loaded, function(a, b)
		if a.priority == b.priority then
			return a.name < b.name
		end
		return a.priority < b.priority
	end)

	return loaded
end

--[[
	Calls `init()` on each module synchronously, in priority order.
	Errors are caught so one broken module cannot abort the whole boot.
]]
function Loader.init(modules: { LoadedModule })
	for _, entry in modules do
		local value = entry.value
		if type(value) == "table" and type(value.init) == "function" then
			local ok, err = pcall(value.init)
			if not ok then
				warn(`[Loader] {entry.name}.init() failed: {err}`)
			end
		end
	end
end

--[[
	Calls `start()` on each module in its own task, in priority order.
	start() is allowed to yield.
]]
function Loader.start(modules: { LoadedModule })
	for _, entry in modules do
		local value = entry.value
		if type(value) == "table" and type(value.start) == "function" then
			task.spawn(function()
				local ok, err = pcall(value.start)
				if not ok then
					warn(`[Loader] {entry.name}.start() failed: {err}`)
				end
			end)
		end
	end
end

--[[
	Convenience: build a name -> module map for cross-module lookups that would
	otherwise need a circular require.
]]
function Loader.toMap(modules: { LoadedModule }): { [string]: any }
	local map = {}
	for _, entry in modules do
		map[entry.name] = entry.value
	end
	return map
end

return Loader
