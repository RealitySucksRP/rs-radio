-- RS Communication Event
--
-- Step 5 of the communication build order: one event shape every RS device
-- agrees on, so a single dispatch exists once on the server and each device
-- renders it in its own voice.
--
--     ONE EVENT                    THREE PRESENTATIONS
--     officer emergency,           radio : EMERGENCY TRAFFIC / 10-13 / UNIT 214
--     unit 214,                    pager : 911 PRIORITY / 214 / VESPUCCI / RESPOND
--     Vespucci Blvd                tablet: card + [Open Map] [Acknowledge]
--
-- THE LOAD-BEARING RULE
-- ---------------------
-- A communication event is not a device presentation. This file defines and
-- validates the event and nothing else -- it contains no rendering, no device
-- vocabulary and no opinion about how anything looks. Renderers live in each
-- device, because that is the difference that makes a pager feel like a pager.
--
-- NO DEPENDENCY CHAIN
-- -------------------
-- Devices do not depend on a dispatcher and dispatchers do not depend on
-- devices. Anything that wants to raise an event fires the well-known
-- server-side event below; whichever devices happen to be installed pick it up.
-- With no devices installed, nothing listens and nothing breaks.
--
--     TriggerEvent('rs-comms:dispatch', event)     -- from any server script
--
-- WHY THAT IS AddEventHandler AND NEVER RegisterNetEvent
-- -----------------------------------------------------
-- A client can only reach RegisterNetEvent handlers. Subscribing with
-- AddEventHandler makes this server-only by construction: no player can forge
-- an officer-emergency broadcast, whatever they send. That is a structural
-- guarantee rather than a check somebody has to remember to write.
--
-- Each RS device vendors this protocol so there is no runtime dependency. Keep
-- compatible fields aligned across devices; newer optional fields are additive.
-- ASCII only, no BOM, LF endings.

RSCommEvent = RSCommEvent or {}
local CommEvent = RSCommEvent

CommEvent.EVENT = 'rs-comms:dispatch'
CommEvent.Version = 2

-- Ordered least to most urgent. Devices use the rank, not the word, so a pager
-- deciding "is this worth overriding silent mode" never has to hardcode a list.
local PRIORITIES = { routine = 1, priority = 2, urgent = 3, emergency = 4 }
CommEvent.Priorities = PRIORITIES

local LIMITS = {
    title = 64,
    body = 240,
    code = 16,
    callsign = 16,
    department = 32,
    callback = 24,
    instructions = 32,
    type = 32,
    list = 64,      -- max entries in any destination list
    key = 48,
}

local sequence = 0

local function text(value, limit)
    if type(value) ~= 'string' then return nil end
    value = value:gsub('%s+', ' '):gsub('^%s*(.-)%s*$', '%1')
    if value == '' then return nil end
    return value:sub(1, limit)
end

local function number(value)
    local n = tonumber(value)
    if not n or n ~= n then return nil end   -- n ~= n rejects NaN
    return n
end

--- Copy a destination list, bounded and de-duplicated. Unbounded lists are how
--- one malformed call turns into a server-wide broadcast.
local function list(value)
    if value == nil then return nil end
    if type(value) ~= 'table' then value = { value } end
    local out, seen = {}, {}
    for _, entry in ipairs(value) do
        local key
        if type(entry) == 'number' then key = math.floor(entry)
        else key = text(tostring(entry), LIMITS.key) end
        if key ~= nil and not seen[key] then
            seen[key] = true
            out[#out + 1] = key
            if #out >= LIMITS.list then break end
        end
    end
    if #out == 0 then return nil end
    return out
end

function CommEvent.NewId()
    sequence = sequence + 1
    return ('evt_%d_%d'):format(os.time(), sequence)
end

--- Validate and normalize. Returns event, or nil plus a reason.
---
--- Rejects rather than repairs anything that decides WHO is reached: a
--- destination nobody can parse must not silently become "everyone".
function CommEvent.Normalize(raw)
    if type(raw) ~= 'table' then return nil, 'invalid_event' end

    local message = type(raw.message) == 'table' and raw.message or {}
    local title = text(message.title or raw.title, LIMITS.title)
    local body = text(message.body or raw.body, LIMITS.body)
    if not title and not body then return nil, 'empty_message' end

    local destination = type(raw.destination) == 'table' and raw.destination or {}
    local dest = {
        channels = list(destination.channels),
        groups = list(destination.groups),
        jobs = list(destination.jobs),
        gangs = list(destination.gangs),
        departments = list(destination.departments or destination.department),
        players = list(destination.players),
        -- nil means "every device kind"; a list narrows it.
        devices = list(destination.devices),
        dutyOnly = destination.dutyOnly == true,
    }
    if not (dest.channels or dest.groups or dest.jobs or dest.gangs or dest.departments or dest.players or destination.broadcast == true) then
        return nil, 'no_destination'
    end
    dest.broadcast = destination.broadcast == true

    local source = type(raw.source) == 'table' and raw.source or {}
    local location = type(raw.location) == 'table' and raw.location or {}
    local metadata = type(raw.metadata) == 'table' and raw.metadata or {}

    local priority = text(raw.priority, 16)
    priority = priority and priority:lower() or 'routine'
    if not PRIORITIES[priority] then priority = 'routine' end

    local now = os.time()
    local ttl = number(raw.ttl)
    local expiresAt = number(raw.expiresAt)
    if not expiresAt and ttl then expiresAt = now + math.max(1, math.floor(ttl)) end

    local x, y, z = number(location.x), number(location.y), number(location.z)

    return {
        v = CommEvent.Version,
        id = text(raw.id, LIMITS.key) or CommEvent.NewId(),
        type = text(raw.type, LIMITS.type) or 'dispatch',
        priority = priority,
        rank = PRIORITIES[priority],

        source = {
            player = number(source.player) and math.floor(number(source.player)) or nil,
            callsign = text(source.callsign, LIMITS.callsign),
            department = text(source.department, LIMITS.department),
        },

        destination = dest,

        message = { title = title, body = body },

        location = (x and y) and { x = x, y = y, z = z or 0.0 } or nil,

        metadata = {
            code = text(metadata.code, LIMITS.code),
            -- Optional callback information is device-agnostic routing context.
            -- A pager prints it; a phone/tablet may choose to make it actionable.
            callback = text(metadata.callback, LIMITS.callback),
            instructions = text(metadata.instructions, LIMITS.instructions),
            -- Only meaningful on devices that can answer. A pager cannot, and
            -- must not render an Acknowledge it has no way to send.
            acknowledgement = metadata.acknowledgement == true,
        },

        createdAt = number(raw.createdAt) or now,
        expiresAt = expiresAt,
    }
end

--- Has this event aged out? Checked at render time, not only at dispatch:
--- a queued pager page delivered after coverage returns may be long stale.
function CommEvent.Expired(event, now)
    if type(event) ~= 'table' or not event.expiresAt then return false end
    return (now or os.time()) > event.expiresAt
end

--- Does this event want to reach a given device kind ('radio', 'pager',
--- 'tablet')? Absent list means every kind, which is the sane default for a
--- dispatcher that does not know what is installed.
function CommEvent.TargetsDevice(event, kind)
    if type(event) ~= 'table' then return false end
    local devices = event.destination and event.destination.devices
    if not devices then return true end
    for _, entry in ipairs(devices) do
        if entry == kind then return true end
    end
    return false
end

function CommEvent.AtLeast(event, priority)
    local want = PRIORITIES[priority] or 0
    return (type(event) == 'table' and (event.rank or 0) or 0) >= want
end

--- One line of plain text. Devices with a single-line readout use this rather
--- than each inventing its own flattening and drifting apart.
function CommEvent.OneLine(event)
    if type(event) ~= 'table' then return '' end
    local parts = {}
    local code = event.metadata and event.metadata.code
    if code then parts[#parts + 1] = code end
    if event.source and event.source.callsign then parts[#parts + 1] = event.source.callsign end
    if event.message and event.message.title then parts[#parts + 1] = event.message.title end
    if event.message and event.message.body then parts[#parts + 1] = event.message.body end
    return table.concat(parts, ' | ')
end
