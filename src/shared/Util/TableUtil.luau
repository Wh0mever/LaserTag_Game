--!nonstrict
--[[
	TableUtil.luau
	Small pure table helpers used by data reconciliation, config cloning and the
	economy logic. No Roblox API, so it is directly unit-testable.
]]

local TableUtil = {}

--[[
	Recursive copy. Used whenever a template table is handed out, so that two
	players can never share a mutable sub-table.
]]
function TableUtil.deepClone(source: { [any]: any }): { [any]: any }
	local clone = {}
	for key, value in pairs(source) do
		if type(value) == "table" then
			clone[key] = TableUtil.deepClone(value)
		else
			clone[key] = value
		end
	end
	return clone
end

--[[
	Fill missing keys in `data` from `template`, recursing into nested tables.
	Existing values are never overwritten — this is what makes adding a new
	profile field safe for players whose saved data predates it.
]]
function TableUtil.reconcile(data: { [any]: any }, template: { [any]: any })
	for key, default in pairs(template) do
		if data[key] == nil then
			if type(default) == "table" then
				data[key] = TableUtil.deepClone(default)
			else
				data[key] = default
			end
		elseif type(default) == "table" and type(data[key]) == "table" then
			TableUtil.reconcile(data[key], default)
		end
	end
end

function TableUtil.deepEquals(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, value in pairs(a) do
		if not TableUtil.deepEquals(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function TableUtil.count(source: { [any]: any }): number
	local total = 0
	for _ in pairs(source) do
		total += 1
	end
	return total
end

function TableUtil.keys(source: { [any]: any }): { any }
	local result = {}
	for key in pairs(source) do
		table.insert(result, key)
	end
	return result
end

--[[
	Fisher-Yates shuffle driven by an injected random function so the result is
	reproducible in tests. `randomFn(n)` must return an integer in [1, n].
]]
function TableUtil.shuffle(list: { any }, randomFn: (number) -> number): { any }
	local copy = table.clone(list)
	for index = #copy, 2, -1 do
		local pick = randomFn(index)
		copy[index], copy[pick] = copy[pick], copy[index]
	end
	return copy
end

function TableUtil.find(list: { any }, predicate: (any) -> boolean): any?
	for _, value in ipairs(list) do
		if predicate(value) then
			return value
		end
	end
	return nil
end

return TableUtil
