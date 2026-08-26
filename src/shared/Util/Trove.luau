--!nonstrict
--[[
	Trove.luau
	Cleanup container. Every RBXScriptConnection, Instance and teardown function
	created for a player or a character goes into a Trove, and the whole thing is
	emptied in one call when that player leaves or that character dies.

	This is the fix for the classic Roblox memory leak where `:Connect()` results
	accumulate for the lifetime of the script and keep firing on destroyed
	objects.
]]

local Trove = {}
Trove.__index = Trove

function Trove.new()
	return setmetatable({ _items = {} }, Trove)
end

--[[
	Track an object. Accepts:
	  * RBXScriptConnection / anything with :Disconnect()
	  * Instance / anything with :Destroy()
	  * function (called on cleanup)
	Returns the object so it can be used inline.
]]
function Trove:Add(object: any): any
	assert(object ~= nil, "Trove:Add expects a value")
	table.insert(self._items, object)
	return object
end

--[[
	Convenience for the very common connect-and-track pattern.
]]
function Trove:Connect(event: RBXScriptSignal, handler: (...any) -> ()): RBXScriptConnection
	return self:Add(event:Connect(handler))
end

--[[
	Stop tracking an object without cleaning it up.
]]
function Trove:Remove(object: any)
	local index = table.find(self._items, object)
	if index then
		table.remove(self._items, index)
	end
end

local function cleanupItem(item: any)
	local itemType = typeof(item)

	if itemType == "RBXScriptConnection" then
		item:Disconnect()
	elseif itemType == "function" then
		item()
	elseif itemType == "Instance" then
		item:Destroy()
	elseif itemType == "table" then
		if type(item.Disconnect) == "function" then
			item:Disconnect()
		elseif type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Clean) == "function" then
			item:Clean()
		end
	end
end

--[[
	Clean up everything, most recently added first (so dependents are torn down
	before what they depend on). Errors in one item never block the rest.
]]
function Trove:Clean()
	local items = self._items
	self._items = {}

	for index = #items, 1, -1 do
		local ok, err = pcall(cleanupItem, items[index])
		if not ok then
			warn(`[Trove] cleanup failed: {err}`)
		end
	end
end

Trove.Destroy = Trove.Clean

return Trove
