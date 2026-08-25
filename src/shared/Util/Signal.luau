--!nonstrict
--[[
	Signal.luau
	Minimal observer used for in-process communication between controllers and
	UI screens (no BindableEvent overhead, no cross-boundary marshalling).

	Handlers are invoked in their own coroutine so a slow or erroring listener
	cannot stall the emitter.
]]

local Signal = {}
Signal.__index = Signal

local Connection = {}
Connection.__index = Connection

function Connection:Disconnect()
	if self._disconnected then
		return
	end
	self._disconnected = true

	local handlers = self._signal._handlers
	local index = table.find(handlers, self)
	if index then
		table.remove(handlers, index)
	end
end

function Signal.new()
	return setmetatable({ _handlers = {} }, Signal)
end

function Signal:Connect(handler: (...any) -> ())
	assert(type(handler) == "function", "Signal:Connect expects a function")

	local connection = setmetatable({
		_signal = self,
		_handler = handler,
		_disconnected = false,
	}, Connection)

	table.insert(self._handlers, connection)
	return connection
end

--[[
	Connect a handler that disconnects itself after the first fire.
]]
function Signal:Once(handler: (...any) -> ())
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		handler(...)
	end)
	return connection
end

function Signal:Fire(...)
	-- Iterate a copy: a handler is allowed to disconnect itself or others.
	local snapshot = table.clone(self._handlers)
	for _, connection in snapshot do
		if not connection._disconnected then
			task.spawn(connection._handler, ...)
		end
	end
end

--[[
	Fire synchronously. Use when ordering matters (for example applying a state
	update before the UI reads it) and every handler is known to be cheap.
]]
function Signal:FireSync(...)
	local snapshot = table.clone(self._handlers)
	for _, connection in snapshot do
		if not connection._disconnected then
			local ok, err = pcall(connection._handler, ...)
			if not ok then
				warn(`[Signal] handler error: {err}`)
			end
		end
	end
end

function Signal:DisconnectAll()
	for _, connection in table.clone(self._handlers) do
		connection:Disconnect()
	end
	table.clear(self._handlers)
end

return Signal
