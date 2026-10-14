-- RS Radio :: Logical channels
--
-- Step 3 of the communication build order.
--
-- THE PROBLEM
-- -----------
-- Display numbers such as 101 are user-facing identities, not authorization
-- tokens. On Legacy/pma-voice they also must not collide with another resource's
-- provider channel. On Enhanced, the Cfx-native adapter maps the same stable
-- logical key to a server-created runtime voice channel ID.
--
-- THE SHAPE
-- ---------
--     DISPLAY        101  (LCD, UI, favourites/recents)
--     LOGICAL        ch_101 / police_dispatch_primary  (stable identity)
--     BACKEND KEY    38412  (internal pma/native route key)
--
-- This indirection prevents accidental collisions. It is not security through
-- obscurity: public source can reveal the mapping, so every join is still
-- authorized on the server.
--
-- WHY IT IS DERIVED AND NOT RANDOM
-- --------------------------------
-- The internal route key is deterministic so every subsystem resolves the same
-- logical channel consistently. pma-voice uses it directly; the Cfx-native
-- backend uses it only as the server-side lookup key for a runtime channel.
--
-- WHY THE RANGE IS HIGH
-- ---------------------
-- Backends land in a high band (default 20000+) so they cannot collide with the
-- low, human-looking numbers other radio/phone scripts hand pma-voice directly.
-- A collision there would put two unrelated resources in one voice room.
--
-- SCOPE: this file changes only what the VOICE layer joins. session.channel,
-- rosters, jammers, favourites, recents and every UI payload keep using the
-- display number, so nothing else in the resource had to learn a new concept.
-- ASCII only, no BOM, LF endings.

RSRadioChannels = RSRadioChannels or {}
local Channels = RSRadioChannels

local backendByDisplay = {}
local displayByBackend = {}
local logicalByDisplay = {}
local built = false

local function cfg()
    return (Config and Config.LogicalChannels) or {}
end

local function enabled()
    return cfg().Enabled ~= false
end

local function base()
    return math.floor(tonumber(cfg().BackendBase) or 20000)
end

local function span()
    return math.max(1024, math.floor(tonumber(cfg().BackendSpan) or 40000))
end

-- djb2 plus an avalanche finalizer. Arithmetic-only rather than bitwise so it
-- behaves identically regardless of which Lua the server runtime is built with.
--
-- The finalizer is not decoration. Plain djb2 on two ids differing only in the
-- last character produces hashes differing by exactly one, so ch_101 and ch_102
-- would land on adjacent backend channels -- discover one and you have derived
-- its neighbours. Folding the halves against different multipliers decorrelates
-- them. Access is gated server-side regardless, so this is depth rather than
-- the only lock, but a guessable id is not worth shipping when the fix is five
-- lines.
local function hashString(str)
    local h = 5381
    for index = 1, #str do
        h = (h * 33 + str:byte(index)) % 4294967296
    end
    h = (h * 2654435761) % 4294967296
    local hi = math.floor(h / 65536)
    local lo = h % 65536
    return (lo * 40503 + hi * 2246822519) % 4294967296
end

--- The stable identity for a display number. An owner may pin one in config
--- (`id = 'police_dispatch_primary'`); otherwise it is derived from the number.
--- Pinning matters: renumbering a channel on the LCD then keeps players in the
--- same voice room instead of silently moving them to a new one.
local function logicalId(display, channelCfg)
    if type(channelCfg) == 'table' and type(channelCfg.id) == 'string' and channelCfg.id ~= '' then
        return channelCfg.id
    end
    return ('ch_%d'):format(display)
end

local function assign(display, logical)
    local wanted = base() + (hashString(logical) % span())

    -- Linear probe on collision. Two logical channels hashing to the same
    -- backend would merge two voice rooms, which is the one failure this whole
    -- file exists to prevent -- so it is resolved at boot, not discovered live.
    local candidate = wanted
    local guard = 0
    while displayByBackend[candidate] ~= nil and displayByBackend[candidate] ~= display do
        candidate = base() + ((candidate - base() + 1) % span())
        guard = guard + 1
        if guard > span() then
            print('^1[rs-radio] logical channel space exhausted; widen Config.LogicalChannels.BackendSpan^7')
            return nil
        end
    end

    backendByDisplay[display] = candidate
    displayByBackend[candidate] = display
    logicalByDisplay[display] = logical
    return candidate
end

function Channels.Build()
    backendByDisplay, displayByBackend, logicalByDisplay = {}, {}, {}
    built = true

    if not enabled() then return end

    -- Sorted so the probe order -- and therefore every assignment -- is
    -- identical on every boot and on every server running this config.
    local displays = {}
    for display in pairs(Config.Channels or {}) do displays[#displays + 1] = display end
    table.sort(displays)

    for _, display in ipairs(displays) do
        assign(display, logicalId(display, Config.Channels[display]))
    end

    if Config.Debug then
        print(('[rs-radio] logical channels: %d mapped into backend band %d-%d')
            :format(#displays, base(), base() + span() - 1))
    end
end

--- Display number -> backend voice id.
--- Ad-hoc frequencies (Config.AllowCustomFrequencies) are mapped on demand and
--- cached, so they are as stable as configured ones.
function Channels.Backend(display)
    display = math.floor(tonumber(display) or 0)
    if display <= 0 then return 0 end
    if not enabled() then return display end
    if not built then Channels.Build() end

    local existing = backendByDisplay[display]
    if existing then return existing end

    return assign(display, logicalId(display, (Config.Channels or {})[display])) or 0
end

--- Backend voice id -> display number, or nil when it is not one of ours.
--- Used to interpret an out-of-band channel change reported by the voice
--- provider: anything that does not reverse-map did not come from this resource.
function Channels.Display(backend)
    backend = math.floor(tonumber(backend) or 0)
    if backend <= 0 then return 0 end
    if not enabled() then return backend end
    if not built then Channels.Build() end
    return displayByBackend[backend]
end

--- The logical identity, for diagnostics. Safe to print -- unlike the backend.
function Channels.Logical(display)
    if not built then Channels.Build() end
    return logicalByDisplay[math.floor(tonumber(display) or 0)]
end

function Channels.Enabled()
    return enabled()
end
