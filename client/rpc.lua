RSRadioRPC = RSRadioRPC or {}
local RPC = RSRadioRPC

RPC.handlers = RPC.handlers or {}

local function safeAction(value)
    if type(value) ~= 'string' then return nil end
    if #value < 1 or #value > 64 then return nil end
    if not value:match('^[%w%._%-]+$') then return nil end
    return value
end

local function respond(cb, requestId, result)
    result = type(result) == 'table' and result or { ok = result ~= false }
    if result.ok == nil then result.ok = true end
    result.requestId = requestId
    cb(result)
end

function RPC.Register(action, handler)
    action = safeAction(action)
    if not action then error('[rs-radio] invalid Device RPC action') end
    if type(handler) ~= 'function' then error(('[rs-radio] Device RPC handler for %s must be a function'):format(action)) end
    RPC.handlers[action] = handler
end

function RPC.Unregister(action)
    RPC.handlers[action] = nil
end

RegisterNUICallback('rpc', function(envelope, cb)
    if type(envelope) ~= 'table' then
        respond(cb, nil, { ok = false, error = 'invalid_envelope' })
        return
    end

    local requestId = tostring(envelope.requestId or ''):sub(1, 96)
    local action = safeAction(envelope.action)
    if not action then
        respond(cb, requestId, { ok = false, error = 'invalid_action' })
        return
    end

    local handler = RPC.handlers[action]
    if not handler then
        respond(cb, requestId, { ok = false, error = 'unknown_action' })
        return
    end

    local payload = type(envelope.payload) == 'table' and envelope.payload or {}
    local ok, result = pcall(handler, payload, {
        requestId = requestId,
        action = action
    })

    if not ok then
        print(('[rs-radio] Device RPC %s failed: %s'):format(action, tostring(result)))
        respond(cb, requestId, { ok = false, error = 'handler_error' })
        return
    end

    respond(cb, requestId, result)
end)
