local Bridge = RSRadioBridge
local Voice = RSRadioVoice
local Sessions, Members, Telemetry, Assignments, Distress = {}, {}, {}, {}, {}
local LastKnown, DirtyChannels = {}, {}
local Profiles, Batteries, Jammers = {}, {}, {}
local saveTimers = {}
local jammerSequence = 0

math.randomseed(os.time() + GetGameTimer())

local function finiteNumber(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return nil end
    return n
end

local function clamp(value, min, max)
    value = finiteNumber(value) or min
    if value < min then return min end
    if value > max then return max end
    return value
end

local function shortText(value, maxLength)
    value = tostring(value or ''):gsub('[\r\n\t]', ' ')
    return value:sub(1, maxLength)
end

local function safeCondition(value)
    value = tostring(value or 'UNKNOWN'):upper():gsub('[^%w _%-]', '')
    value = value:gsub('^%s+', ''):gsub('%s+$', '')
    if value == '' then value = 'UNKNOWN' end
    return value:sub(1, 16)
end

local function listContains(list, needle)
    for _, value in ipairs(list or {}) do
        if value == needle then return true end
    end
    return false
end

local function tableCopyArray(source, maxEntries, transform)
    local out, seen = {}, {}
    for _, value in ipairs(type(source) == 'table' and source or {}) do
        if transform then value = transform(value) end
        if value ~= nil and not seen[tostring(value)] then
            out[#out + 1] = value
            seen[tostring(value)] = true
            if maxEntries and #out >= maxEntries then break end
        end
    end
    return out
end

-- === persistence backend ===================================================
--
-- JSON remains the human-readable primary store. Some managed hosts mount the
-- resource folder read-only, so SaveResourceFile cannot persist changes there.
-- The fallback uses Cfx resource KVP storage: no database dependency, no remote
-- service, and no mandatory third-party resource for a free standalone release.
local storeMode = 'json'
local KVP_PREFIX = 'rs-radio:persist:'

local function probeWritable()
    local probe = 'data/.write_probe'
    local token = ('probe-%d'):format(os.time())
    local ok, wrote = pcall(SaveResourceFile, GetCurrentResourceName(), probe, token, -1)
    if not ok or wrote == false then return false end
    local readback = LoadResourceFile(GetCurrentResourceName(), probe)
    pcall(SaveResourceFile, GetCurrentResourceName(), probe, '', -1)
    return readback == token
end

local function kvpKey(path)
    return KVP_PREFIX .. tostring(path):gsub('[^%w%._%-/]', '_')
end

local function initializeStore()
    if not Config.Persistence.Enabled then return end
    -- Once KVP has accepted writes it remains the source of truth, even when
    -- a host later makes data/ writable. Selecting old JSON would lose updates.
    if type(GetResourceKvpString) == 'function'
        and GetResourceKvpString(KVP_PREFIX .. 'backend') == 'kvp' then
        storeMode = 'kvp'
        return
    end
    if probeWritable() then
        storeMode = 'json'
        return
    end

    if type(GetResourceKvpString) == 'function' and type(SetResourceKvp) == 'function' then
        storeMode = 'kvp'
        print('^2[rs-radio] data/ is read-only; persistence automatically switched to Cfx resource KVP storage.^7')
        return
    end

    storeMode = 'memory'
    print('^3[rs-radio] WARNING: data/ is read-only and Cfx KVP natives are unavailable. Persistence is memory-only for this boot.^7')
end

local function readJsonFile(path, fallback)
    local raw = LoadResourceFile(GetCurrentResourceName(), path)
    if not raw or raw == '' then return fallback end
    local ok, decoded = pcall(json.decode, raw)
    if not ok or type(decoded) ~= type(fallback) then return fallback end
    return decoded
end

local function loadJson(path, fallback)
    if storeMode ~= 'kvp' then return readJsonFile(path, fallback) end

    local raw
    local ok = pcall(function() raw = GetResourceKvpString(kvpKey(path)) end)
    if ok and raw and raw ~= '' then
        local good, decoded = pcall(json.decode, raw)
        if good and type(decoded) == type(fallback) then return decoded end
    end

    -- First boot after switching to KVP: adopt any existing JSON data.
    return readJsonFile(path, fallback)
end

local function writeStore(path, value)
    if storeMode == 'memory' then return false end
    local encodedOk, encoded = pcall(json.encode, value)
    if not encodedOk then
        print(('[rs-radio] Persistence encode failed for %s: %s'):format(path, tostring(encoded)))
        return false
    end

    if storeMode == 'kvp' then
        local ok = pcall(function()
            SetResourceKvp(kvpKey(path), encoded)
            SetResourceKvp(KVP_PREFIX .. 'backend', 'kvp')
        end)
        if not ok then print(('[rs-radio] KVP persistence failed for %s'):format(path)) end
        return ok
    end

    local ok, wrote = pcall(SaveResourceFile, GetCurrentResourceName(), path, encoded, -1)
    if ok and wrote ~= false then return true end
    if type(SetResourceKvp) == 'function' then
        storeMode = 'kvp'
        print(('^3[rs-radio] JSON write failed for %s; switching to KVP.^7'):format(path))
        return writeStore(path, value)
    end
    print(('[rs-radio] Persistence write failed for %s'):format(path))
    return false
end

local function saveJsonNow(kind)
    if not Config.Persistence.Enabled then return end
    local path, value
    if kind == 'profiles' then path, value = Config.Persistence.ProfilesFile, Profiles
    elseif kind == 'batteries' then path, value = Config.Persistence.BatteriesFile, Batteries
    elseif kind == 'jammers' then
        path, value = Config.Persistence.JammersFile, {}
        for _, jammer in pairs(Jammers) do
            if jammer.persist then
                value[#value + 1] = {
                    id = jammer.id,
                    coords = jammer.coords,
                    range = jammer.range,
                    allowedChannels = jammer.allowedChannels,
                    enabled = jammer.enabled,
                    canRemove = jammer.canRemove,
                    canDamage = jammer.canDamage,
                    owner = jammer.owner,
                    recoverItem = jammer.recoverItem == true,
                    bucket = finiteNumber(jammer.bucket) or 0,
                    persist = true
                }
            end
        end
    end
    if path then writeStore(path, value) end
end

local function scheduleSave(kind)
    if not Config.Persistence.Enabled then return end
    if saveTimers[kind] then return end
    saveTimers[kind] = true
    SetTimeout(Config.Persistence.SaveDebounceMs or 1200, function()
        saveTimers[kind] = nil
        saveJsonNow(kind)
    end)
end

local function defaultProfile()
    return {
        volume = math.floor(clamp(Config.DefaultVolume, 0, 100)),
        favorites = {},
        recent = {},
        displayName = nil,
        deafened = false,
        micClicks = Config.Profile.MicClicksDefault ~= false,
        allowMovement = Config.Profile.MovementDefault ~= false,
        overlayVisible = Config.UI.DefaultOverlayVisible == true,
        overlayMode = Config.UI.Overlay or 'default',
        overlayScale = math.floor(clamp(Config.UI.DefaultOverlayScale or 100, 60, 160)),
        overlayX = clamp(Config.UI.DefaultOverlayX or 78, 0, 95),
        overlayY = clamp(Config.UI.DefaultOverlayY or 8, 0, 95),
        radioPosition = Config.UI.Position == 'left' and 'left' or 'right',
        radioX = Config.UI.Position == 'left' and 1 or (Config.UI.DefaultRadioX or 62),
        radioY = Config.UI.DefaultRadioY or 15,
        radioScale = math.floor(clamp(Config.UI.DefaultScale or 100, Config.UI.ScaleMin or 75, Config.UI.ScaleMax or 120))
    }
end

local function normalizeProfile(profile)
    local defaults = defaultProfile()
    profile = type(profile) == 'table' and profile or {}
    defaults.volume = math.floor(clamp(profile.volume or defaults.volume, 0, 100))
    defaults.favorites = tableCopyArray(profile.favorites, Config.Profile.MaxFavorites or 12, function(value)
        value = math.floor(finiteNumber(value) or 0)
        return value > 0 and value <= Config.MaxFrequency and value or nil
    end)
    defaults.recent = tableCopyArray(profile.recent, Config.Profile.MaxRecentChannels or 8, function(value)
        value = math.floor(finiteNumber(value) or 0)
        return value > 0 and value <= Config.MaxFrequency and value or nil
    end)
    defaults.displayName = profile.displayName and shortText(profile.displayName, Config.Profile.MaxDisplayNameLength or 32) or nil
    defaults.deafened = profile.deafened == true
    if profile.micClicks ~= nil then defaults.micClicks = profile.micClicks ~= false end
    if profile.allowMovement ~= nil then defaults.allowMovement = profile.allowMovement ~= false end
    if profile.overlayVisible ~= nil then defaults.overlayVisible = profile.overlayVisible == true end
    defaults.overlayMode = listContains({ 'default', 'always', 'never' }, profile.overlayMode) and profile.overlayMode or defaults.overlayMode
    defaults.overlayScale = math.floor(clamp(profile.overlayScale or defaults.overlayScale, 60, 160))
    defaults.overlayX = clamp(profile.overlayX or defaults.overlayX, 0, 95)
    defaults.overlayY = clamp(profile.overlayY or defaults.overlayY, 0, 95)
    if profile.radioPosition ~= nil then defaults.radioPosition = profile.radioPosition == 'left' and 'left' or 'right' end
    defaults.radioX = clamp(profile.radioX or defaults.radioX, 0, 92)
    defaults.radioY = clamp(profile.radioY or defaults.radioY, 0, 90)
    defaults.radioScale = math.floor(clamp(profile.radioScale or defaults.radioScale, Config.UI.ScaleMin or 75, Config.UI.ScaleMax or 120))
    return defaults
end

local function profileKey(src)
    return Bridge.GetIdentifier(src)
end

local function getProfile(src)
    local key = profileKey(src)
    Profiles[key] = normalizeProfile(Profiles[key])
    return Profiles[key], key
end

local function getSession(src)
    local session = Sessions[src]
    if not session then
        local profile = getProfile(src)
        session = {
            channel = 0,
            powered = false,
            volume = profile.volume,
            battery = Config.Battery.StartingLevel,
            talking = false,
            jammed = false,
            jammerId = nil,
            voiceConnected = false,
            requestedChannel = 0,
            confirmedChannel = 0,
            lastOwnershipReason = nil,
            lastProviderConfirmation = nil,
            deviceId = nil
        }
        Sessions[src] = session
    end
    return session
end

local function rateLimited(session, key, minMs)
    local now = GetGameTimer()
    if session[key] and (now - session[key]) < (minMs or 0) then return true end
    session[key] = now
    return false
end

local function activateDevice(src)
    local session = getSession(src)
    local device = Bridge.GetRadioDevice(src)
    if not device.hasItem then return false, device.reason or 'no_item' end
    local deviceId = tostring(device.id or ('PERSONAL:%s'):format(profileKey(src)))
    if session.deviceId ~= deviceId then
        session.deviceId = deviceId
        if Batteries[deviceId] == nil then Batteries[deviceId] = Config.Battery.StartingLevel end
        session.battery = math.floor(clamp(Batteries[deviceId], 0, 100))
        scheduleSave('batteries')
    else
        session.battery = math.floor(clamp(Batteries[deviceId] or session.battery, 0, 100))
    end
    return true, device
end

local function persistBattery(session)
    if not session.deviceId then return end
    Batteries[session.deviceId] = math.floor(clamp(session.battery, 0, 100))
    scheduleSave('batteries')
end

-- Team/role/callsign resolution is server-trusted only.
local function resolveAssignment(src)
    if Assignments[src] then return Assignments[src] end
    local data = Bridge.GetPlayerData(src)
    if not data then return { team = nil, role = 'member', callsign = tostring(src), name = GetPlayerName(src) } end

    local metadata = data.metadata or {}
    local rawTeam = metadata[Config.TeamMetadataKey]
    local rawRole = metadata[Config.RoleMetadataKey]
    local callsign = metadata[Config.CallsignMetadataKey]
    local team, role

    if type(rawTeam) == 'table' then
        team = rawTeam.team or rawTeam.id or rawTeam.name
        role = rawTeam.role
        callsign = rawTeam.callsign or callsign
    else
        team = rawTeam
    end

    if not team and Config.JobTeams[data.job] then
        team = Config.JobTeams[data.job].team
        role = Config.JobTeams[data.job].role
    end

    return {
        team = team and tostring(team) or nil,
        role = tostring(rawRole or role or 'member'),
        callsign = tostring(callsign or data.name or src),
        name = data.name,
        job = data.job,
        gang = data.gang
    }
end

-- ---------------------------------------------------------------------------
-- Replicated state, written OUTSIDE the state-bag callback
--
-- THE CRASH THIS FIXES
-- --------------------
-- One of these calls sits in the leave path of the radioChannel state-bag
-- change handler. Writing five REPLICATED state bags from inside a state-bag
-- change callback re-enters the state-bag system on the same call stack --
-- close the radio, pma-voice writes radioChannel, our handler fires, and while
-- still inside that handler we write five more replicated bags.
--
-- rs-zombieradio, which does not crash, does not do this: its observer's leave
-- path has no replicated write at all. That single structural difference is the
-- one thing separating the fork that hangs the server from the one that does
-- not.
--
-- Deferring by one tick puts every write on a clean stack. State-bag
-- replication is asynchronous anyway, so nothing observable changes -- a client
-- cannot tell a one-frame-later bag update from an immediate one.
--
-- It also COALESCES: fifteen call sites can ask for a sync in the same frame
-- and the player's bags are written once, which is both cheaper and removes any
-- chance of two queued writes landing out of order.
-- ---------------------------------------------------------------------------
local ReplicationPending = {}

local function flushReplicatedState(src)
    if not src or not GetPlayerName(src) then return end
    local ownership = Voice.GetOwnership(src)
    if ownership.owner and ownership.owner ~= Voice.ControllerId() then return end
    local session = Sessions[src] or { channel = 0 }
    local assignment = resolveAssignment(src)
    local distress = Distress[src]
    local emergency = distress and distress.active == true and distress.expires > os.time() or false
    local player = Player(src)
    if not player or not player.state then return end

    pcall(function() player.state:set('rsRadioChannel', finiteNumber(session.channel) or 0, true) end)
    pcall(function() player.state:set('rsRadioTalking', session.talking == true, true) end)
    pcall(function() player.state:set('rsRadioEmergency', emergency, true) end)
    pcall(function() player.state:set('rsRadioJammed', session.jammed == true, true) end)
    pcall(function() player.state:set('rsRadioCallsign', tostring(assignment.callsign or ''), true) end)
end

local function syncReplicatedState(src)
    if not src or not GetPlayerName(src) then return end
    -- Already queued for this frame; the flush reads live values, so a second
    -- request inside the same tick would write exactly the same thing.
    if ReplicationPending[src] then return end
    local pending = {}
    ReplicationPending[src] = pending
    SetTimeout(0, function()
        if ReplicationPending[src] ~= pending then return end
        ReplicationPending[src] = nil
        flushReplicatedState(src)
    end)
end

local function canAccess(src, channel)
    local cfg = Config.Channels[channel]
    if not cfg then return Config.AllowCustomFrequencies and channel > 0 and channel <= Config.MaxFrequency end
    local access = cfg.access or { mode = 'public' }
    local mode = access.mode or 'public'
    if mode == 'public' then return true end

    local assignment = resolveAssignment(src)
    local data = Bridge.GetPlayerData(src) or {}
    if mode == 'team' then return assignment.team and listContains(access.teams, assignment.team) end
    if mode == 'roles' then return listContains(access.roles, assignment.role) end
    if mode == 'jobs' then return listContains(access.jobs, data.job) and Bridge.IsOnDuty(src) end
    if mode == 'gangs' then return listContains(access.gangs, data.gang) end
    if mode == 'ace' then
        for _, ace in ipairs(access.aces or {}) do
            if IsPlayerAceAllowed(src, ace) then return true end
        end
    end
    return false
end

local function isAllowed(src, channel)
    if not Bridge.GetPlayerData(src) then return false, 'inventory_not_ready' end
    local deviceOk, reason = activateDevice(src)
    if not deviceOk then return false, reason end
    local session = getSession(src)
    if Config.Battery.Enabled and session.battery <= 0 then return false, 'dead_battery' end
    if not canAccess(src, channel) then return false, 'denied' end
    return true
end

local function canSeeVitals(viewer)
    if not Config.Medical.ShowVitals then return false end
    return listContains(Config.Medical.VitalsRoles, resolveAssignment(viewer).role)
end

local function channelRosterEnabled(channel)
    local cfg = Config.Channels[channel]
    if not cfg then return false end
    if cfg.roster ~= nil then return cfg.roster == true end
    return cfg.telemetry == true
end

local function markDirty(channel)
    if channel and channel > 0 then DirtyChannels[channel] = true end
end

local function removeMember(src, channel)
    if Members[channel] then Members[channel][src] = nil end
end

local function addMember(src, channel)
    Members[channel] = Members[channel] or {}
    Members[channel][src] = true
    if LastKnown[channel] then LastKnown[channel][src] = nil end
end

local function channelLabel(channel)
    return Config.Channels[channel] and Config.Channels[channel].label or ('FREQUENCY %s'):format(channel)
end

local function recommendedChannels(src)
    local assignment = resolveAssignment(src)
    local recommended = {}
    if assignment.team and Config.Teams[assignment.team] and Config.Teams[assignment.team].channel then
        recommended[Config.Teams[assignment.team].channel] = true
    end
    for id, cfg in pairs(Config.Channels) do
        if canAccess(src, id) and cfg.access and (cfg.access.mode ~= 'public') then recommended[id] = true end
    end
    return recommended
end

local function buildChannels(src)
    local result = {}
    local profile = getProfile(src)
    local favorites, recent, recommended = {}, {}, recommendedChannels(src)
    for _, id in ipairs(profile.favorites) do favorites[id] = true end
    for index, id in ipairs(profile.recent) do recent[id] = index end

    for id, cfg in pairs(Config.Channels) do
        result[#result + 1] = {
            id = id,
            label = cfg.label,
            telemetry = cfg.telemetry == true,
            roster = channelRosterEnabled(id),
            locked = not canAccess(src, id),
            favorite = favorites[id] == true,
            recommended = recommended[id] == true,
            recent = recent[id]
        }
    end
    table.sort(result, function(a, b)
        if a.favorite ~= b.favorite then return a.favorite end
        if a.recommended ~= b.recommended then return a.recommended end
        if a.recent and b.recent and a.recent ~= b.recent then return a.recent < b.recent end
        if a.recent and not b.recent then return true end
        if b.recent and not a.recent then return false end
        return a.id < b.id
    end)
    return result
end

local function defaultChannelFor(src)
    local assignment = resolveAssignment(src)
    local teamChannel = assignment.team and Config.Teams[assignment.team] and Config.Teams[assignment.team].channel
    if teamChannel and canAccess(src, teamChannel) then return teamChannel end
    if Config.DefaultChannel and canAccess(src, Config.DefaultChannel) then return Config.DefaultChannel end
    local channels = buildChannels(src)
    for _, channel in ipairs(channels) do
        if not channel.locked then return channel.id end
    end
    return 0
end

local function verifiedPlayerState(src, payload)
    payload = type(payload) == 'table' and payload or {}
    local coords
    local health = math.floor(clamp(payload.health, 0, 100))
    local armor = math.floor(clamp(payload.armor, 0, 100))
    local dead = payload.dead == true
    local ped = GetPlayerPed(src)
    if ped and ped > 0 and DoesEntityExist(ped) then
        local serverCoords = GetEntityCoords(ped)
        coords = { x = serverCoords.x, y = serverCoords.y, z = serverCoords.z }
        local rawHealth = GetEntityHealth(ped)
        local maxHealth = math.max(GetEntityMaxHealth(ped), 101)
        health = math.floor(clamp(((rawHealth - 100) / (maxHealth - 100)) * 100, 0, 100))
        armor = math.floor(clamp(GetPedArmour(ped), 0, 100))

        -- Some FiveM server artifacts do not expose IsEntityDead as a Lua global.
        -- Feature-detect it so distress/telemetry never crashes, while still using
        -- verified server health and the client's framework-aware medical state.
        local nativeDead = false
        if type(IsEntityDead) == 'function' then
            local ok, result = pcall(IsEntityDead, ped)
            nativeDead = ok and result == true
        end
        dead = nativeDead or health <= 0 or dead
    end
    -- No server-observed ped means there is no verified position to publish.
    if not coords then return nil end
    return coords, health, armor, dead
end

local function deriveCondition(health, dead, unconscious, bleeding)
    if dead or health <= 0 then return 'DECEASED' end
    if unconscious then return 'UNCONSCIOUS' end
    if health < Config.Medical.CriticalAbove then return 'CRITICAL' end
    if bleeding then return 'BLEEDING' end
    if health >= Config.Medical.StableAbove then return 'STABLE' end
    if health >= Config.Medical.InjuredAbove then return 'INJURED' end
    return 'CRITICAL'
end

local function snapshotLastKnown(src, channel)
    if not Config.LastKnown.Enabled then return end
    local channelCfg = channel and Config.Channels[channel]
    if not channelCfg or not channelCfg.telemetry then return end
    local status = Telemetry[src]
    if not status then return end

    local ok, assignment = pcall(resolveAssignment, src)
    if not ok then assignment = { callsign = tostring(src), role = 'member' } end
    local profile = getProfile(src)
    LastKnown[channel] = LastKnown[channel] or {}
    LastKnown[channel][src] = {
        id = src,
        name = profile.displayName or assignment.name or GetPlayerName(src) or assignment.callsign,
        callsign = assignment.callsign,
        role = assignment.role,
        team = assignment.team,
        condition = status.condition or 'UNKNOWN',
        health = status.health,
        armor = status.armor,
        dead = status.dead == true,
        unconscious = status.unconscious == true,
        bleeding = status.bleeding == true,
        vitals = status.vitals,
        street = status.street or 'NO GPS',
        zone = status.zone or '',
        coords = status.coords,
        leftAt = os.time()
    }
    markDirty(channel)
end

local function redactEntry(entry)
    return {
        id = entry.id, name = entry.name, callsign = entry.callsign, role = entry.role, team = entry.team,
        talking = entry.talking, condition = entry.condition, dead = entry.dead, unconscious = entry.unconscious,
        bleeding = entry.bleeding, street = entry.street, zone = entry.zone, coords = entry.coords,
        signal = entry.signal, stale = entry.stale, age = entry.age, distress = entry.distress,
        offline = entry.offline, jammed = entry.jammed
    }
end

local function buildRoster(channel)
    local full, now = {}, os.time()
    local function push(entry) full[#full + 1] = entry end

    for playerId in pairs(Members[channel] or {}) do
        if GetPlayerName(playerId) then
            local assignment = resolveAssignment(playerId)
            local playerData = Bridge.GetPlayerData(playerId) or {}
            local profile = getProfile(playerId)
            local status = Telemetry[playerId] or {}
            local age = status.updatedAt and (now - status.updatedAt) or 9999
            local distress = Distress[playerId]
            local session = getSession(playerId)
            push({
                id = playerId,
                name = profile.displayName or playerData.name or GetPlayerName(playerId),
                callsign = assignment.callsign,
                role = assignment.role,
                team = assignment.team,
                talking = session.talking == true,
                condition = status.condition or (session.jammed and 'SIGNAL JAMMED' or 'UNKNOWN'),
                health = status.health,
                armor = status.armor,
                dead = status.dead == true,
                unconscious = status.unconscious == true,
                bleeding = status.bleeding == true,
                vitals = status.vitals,
                street = status.street or 'NO GPS',
                zone = status.zone or '',
                coords = status.coords,
                signal = session.jammed and 0 or (status.signal or (Config.Channels[channel] and Config.Channels[channel].telemetry and 0 or 100)),
                stale = Config.Channels[channel] and Config.Channels[channel].telemetry and age > Config.Telemetry.StaleAfterSeconds or false,
                age = age,
                distress = (distress and distress.active and distress.expires > now) or false,
                offline = false,
                jammed = session.jammed == true
            })
        end
    end

    for playerId, snapshot in pairs(LastKnown[channel] or {}) do
        if not (Members[channel] and Members[channel][playerId]) then
            push({
                id = snapshot.id, name = snapshot.name, callsign = snapshot.callsign, role = snapshot.role,
                team = snapshot.team, talking = false, condition = snapshot.condition, health = snapshot.health,
                armor = snapshot.armor, dead = snapshot.dead, unconscious = snapshot.unconscious,
                bleeding = snapshot.bleeding, vitals = snapshot.vitals, street = snapshot.street,
                zone = snapshot.zone, coords = snapshot.coords, signal = 0, stale = true,
                age = now - snapshot.leftAt, distress = false, offline = true, jammed = false
            })
        end
    end

    table.sort(full, function(a, b)
        if a.distress ~= b.distress then return a.distress end
        if a.offline ~= b.offline then return b.offline end
        local ac, bc = tostring(a.callsign), tostring(b.callsign)
        if ac ~= bc then return ac < bc end
        return (a.id or 0) < (b.id or 0)
    end)

    -- A roster-only channel must not inherit telemetry collected on a prior net.
    if not (Config.Channels[channel] and Config.Channels[channel].telemetry) then
        for _, entry in ipairs(full) do
            entry.coords, entry.health, entry.armor, entry.vitals = nil, nil, nil, nil
            entry.dead, entry.unconscious, entry.bleeding = nil, nil, nil
            entry.street, entry.zone, entry.condition = 'NO GPS', '', 'UNKNOWN'
        end
    end
    local redacted = {}
    for index, entry in ipairs(full) do redacted[index] = redactEntry(entry) end
    return full, redacted
end

local function rosterFor(target, full, redacted)
    if canSeeVitals(target) then return full end
    local out = {}
    for index, entry in ipairs(redacted) do
        out[index] = (entry.id == target and not entry.offline) and full[index] or entry
    end
    return out
end

local function sendRoster(channel)
    local members = Members[channel]
    if not members or not next(members) then return end
    if not channelRosterEnabled(channel) then
        for target in pairs(members) do TriggerClientEvent('rs-radio:client:roster', target, {}) end
        return
    end
    local full, redacted = buildRoster(channel)
    for target in pairs(members) do
        TriggerClientEvent('rs-radio:client:roster', target, rosterFor(target, full, redacted))
    end
end

local function distressModesFor(channel)
    local override = Config.Distress.ChannelOverrides and Config.Distress.ChannelOverrides[channel]
    return (override and override.modes) or Config.Distress.DefaultRecipientModes or { 'channel' }
end

local function canReceiveDistress(target, distress)
    if not GetPlayerName(target) then return false end
    local session = Sessions[target]
    if not session or session.channel <= 0 then return false end
    local modes = distress.modes or { 'channel' }
    local targetAssignment = resolveAssignment(target)
    local data = Bridge.GetPlayerData(target) or {}
    for _, mode in ipairs(modes) do
        if mode == 'channel' and session.channel == distress.channel then return true end
        if mode == 'radio' then return true end
        if mode == 'all' then return true end
        if mode == 'team' and distress.team and targetAssignment.team == distress.team then return true end
        if mode == 'teams' and listContains(Config.Distress.Teams, targetAssignment.team) then return true end
        if mode == 'roles' and listContains(Config.Distress.Roles, targetAssignment.role) then return true end
        if mode == 'jobs' and listContains(Config.Distress.Jobs, data.job) then return true end
    end
    return false
end

local function distressPublic(entry)
    return {
        id = entry.source,
        channel = entry.channel,
        channelLabel = channelLabel(entry.channel),
        callsign = entry.callsign,
        name = entry.name,
        role = entry.role,
        team = entry.team,
        street = entry.street,
        zone = entry.zone,
        coords = entry.coords,
        condition = entry.condition,
        createdAt = entry.createdAt,
        expires = entry.expires,
        seconds = math.max(0, entry.expires - os.time())
    }
end

local function buildDistressBoard(target)
    if not Config.Distress.BoardEnabled then return {} end
    local board = {}
    for _, entry in pairs(Distress) do
        if entry.active and entry.expires > os.time() and canReceiveDistress(target, entry) then
            board[#board + 1] = distressPublic(entry)
        end
    end
    table.sort(board, function(a, b) return a.createdAt > b.createdAt end)
    return board
end

local function sendDistressBoard(target)
    TriggerClientEvent('rs-radio:client:distressBoard', target, buildDistressBoard(target))
end

local function broadcastDistressBoards()
    for target, session in pairs(Sessions) do
        if session.channel > 0 and GetPlayerName(target) then sendDistressBoard(target) end
    end
end

local function leaveRadio(src, reason)
    local session = getSession(src)
    local oldChannel = session.channel
    if oldChannel > 0 then
        snapshotLastKnown(src, oldChannel)
        removeMember(src, oldChannel)
    end
    if oldChannel > 0 or Voice.IsOwner(src) then Voice.RemovePlayer(src, reason or 'leave') end
    session.talkSerial = (session.talkSerial or 0) + 1
    session.channel, session.powered, session.talking = 0, false, false
    session.jammed, session.jammerId, session.voiceConnected = false, nil, false
    session.requestedChannel, session.confirmedChannel = 0, 0
    syncReplicatedState(src)
    TriggerClientEvent('rs-radio:client:left', src, reason)
    if oldChannel > 0 then sendRoster(oldChannel) end
    sendDistressBoard(src)
end

-- A sibling RS radio (or an external provider change) took the player's real
-- voice transport. Clear only this resource's logical/UI state. Never call the
-- pma leave path here; the winner owns the provider now.
Voice.RegisterOwnershipLostHandler(function(src, payload)
    local session = Sessions[src]
    if not session then return end
    local oldChannel = math.floor(finiteNumber(session.channel) or 0)
    if oldChannel <= 0 and not session.voiceConnected and not session.talking then return end

    if oldChannel > 0 then
        snapshotLastKnown(src, oldChannel)
        removeMember(src, oldChannel)
    end
    Voice.StandDownLocal(src)
    session.talkSerial = (session.talkSerial or 0) + 1
    session.channel, session.powered, session.talking = 0, false, false
    session.jammed, session.jammerId, session.voiceConnected = false, nil, false
    session.requestedChannel, session.confirmedChannel = 0, 0
    session.lastOwnershipReason = tostring((payload or {}).reason or 'external_takeover')
    syncReplicatedState(src)
    TriggerClientEvent('rs-radio:client:left', src, 'external_takeover')
    if oldChannel > 0 then sendRoster(oldChannel) end
    sendDistressBoard(src)
end)

local function sendState(src, open, requestId)
    activateDevice(src)
    local session = getSession(src)
    syncReplicatedState(src)
    local assignment = resolveAssignment(src)
    local profile = getProfile(src)
    local roster = {}
    if session.channel > 0 and channelRosterEnabled(session.channel) then
        local full, redacted = buildRoster(session.channel)
        roster = rosterFor(src, full, redacted)
    end
    local distress = Distress[src]
    TriggerClientEvent('rs-radio:client:state', src, {
        open = open == true,
        requestId = requestId,
        channel = session.channel,
        channelLabel = session.channel > 0 and channelLabel(session.channel) or 'OFFLINE',
        powered = session.powered,
        battery = session.battery,
        volume = profile.volume,
        assignment = assignment,
        channels = buildChannels(src),
        roster = roster,
        distressBoard = buildDistressBoard(src),
        distressActive = (distress and distress.active and distress.expires > os.time()) or false,
        ui = {
            showWindowLabels = Config.UI.ShowWindowLabels == true,
            scaleMin = Config.UI.ScaleMin or 75,
            scaleMax = Config.UI.ScaleMax or 120,
            allowMovementToggle = Config.UI.AllowMovementToggle ~= false,
            allowPositionSettings = Config.UI.AllowPositionSettings ~= false,
            allowScaleSettings = Config.UI.AllowScaleSettings ~= false,
            allowCustomDisplayName = Config.Profile.AllowCustomDisplayName ~= false
        },
        profile = profile,
        batteryConfig = Config.Battery,
        jammerConfig = {
            enabled = Config.Jammer.Enabled == true,
            rangeMin = Config.Jammer.Range.Min,
            rangeMax = Config.Jammer.Range.Max,
            rangeStep = Config.Jammer.Range.Step,
            defaultRange = Config.Jammer.Range.Default,
            interactionDistance = Config.Jammer.InteractionDistance
        },
        defaultChannel = defaultChannelFor(src),
        playerId = src,
        jammed = session.jammed == true,
        jammerId = session.jammerId,
        waypointEnabled = Config.Distress.WaypointEnabled == true,
        voice = { provider = Voice.Provider(), capabilities = Voice.Capabilities() }
    })
end

local function addRecentChannel(src, channel)
    local profile = getProfile(src)
    local nextRecent = { channel }
    for _, existing in ipairs(profile.recent or {}) do
        if existing ~= channel then nextRecent[#nextRecent + 1] = existing end
    end
    profile.recent = tableCopyArray(nextRecent, Config.Profile.MaxRecentChannels or 8)
    scheduleSave('profiles')
end

-- The one place a display number becomes a real voice channel.
--
-- Everything above this line -- sessions, rosters, jammers, favourites, the UI
-- payloads -- speaks in display numbers. Everything below it speaks in backend
-- ids the player never sees. Keeping the translation to a single function is
-- what stops the two vocabularies leaking into each other.
local function setVoiceChannel(src, channel, reason)
    local session = getSession(src)
    session.requestedChannel = math.floor(finiteNumber(channel) or 0)
    if not Voice.IsReady() then
        session.voiceConnected = false
        return false
    end
    local ok = Voice.SetPlayerChannel(src, RSRadioChannels.Backend(channel), reason or 'join')
    session.voiceConnected = ok and channel > 0 and Voice.IsOwner(src)
    if ok and channel > 0 then
        session.confirmedChannel = channel
        session.lastProviderConfirmation = os.time()
        session.lastOwnershipReason = reason or 'join'
        local profile = getProfile(src)
        Voice.SetPlayerDeaf(src, profile.deafened == true)
        Voice.SetTransmitState(src, false)
        session.talkSerial = (session.talkSerial or 0) + 1
        session.talking = false
    elseif not ok then
        session.confirmedChannel = 0
    end
    return ok
end

local function pointDistance(a, b)
    local dx, dy, dz = (a.x or 0) - (b.x or 0), (a.y or 0) - (b.y or 0), (a.z or 0) - (b.z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local function routingBucketForSource(src)
    local ok, bucket = pcall(GetPlayerRoutingBucket, src)
    return ok and finiteNumber(bucket) or 0
end

local function sameRoutingBucket(src, jammer)
    return routingBucketForSource(src) == (finiteNumber(jammer and jammer.bucket) or 0)
end

local function channelAllowedByJammer(jammer, channel)
    return listContains(jammer.allowedChannels, channel)
end

local function jammerAffecting(src, channel)
    if not Config.Jammer.Enabled or channel <= 0 then return nil end
    local ped = GetPlayerPed(src)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then return nil end
    local coords = GetEntityCoords(ped)
    local point = { x = coords.x, y = coords.y, z = coords.z }
    for _, jammer in pairs(Jammers) do
        if sameRoutingBucket(src, jammer) and jammer.enabled and not channelAllowedByJammer(jammer, channel) and pointDistance(point, jammer.coords) <= jammer.range then
            return jammer
        end
    end
    return nil
end

local function setJammed(src, jammer)
    local session = getSession(src)
    local shouldJam = jammer ~= nil
    if session.jammed == shouldJam and (not shouldJam or session.jammerId == jammer.id) then return end
    session.jammed = shouldJam
    session.jammerId = shouldJam and jammer.id or nil
    if shouldJam then
        session.voiceConnected = false
        local wasTalking = session.talking == true
        session.talking = false
        session.talkSerial = (session.talkSerial or 0) + 1
        Voice.SetTransmitState(src, false)
        Voice.RemovePlayer(src, 'jammer')
        session.lastOwnershipReason = 'jammer'
        if wasTalking and session.channel > 0 and Members[session.channel] then
            for target in pairs(Members[session.channel]) do
                TriggerClientEvent('rs-radio:client:talking', target, src, false)
            end
        end
        TriggerClientEvent('rs-radio:client:jammer', src, { jammed = true, id = jammer.id, range = jammer.range })
    else
        if session.channel > 0 then
            local allowed = isAllowed(src, session.channel)
            if not allowed then
                leaveRadio(src, 'denied')
                return
            end
            if not setVoiceChannel(src, session.channel) then
                TriggerClientEvent('rs-radio:client:denied', src, 'no_voice')
                leaveRadio(src, 'no_voice')
                return
            end
        end
        TriggerClientEvent('rs-radio:client:jammer', src, { jammed = false })
    end
    syncReplicatedState(src)
    markDirty(session.channel)
end

-- A failed switch must never leave the UI/roster on the previous logical
-- channel while the voice backend has already detached from it. Revalidate the
-- previous channel, account for a jammer that may have appeared meanwhile, and
-- explicitly reconnect voice. If that recovery also fails, fail closed to
-- OFFLINE so logical and voice state cannot diverge.
local function restorePreviousChannel(src, oldChannel)
    local session = getSession(src)
    session.channel, session.powered = 0, false
    session.jammed, session.jammerId, session.voiceConnected = false, nil, false
    session.talking = false

    oldChannel = math.floor(finiteNumber(oldChannel) or 0)
    if oldChannel <= 0 then return false end

    local allowed = isAllowed(src, oldChannel)
    if not allowed then return false end

    session.channel, session.powered = oldChannel, true
    addMember(src, oldChannel)

    local oldJammer = jammerAffecting(src, oldChannel)
    if oldJammer then
        session.jammed, session.jammerId, session.voiceConnected = true, oldJammer.id, false
        Voice.RemovePlayer(src, 'jammer')
        session.lastOwnershipReason = 'jammer'
        return true
    end

    if setVoiceChannel(src, oldChannel) then return true end

    removeMember(src, oldChannel)
    session.channel, session.powered = 0, false
    session.jammed, session.jammerId, session.voiceConnected = false, nil, false
    session.talking = false
    return false
end

local function joinChannel(src, channel)
    local session = getSession(src)
    local oldChannel = session.channel
    if oldChannel > 0 and oldChannel ~= channel then
        snapshotLastKnown(src, oldChannel)
        removeMember(src, oldChannel)
    end

    session.channel, session.powered = channel, true
    addMember(src, channel)
    addRecentChannel(src, channel)
    local jammer = jammerAffecting(src, channel)
    if jammer then
        session.jammed, session.jammerId, session.voiceConnected = true, jammer.id, false
        Voice.RemovePlayer(src, 'jammer')
        session.lastOwnershipReason = 'jammer'
    else
        session.jammed, session.jammerId = false, nil
        -- Repeated joins are idempotent; re-adding a native member resets PTT.
        if not (oldChannel == channel and session.voiceConnected and Voice.IsOwner(src))
            and not setVoiceChannel(src, channel, oldChannel > 0 and oldChannel ~= channel and 'channel_switch' or 'join') then
            removeMember(src, channel)
            local restored = restorePreviousChannel(src, oldChannel)
            syncReplicatedState(src)
            TriggerClientEvent('rs-radio:client:denied', src, 'no_voice')
            if restored then
                sendRoster(oldChannel)
            else
                leaveRadio(src, 'no_voice')
            end
            return
        end
    end

    syncReplicatedState(src)
    local profile = getProfile(src)
    TriggerClientEvent('rs-radio:client:joined', src, {
        channel = channel,
        label = channelLabel(channel),
        battery = session.battery,
        volume = profile.volume,
        jammed = session.jammed,
        talking = session.talking == true,
        profile = profile,
        channels = buildChannels(src),
        voice = { provider = Voice.Provider(), capabilities = Voice.Capabilities() }
    })
    if oldChannel > 0 and oldChannel ~= channel then sendRoster(oldChannel) end
    sendRoster(channel)
    sendDistressBoard(src)
end

RegisterNetEvent('rs-radio:server:requestOpen', function(requestId)
    local src = source
    requestId = finiteNumber(requestId)
    if requestId then requestId = math.floor(requestId) end
    if rateLimited(getSession(src), 'lastOpen', Config.Security.OpenCooldownMs) then return end
    if not Bridge.GetPlayerData(src) then
        TriggerClientEvent('rs-radio:client:denied', src, 'inventory_not_ready', requestId)
        return
    end
    if not Voice.IsReady() then
        TriggerClientEvent('rs-radio:client:denied', src, 'no_voice', requestId)
        return
    end
    local ok, reason = activateDevice(src)
    if not ok then
        TriggerClientEvent('rs-radio:client:denied', src, reason, requestId)
        return
    end
    sendState(src, true, requestId)
end)

RegisterNetEvent('rs-radio:server:join', function(rawChannel)
    local src = source
    if rateLimited(getSession(src), 'lastJoin', Config.Security.JoinCooldownMs) then return end
    local channel = math.floor(finiteNumber(rawChannel) or 0)
    if channel <= 0 or channel > Config.MaxFrequency then
        TriggerClientEvent('rs-radio:client:denied', src, 'denied')
        return
    end
    local allowed, reason = isAllowed(src, channel)
    if not allowed then
        TriggerClientEvent('rs-radio:client:denied', src, reason)
        return
    end
    joinChannel(src, channel)
end)

RegisterNetEvent('rs-radio:server:leave', function()
    local src = source
    local session = Sessions[src]
    if not session or (session.channel <= 0 and not session.talking and not Voice.IsOwner(src)) then return end
    leaveRadio(src, 'manual')
end)

local queueProfilePatch
RegisterNetEvent('rs-radio:server:setVolume', function(value)
    queueProfilePatch(source, { volume = value })
end)

local function applyProfilePatch(src, patch)
    local session = getSession(src)
    if type(patch) ~= 'table' then return end
    local profile = getProfile(src)

    if patch.volume ~= nil then
        profile.volume = math.floor(clamp(patch.volume, 0, 100))
        session.volume = profile.volume
    end
    if patch.favoriteChannel ~= nil then
        local channel = math.floor(finiteNumber(patch.favoriteChannel) or 0)
        if Config.Channels[channel] then
            local nextFavorites, found = {}, false
            for _, value in ipairs(profile.favorites) do
                if value == channel then found = true else nextFavorites[#nextFavorites + 1] = value end
            end
            if patch.favorite == true and not found and #nextFavorites < (Config.Profile.MaxFavorites or 12) then
                nextFavorites[#nextFavorites + 1] = channel
            end
            profile.favorites = nextFavorites
        end
    end
    if patch.displayName ~= nil and Config.Profile.AllowCustomDisplayName ~= false then
        local name = shortText(patch.displayName, Config.Profile.MaxDisplayNameLength or 32):gsub('[<>]', '')
        profile.displayName = name ~= '' and name or nil
    end
    if patch.deafened ~= nil then profile.deafened = patch.deafened == true end
    if patch.micClicks ~= nil then profile.micClicks = patch.micClicks == true end
    if patch.allowMovement ~= nil and Config.UI.AllowMovementToggle ~= false then profile.allowMovement = patch.allowMovement == true end
    if patch.overlayVisible ~= nil then profile.overlayVisible = patch.overlayVisible == true end
    if patch.overlayMode ~= nil and listContains({ 'default', 'always', 'never' }, patch.overlayMode) then profile.overlayMode = patch.overlayMode end
    if patch.overlayScale ~= nil then profile.overlayScale = math.floor(clamp(patch.overlayScale, 60, 160)) end
    if patch.overlayX ~= nil then profile.overlayX = clamp(patch.overlayX, 0, 95) end
    if patch.overlayY ~= nil then profile.overlayY = clamp(patch.overlayY, 0, 95) end
    if patch.radioPosition ~= nil and Config.UI.AllowPositionSettings ~= false then
        profile.radioPosition = patch.radioPosition == 'left' and 'left' or 'right'
        profile.radioX = profile.radioPosition == 'left' and 1 or (Config.UI.DefaultRadioX or 62)
    end
    if patch.radioX ~= nil and Config.UI.AllowPositionSettings ~= false then profile.radioX = clamp(patch.radioX, 0, 92) end
    if patch.radioY ~= nil and Config.UI.AllowPositionSettings ~= false then profile.radioY = clamp(patch.radioY, 0, 90) end
    if patch.radioScale ~= nil and Config.UI.AllowScaleSettings ~= false then
        profile.radioScale = math.floor(clamp(patch.radioScale, Config.UI.ScaleMin or 75, Config.UI.ScaleMax or 120))
    end

    Profiles[profileKey(src)] = normalizeProfile(profile)
    profile = Profiles[profileKey(src)]
    Voice.SetPlayerDeaf(src, profile.deafened == true)
    scheduleSave('profiles')
    TriggerClientEvent('rs-radio:client:profile', src, profile, buildChannels(src))
    if session.channel > 0 then sendRoster(session.channel) end
end

queueProfilePatch = function(src, patch)
    if type(patch) ~= 'table' or not Bridge.GetPlayerData(src) then return end
    local session = getSession(src)
    local interval = Config.Security.SettingsMinIntervalMs or 250
    if not rateLimited(session, 'lastSettings', interval) then
        local favorites = session.pendingFavorites
        session.pendingFavorites = nil
        for channel, favorite in pairs(favorites or {}) do
            applyProfilePatch(src, { favoriteChannel = channel, favorite = favorite })
        end
        local merged = session.pendingProfile or {}
        for key, value in pairs(patch) do merged[key] = value end
        session.pendingProfile = nil
        applyProfilePatch(src, merged)
        return
    end
    -- Retain the final value of each bounded setting instead of dropping the
    -- last slider/toggle update in a burst. One timer per session caps work.
    session.pendingProfile = session.pendingProfile or {}
    local favoriteChannel = math.floor(finiteNumber(patch.favoriteChannel) or 0)
    if Config.Channels[favoriteChannel] then
        session.pendingFavorites = session.pendingFavorites or {}
        session.pendingFavorites[favoriteChannel] = patch.favorite == true
    end
    for _, key in ipairs({ 'volume', 'displayName', 'deafened',
        'micClicks', 'allowMovement', 'overlayVisible', 'overlayMode', 'overlayScale',
        'overlayX', 'overlayY', 'radioPosition', 'radioX', 'radioY', 'radioScale' }) do
        if patch[key] ~= nil then session.pendingProfile[key] = patch[key] end
    end
    if session.profileTimer then return end
    session.profileTimer = true
    SetTimeout(interval, function()
        if Sessions[src] ~= session or not GetPlayerName(src) then return end
        session.profileTimer = nil
        local pending = session.pendingProfile
        local favorites = session.pendingFavorites
        session.pendingProfile, session.pendingFavorites = nil, nil
        for channel, favorite in pairs(favorites or {}) do
            applyProfilePatch(src, { favoriteChannel = channel, favorite = favorite })
        end
        if pending then
            session.lastSettings = GetGameTimer()
            applyProfilePatch(src, pending)
        end
    end)
end
RegisterNetEvent('rs-radio:server:updateProfile', function(patch) queueProfilePatch(source, patch) end)

RegisterNetEvent('rs-radio:server:talking', function(active)
    local src = source
    local session = getSession(src)
    active = active == true

    -- A release is never rate-limited: dropping a key-up on the Enhanced
    -- backend would leave the sender server-unmuted. Only repeated key-downs
    -- are throttled.
    if active and rateLimited(session, 'lastTalking', Config.Security.TalkingMinIntervalMs) then
        if not session.talking then TriggerClientEvent('rs-radio:client:talkingTimeout', src) end
        return
    end
    if active and session.channel > 0 then
        local allowed, reason = isAllowed(src, session.channel)
        if not allowed then
            leaveRadio(src, reason)
            TriggerClientEvent('rs-radio:client:talkingTimeout', src)
            return
        end
        local jammer = jammerAffecting(src, session.channel)
        if jammer then setJammed(src, jammer) end
        local ped = GetPlayerPed(src)
        local metadata = (Bridge.GetPlayerData(src) or {}).metadata or {}
        if not ped or ped <= 0 or not DoesEntityExist(ped) or GetEntityHealth(ped) <= 100
            or metadata.isdead == true or metadata.inlaststand == true then
            active = false
        end
    end

    if session.channel <= 0 or not session.voiceConnected or session.jammed or not Voice.IsOwner(src) then
        if Voice.IsOwner(src) then Voice.SetTransmitState(src, false) end
        active = false
    end

    if active and not Voice.SetTransmitState(src, true) then
        TriggerClientEvent('rs-radio:client:talkingTimeout', src)
        return
    end
    if not active then TriggerClientEvent('rs-radio:client:talkingTimeout', src) end
    if not active then Voice.SetTransmitState(src, false) end
    if session.talking == active then return end

    session.talking = active
    session.talkSerial = (session.talkSerial or 0) + 1
    local serial = session.talkSerial
    syncReplicatedState(src)
    for target in pairs(Members[session.channel] or {}) do
        if target ~= src then TriggerClientEvent('rs-radio:client:talking', target, src, active) end
    end

    if active and Voice.Provider() == 'cfx-native' then
        local maxSeconds = math.max(10, finiteNumber((Config.Voice or {}).MaxTransmitSeconds) or 120)
        SetTimeout(math.floor(maxSeconds * 1000), function()
            local current = Sessions[src]
            if current ~= session or not current.talking or current.talkSerial ~= serial then return end
            current.talking = false
            current.talkSerial = current.talkSerial + 1
            Voice.SetTransmitState(src, false)
            syncReplicatedState(src)
            for target in pairs(Members[current.channel] or {}) do
                if target ~= src then TriggerClientEvent('rs-radio:client:talking', target, src, false) end
            end
            TriggerClientEvent('rs-radio:client:talkingTimeout', src)
        end)
    end
end)

RegisterNetEvent('rs-radio:server:telemetry' , function(payload)
    local src = source
    local session = getSession(src)
    if rateLimited(session, 'lastTelemetry', Config.Security.TelemetryMinIntervalMs) then return end
    local channelCfg = Config.Channels[session.channel]
    if session.channel <= 0 or not Config.Telemetry.Enabled or not channelCfg or not channelCfg.telemetry then return end
    if type(payload) ~= 'table' then return end

    local coords, health, armor, dead = verifiedPlayerState(src, payload)
    if not coords then return end
    local unconscious = payload.unconscious == true
    local bleeding = payload.bleeding == true
    local vitals = Config.Medical.ShowVitals and type(payload.vitals) == 'table' and payload.vitals or nil
    Telemetry[src] = {
        coords = coords,
        street = shortText(payload.street, Config.Telemetry.MaxStreetLength),
        zone = shortText(payload.zone, Config.Telemetry.MaxZoneLength),
        condition = deriveCondition(health, dead, unconscious, bleeding),
        health = health,
        armor = armor,
        dead = dead,
        unconscious = unconscious,
        bleeding = bleeding,
        signal = session.jammed and 0 or math.floor(clamp(payload.signal or 100, 0, 100)),
        vitals = vitals and {
            hr = clamp(vitals.hr, 0, 300), sys = clamp(vitals.sys, 0, 300), dia = clamp(vitals.dia, 0, 200),
            spo2 = clamp(vitals.spo2, 0, 100), rr = clamp(vitals.rr, 0, 80), temp = clamp(vitals.temp, 20, 45)
        } or nil,
        updatedAt = os.time()
    }
    markDirty(session.channel)
end)

RegisterNetEvent('rs-radio:server:distress', function(payload)
    local src = source
    if not Config.Distress.Enabled then return end
    local session = getSession(src)
    if session.channel <= 0 then return end
    if rateLimited(session, 'lastDistress', Config.Security.DistressMinIntervalMs) then return end

    local now, current = os.time(), Distress[src]
    if current and current.active and current.expires > now then
        current.active, current.expires = false, now
        syncReplicatedState(src)
        TriggerClientEvent('rs-radio:client:distressState', src, { active = false, cancelled = true })
        sendRoster(session.channel)
        broadcastDistressBoards()
        return
    end
    if current and current.cooldownUntil and current.cooldownUntil > now then return end

    payload = type(payload) == 'table' and payload or {}
    local coords, health, _, dead = verifiedPlayerState(src, payload)
    if not coords then return end
    local unconscious, bleeding = payload.unconscious == true, payload.bleeding == true
    local assignment = resolveAssignment(src)
    local profile = getProfile(src)
    local entry = {
        source = src,
        active = true,
        channel = session.channel,
        modes = distressModesFor(session.channel),
        callsign = assignment.callsign,
        name = profile.displayName or assignment.name or GetPlayerName(src),
        role = assignment.role,
        team = assignment.team,
        coords = coords,
        street = shortText(payload.street ~= '' and payload.street or 'UNKNOWN POSITION', Config.Telemetry.MaxStreetLength),
        zone = shortText(payload.zone, Config.Telemetry.MaxZoneLength),
        condition = deriveCondition(health, dead, unconscious, bleeding),
        createdAt = now,
        expires = now + Config.Distress.DurationSeconds,
        cooldownUntil = now + Config.Distress.DurationSeconds + Config.Distress.CooldownSeconds
    }
    Distress[src] = entry
    syncReplicatedState(src)
    TriggerClientEvent('rs-radio:client:distressState', src, { active = true, seconds = Config.Distress.DurationSeconds })

    for target, targetSession in pairs(Sessions) do
        if target ~= src and targetSession.channel > 0 and canReceiveDistress(target, entry) then
            TriggerClientEvent('rs-radio:client:distressAlert', target, distressPublic(entry))
        end
    end
    sendRoster(session.channel)
    broadcastDistressBoards()
end)

local function rechargePlayer(src)
    local ok, reason = activateDevice(src)
    if not ok then
        TriggerClientEvent('rs-radio:client:denied', src, reason)
        return false
    end
    local session = getSession(src)
    if session.rechargeBusy or rateLimited(session, 'lastRecharge', Config.Security.RechargeCooldownMs or 750) then return false end
    session.rechargeBusy = true
    local removed, consumed = pcall(Bridge.RemoveFirstAvailableItem, src, Config.Battery.RechargeItems, 1)
    session.rechargeBusy = false
    if not removed then consumed = nil end
    if not consumed then
        TriggerClientEvent('rs-radio:client:denied', src, 'no_cell')
        return false
    end
    if Sessions[src] ~= session then return false end
    session.battery = math.floor(clamp(Config.Battery.RechargeAmount or 100, 0, 100))
    persistBattery(session)
    TriggerClientEvent('rs-radio:client:battery', src, session.battery, true)
    return true
end

RegisterNetEvent('rs-radio:server:recharge', function()
    rechargePlayer(source)
end)

local function hasJammerPermission(src)
    if src == 0 then return true end
    local data, assignment = Bridge.GetPlayerData(src) or {}, resolveAssignment(src)
    if listContains(Config.Jammer.Permission.Jobs, data.job) then return true end
    if listContains(Config.Jammer.Permission.Gangs, data.gang) then return true end
    if listContains(Config.Jammer.Permission.Roles, assignment.role) then return true end
    for _, ace in ipairs(Config.Jammer.Permission.Aces or {}) do
        if IsPlayerAceAllowed(src, ace) then return true end
    end
    return false
end

local function nextJammerId()
    jammerSequence = jammerSequence + 1
    return ('RSJ-%d-%d'):format(os.time(), jammerSequence)
end

local function publicJammer(jammer)
    local netId = jammer.entity and DoesEntityExist(jammer.entity) and NetworkGetNetworkIdFromEntity(jammer.entity) or 0
    return {
        id = jammer.id,
        netId = netId,
        coords = jammer.coords,
        range = jammer.range,
        allowedChannels = jammer.allowedChannels,
        enabled = jammer.enabled,
        canRemove = jammer.canRemove,
        canDamage = jammer.canDamage,
        bucket = finiteNumber(jammer.bucket) or 0
    }
end

local function broadcastJammers(target)
    local function sendTo(src)
        local list = {}
        for _, jammer in pairs(Jammers) do
            if sameRoutingBucket(src, jammer) then list[#list + 1] = publicJammer(jammer) end
        end
        TriggerClientEvent('rs-radio:client:jammers', src, list)
    end
    if target then sendTo(target)
    else for _, src in ipairs(GetPlayers()) do sendTo(finiteNumber(src)) end end
end

RegisterNetEvent('rs-radio:server:requestJammers', function()
    local src = source
    if rateLimited(getSession(src), 'lastJammerRequest', Config.Security.JammerStatusCooldownMs or 500) then return end
    broadcastJammers(src)
end)

local function spawnJammer(data, deferCommit)
    if not Config.Jammer.Enabled or type(data) ~= 'table' or type(data.coords) ~= 'table' then return nil end
    local coords = data.coords
    if not finiteNumber(coords.x) or not finiteNumber(coords.y) or not finiteNumber(coords.z) then return nil end
    local id = tostring(data.id or nextJammerId())
    if Jammers[id] then return nil end
    local model = joaat(Config.Jammer.Model)
    local entity = CreateObject(model, finiteNumber(coords.x) or 0.0, finiteNumber(coords.y) or 0.0, finiteNumber(coords.z) or 0.0, true, true, false)
    if not entity or entity <= 0 then return nil end
    local bucket = finiteNumber(data.bucket) or 0
    local configured = pcall(function()
        SetEntityHeading(entity, finiteNumber(coords.w) or 0.0)
        SetEntityRoutingBucket(entity, bucket)
        FreezeEntityPosition(entity, true)
        SetEntityOrphanMode(entity, 2)
    end)
    if not configured then
        DeleteEntity(entity)
        return nil
    end
    local jammer = {
        id = id,
        entity = entity,
        coords = { x = finiteNumber(coords.x) or 0.0, y = finiteNumber(coords.y) or 0.0, z = finiteNumber(coords.z) or 0.0, w = finiteNumber(coords.w) or 0.0 },
        range = clamp(data.range or Config.Jammer.Range.Default, Config.Jammer.Range.Min, Config.Jammer.Range.Max),
        allowedChannels = tableCopyArray(data.allowedChannels, 64, function(value)
            value = math.floor(finiteNumber(value) or 0)
            return value > 0 and value <= Config.MaxFrequency and value or nil
        end),
        enabled = data.enabled ~= false,
        canRemove = data.canRemove ~= false,
        canDamage = data.canDamage ~= false,
        owner = data.owner,
        -- Older placed records predate this field. Preserve paid recovery only
        -- when physical jammer mode is still configured. Free units never mint items.
        recoverItem = data.recoverItem == true or (data.recoverItem == nil
            and data.owner ~= nil and Config.Jammer.RequireItem == true),
        bucket = bucket,
        persist = data.persist == true
    }
    if not deferCommit then
        Jammers[id] = jammer
        if jammer.persist then scheduleSave('jammers') end
    end
    return jammer
end

local function nearestJammer(src, maxDistance)
    local ped = GetPlayerPed(src)
    if not ped or ped <= 0 or not DoesEntityExist(ped) then return nil end
    local coords = GetEntityCoords(ped)
    local point, best, bestDistance = { x = coords.x, y = coords.y, z = coords.z }, nil, maxDistance or Config.Jammer.InteractionDistance
    for _, jammer in pairs(Jammers) do
        if sameRoutingBucket(src, jammer) then
            local distance = pointDistance(point, jammer.coords)
            if distance <= bestDistance then best, bestDistance = jammer, distance end
        end
    end
    return best, bestDistance
end

local function sendNearestJammerStatus(src)
    local jammer, distance = nearestJammer(src, Config.Jammer.InteractionDistance)
    TriggerClientEvent('rs-radio:client:jammerStatus', src, jammer and publicJammer(jammer) or nil, distance)
end

local function removeJammer(jammer, returnItem, src)
    if not jammer or Jammers[jammer.id] ~= jammer or jammer.recovering then return false end
    jammer.recovering = true

    -- Recovery is two-phase: when the configured policy returns the physical
    -- jammer item, prove the inventory accepted it before deleting the world
    -- entity/record. This avoids permanently consuming a paid/rare item when
    -- the player's inventory is full or temporarily unavailable.
    if returnItem and jammer.recoverItem and src and Config.Jammer.Item then
        if not Bridge.AddItem(src, Config.Jammer.Item, 1) then
            jammer.recovering = false
            TriggerClientEvent('rs-radio:client:denied', src, 'inventory_not_ready')
            return false
        end
    end

    if jammer.entity and DoesEntityExist(jammer.entity) then DeleteEntity(jammer.entity) end
    Jammers[jammer.id] = nil
    scheduleSave('jammers')
    broadcastJammers()
    return true
end

RegisterNetEvent('rs-radio:server:placeJammer', function(payload)
    local src = source
    local session = getSession(src)
    if rateLimited(session, 'lastJammerAction', Config.Security.JammerActionCooldownMs) then return end
    if not Config.Jammer.Enabled or not hasJammerPermission(src) then
        TriggerClientEvent('rs-radio:client:denied', src, 'jammer_denied')
        return
    end
    if session.jammerBusy or type(payload) ~= 'table' or type(payload.coords) ~= 'table' then return end
    local ped = GetPlayerPed(src)
    if not ped or ped <= 0 or not DoesEntityExist(ped) or GetEntityHealth(ped) <= 100 then return end
    local playerCoords = GetEntityCoords(ped)
    local target = payload.coords
    local targetPoint = { x = finiteNumber(target.x), y = finiteNumber(target.y), z = finiteNumber(target.z) }
    if not targetPoint.x or not targetPoint.y or not targetPoint.z then return end
    if pointDistance({ x = playerCoords.x, y = playerCoords.y, z = playerCoords.z }, targetPoint) > Config.Jammer.MaxPlacementDistance then return end
    session.jammerBusy = true
    -- Allocate before consuming. A failed native cannot eat a physical item.
    local ok, jammer = pcall(spawnJammer, {
        coords = { x = targetPoint.x, y = targetPoint.y, z = targetPoint.z, w = finiteNumber(target.w) or GetEntityHeading(ped) },
        range = payload.range,
        allowedChannels = payload.allowedChannels or {},
        enabled = true,
        canRemove = true,
        canDamage = Config.Jammer.CanDamage,
        owner = profileKey(src),
        bucket = routingBucketForSource(src),
        persist = Config.Jammer.PersistPlaced,
        recoverItem = Config.Jammer.RequireItem == true
    }, true)
    if not ok or not jammer then
        session.jammerBusy = false
        TriggerClientEvent('rs-radio:client:denied', src, 'jammer_spawn_failed')
        return
    end
    if Sessions[src] ~= session or not GetPlayerName(src)
        or (Config.Jammer.RequireItem and not Bridge.RemoveItem(src, Config.Jammer.Item, 1)) then
        DeleteEntity(jammer.entity)
        session.jammerBusy = false
        TriggerClientEvent('rs-radio:client:denied', src, 'no_item')
        return
    end
    Jammers[jammer.id] = jammer
    session.jammerBusy = false
    if jammer.persist then scheduleSave('jammers') end
    broadcastJammers()
    TriggerClientEvent('rs-radio:client:jammerAction', src, 'placed', publicJammer(jammer))
end)

local function handleJammerAction(src, action, value)
    local session = getSession(src)
    if rateLimited(session, 'lastJammerAction', Config.Security.JammerActionCooldownMs) then return end
    if not Config.Jammer.Enabled or not hasJammerPermission(src) then TriggerClientEvent('rs-radio:client:denied', src, 'jammer_denied') return end
    local jammer = nearestJammer(src, Config.Jammer.InteractionDistance)
    if not jammer then TriggerClientEvent('rs-radio:client:denied', src, 'jammer_not_found') return end

    if action == 'remove' then
        if not jammer.canRemove then return end
        if removeJammer(jammer, Config.Jammer.ReturnItemOnRemove, src) then
            TriggerClientEvent('rs-radio:client:jammerAction', src, 'removed')
        end
    elseif action == 'toggle' then
        jammer.enabled = not jammer.enabled
        scheduleSave('jammers')
        broadcastJammers()
    elseif action == 'range' then
        jammer.range = clamp(value, Config.Jammer.Range.Min, Config.Jammer.Range.Max)
        scheduleSave('jammers')
        broadcastJammers()
    elseif action == 'allow' then
        local channel = math.floor(finiteNumber(value) or 0)
        if channel <= 0 or channel > Config.MaxFrequency then return end
        local nextAllowed, found = {}, false
        for _, existing in ipairs(jammer.allowedChannels) do
            if existing == channel then found = true else nextAllowed[#nextAllowed + 1] = existing end
        end
        if not found then nextAllowed[#nextAllowed + 1] = channel end
        jammer.allowedChannels = nextAllowed
        scheduleSave('jammers')
        broadcastJammers()
    end

    for playerId, playerSession in pairs(Sessions) do
        if playerSession.channel > 0 and GetPlayerName(playerId) then
            setJammed(playerId, jammerAffecting(playerId, playerSession.channel))
        end
    end
    sendNearestJammerStatus(src)
end

RegisterNetEvent('rs-radio:server:jammerAction', function(action, value)
    handleJammerAction(source, action, value)
end)

-- Voice state enforcement. Jammer-induced channel zero is intentionally retained
-- as an RS session so the player reconnects when leaving the jammer radius.
Voice.RegisterExternalChannelObserver(function(src, backendChannel)
    if not Config.Security.EnforceVoiceChannels then return end
    local session = getSession(src)

    -- With the shared ownership protocol enabled, server/voice.lua consumes
    -- external provider changes and stands this resource down before this legacy
    -- reconciliation callback is reached. If ownership is not ours, never touch
    -- the provider from this fallback path either.
    if (Config.Coexistence or {}).OwnershipProtocol ~= false and not Voice.IsOwner(src) then
        session.voiceConnected = false
        return
    end

    -- What arrives here is a BACKEND id, because it is read from the voice
    -- provider's own state. Reverse-map it before comparing to anything.
    --
    -- STAND DOWN, DO NOT FIGHT.
    --
    -- A non-zero id that does not reverse-map is a channel this resource never
    -- issued -- another resource put the player there. The previous version
    -- treated that as unauthorised and reacted, which is precisely how two
    -- radios deadlocked the server: each saw the other's number as hostile and
    -- wrote the bag back, forever.
    --
    -- Somebody else's voice channel is not ours to correct. We leave it alone
    -- and stop tracking voice for that player until they use OUR radio again.
    -- Being a good neighbour costs nothing here; fighting cost the server.
    local channel
    if backendChannel <= 0 then
        channel = 0
    else
        channel = RSRadioChannels.Display(backendChannel)
        if not channel then
            session.voiceConnected = false
            return
        end
    end

    if channel == session.channel and not session.jammed then session.voiceConnected = channel > 0 return end
    if channel <= 0 and session.jammed then session.voiceConnected = false return end

    if channel <= 0 then
        local old = session.channel
        if old > 0 then
            snapshotLastKnown(src, old)
            removeMember(src, old)
            session.talkSerial = (session.talkSerial or 0) + 1
            session.channel, session.powered, session.talking = 0, false, false
            session.voiceConnected = false
            syncReplicatedState(src)
            TriggerClientEvent('rs-radio:client:left', src, 'voice_sync')
            markDirty(old)
        end
        return
    end

    if Config.Security.ExternalVoicePolicy == 'reject' then
        Voice.SetPlayerChannel(src, session.jammed and 0 or RSRadioChannels.Backend(session.channel))
        return
    end

    local allowed = isAllowed(src, channel)
    if not allowed then
        Voice.RemovePlayer(src)
        TriggerClientEvent('rs-radio:client:denied', src, 'denied')
        return
    end

    local old = session.channel
    if old > 0 then
        snapshotLastKnown(src, old)
        removeMember(src, old)
        markDirty(old)
    end
    session.channel, session.powered, session.voiceConnected = channel, true, true
    addMember(src, channel)
    addRecentChannel(src, channel)
    local jammer = jammerAffecting(src, channel)
    if jammer then setJammed(src, jammer) end
    syncReplicatedState(src)
    local profile = getProfile(src)
    TriggerClientEvent('rs-radio:client:joined', src, {
        channel = channel, label = channelLabel(channel), battery = session.battery,
        volume = profile.volume, jammed = session.jammed, channels = buildChannels(src),
        voice = { provider = Voice.Provider(), capabilities = Voice.Capabilities() }
    })
    markDirty(channel)
end)

local function setPlayerTeam(src, team, callsign, role)
    src = finiteNumber(src)
    if not src or not GetPlayerName(src) then return false end
    team = team and tostring(team) or nil
    if team and not Config.Teams[team] then return false end
    Assignments[src] = {
        team = team,
        callsign = tostring(callsign or GetPlayerName(src)),
        role = tostring(role or 'member'),
        name = GetPlayerName(src)
    }
    local session = getSession(src)
    if session.channel > 0 and not canAccess(src, session.channel) then leaveRadio(src, 'assignment_changed')
    elseif session.channel > 0 then sendRoster(session.channel) end
    syncReplicatedState(src)
    sendState(src, false)
    return true
end
exports('SetPlayerTeam', setPlayerTeam)

local function clearPlayerTeam(src)
    src = finiteNumber(src)
    if not src then return false end
    Assignments[src] = nil
    local session = Sessions[src]
    if session and session.channel > 0 then
        if not canAccess(src, session.channel) then leaveRadio(src, 'assignment_changed') else sendRoster(session.channel) end
        syncReplicatedState(src)
        sendState(src, false)
    elseif GetPlayerName(src) then
        syncReplicatedState(src)
    end
    return true
end
exports('ClearPlayerTeam', clearPlayerTeam)
exports('GetPlayerTeam', function(src) return resolveAssignment(finiteNumber(src)) end)

local function setBattery(src, level)
    src = finiteNumber(src)
    if not src or not GetPlayerName(src) then return false end
    local ok = activateDevice(src)
    if not ok then return false end
    local session = getSession(src)
    session.battery = math.floor(clamp(level, 0, 100))
    persistBattery(session)
    TriggerClientEvent('rs-radio:client:battery', src, session.battery)
    if Config.Battery.Enabled and session.battery <= 0 and session.channel > 0 then leaveRadio(src, 'dead_battery') end
    return session.battery
end
exports('SetBattery', setBattery)
exports('RechargeRadio', function(src, amount)
    local session = getSession(finiteNumber(src))
    return setBattery(src, session.battery + (finiteNumber(amount) or 100))
end)
exports('GetBattery', function(src)
    if not activateDevice(finiteNumber(src)) then return false end
    return getSession(finiteNumber(src)).battery
end)

local function resetProfile(src)
    src = finiteNumber(src)
    if not src or not GetPlayerName(src) then return false end
    local key = profileKey(src)
    Profiles[key] = defaultProfile()
    local session = getSession(src)
    session.pendingProfile, session.pendingFavorites = nil, nil
    session.volume = Profiles[key].volume
    Voice.SetPlayerDeaf(src, false)
    scheduleSave('profiles')
    TriggerClientEvent('rs-radio:client:profile', src, Profiles[key], buildChannels(src))
    TriggerClientEvent('rs-radio:client:volume', src, Profiles[key].volume, false)
    TriggerClientEvent('rs-radio:client:profileReset', src)
    if session.channel > 0 then sendRoster(session.channel) end
    return true
end
exports('ResetProfile', resetProfile)
RegisterNetEvent('rs-radio:server:resetProfile', function()
    local src = source
    if rateLimited(getSession(src), 'lastProfileReset', Config.Security.ProfileResetCooldownMs or 5000) then return end
    resetProfile(src)
end)

RegisterCommand('rsradioteam', function(src, args)
    if src ~= 0 and not IsPlayerAceAllowed(src, 'rsradio.admin') then return end
    local target, team, callsign, role = finiteNumber(args[1]), args[2], args[3], args[4]
    if target and team then setPlayerTeam(target, team, callsign, role) end
end, false)

RegisterCommand(Config.Profile.ResetCommand or 'rsradioreset', function(src)
    if src > 0 and not rateLimited(getSession(src), 'lastProfileReset', Config.Security.ProfileResetCooldownMs or 5000) then resetProfile(src) end
end, false)

RegisterCommand(Config.Battery.RechargeCommand or 'rechargeradio', function(src)
    if src > 0 then rechargePlayer(src) end
end, false)

RegisterCommand(Config.Jammer.Command or 'rsjammer', function(src, args)
    if src <= 0 then return end
    if not Config.Jammer.Enabled or not hasJammerPermission(src) then TriggerClientEvent('rs-radio:client:denied', src, 'jammer_denied') return end
    local action = string.lower(args[1] or 'status')
    if action == 'place' then
        TriggerClientEvent('rs-radio:client:placeJammer', src, finiteNumber(args[2]) or Config.Jammer.Range.Default)
    elseif action == 'remove' or action == 'toggle' then
        handleJammerAction(src, action)
    elseif action == 'range' or action == 'allow' then
        handleJammerAction(src, action, finiteNumber(args[2]))
    elseif not rateLimited(getSession(src), 'lastJammerStatus', Config.Security.JammerStatusCooldownMs or 500) then
        sendNearestJammerStatus(src)
    end
end, false)

local function reevaluatePlayerAccess(src, reason)
    src = finiteNumber(src)
    if not src or not GetPlayerName(src) then return end
    local session = Sessions[src]
    if not session then return end

    if session.channel > 0 and not canAccess(src, session.channel) then
        leaveRadio(src, reason or 'assignment_changed')
        return
    end

    syncReplicatedState(src)
    if session.channel > 0 then
        sendRoster(session.channel)
        sendDistressBoard(src)
    end
    sendState(src, false)
end

local function clearPlayerRuntime(src, reason)
    src = finiteNumber(src)
    if not src then return end
    local session = Sessions[src]
    ReplicationPending[src] = nil
    if GetPlayerName(src) then
        TriggerClientEvent('rs-radio:client:forceClose', src, reason or 'player_unloaded')
    end
    if session and session.channel > 0 and GetPlayerName(src) then
        leaveRadio(src, reason or 'player_unloaded')
    end
    Sessions[src], Telemetry[src], Assignments[src], Distress[src] = nil, nil, nil, nil
    broadcastDistressBoards()
end

-- Reactive framework authorization. A player who changes job, gang, duty,
-- group, or radio-related metadata is re-evaluated immediately instead of
-- remaining on a stale restricted channel until their next interaction.
AddEventHandler('QBCore:Server:OnJobUpdate', function(src)
    reevaluatePlayerAccess(src, 'job_changed')
end)

AddEventHandler('QBCore:Server:OnGangUpdate', function(src)
    reevaluatePlayerAccess(src, 'gang_changed')
end)

AddEventHandler('QBCore:Server:SetDuty', function(src)
    reevaluatePlayerAccess(src, 'duty_changed')
end)

AddEventHandler('QBCore:Server:OnPermissionUpdate', function(src)
    reevaluatePlayerAccess(src, 'permission_changed')
end)

AddEventHandler('QBCore:Server:OnPlayerUpdated', function(src, key)
    if key == 'job' or key == 'gang' or key == 'metadata' or key == 'all' then
        reevaluatePlayerAccess(src, 'player_data_changed')
    end
end)

AddEventHandler('qbx_core:server:onGroupUpdate', function(src)
    reevaluatePlayerAccess(src, 'group_changed')
end)

AddEventHandler('qbx_core:server:onSetMetaData', function(key, _, _, src)
    if key == Config.TeamMetadataKey or key == Config.RoleMetadataKey or key == Config.CallsignMetadataKey then
        reevaluatePlayerAccess(src, 'metadata_changed')
    end
end)

AddEventHandler('esx:setJob', function(src)
    reevaluatePlayerAccess(src, 'job_changed')
end)

AddEventHandler('QBCore:Server:OnPlayerUnload', function(src)
    clearPlayerRuntime(src, 'player_unloaded')
end)

AddEventHandler('esx:playerLogout', function(src)
    clearPlayerRuntime(src, 'player_unloaded')
end)

local function registerChannelChecks()
    for channel in pairs(Config.Channels) do
        -- Registered against the BACKEND id, because that is the channel
        -- pma-voice will ask about. The closure still reasons in display
        -- numbers, which is where permissions and jammers are defined.
        Voice.RegisterChannelCheck(RSRadioChannels.Backend(channel), function(src)
            local allowed = isAllowed(src, channel)
            if not allowed then return false end
            return jammerAffecting(src, channel) == nil
        end)
    end
end

local function initializePersistence()
    -- Channel map first: every voice join below depends on it, and it must be
    -- identical on every boot or players split across a restart.
    RSRadioChannels.Build()
    -- Must run before the first read: it decides which backend loadJson uses.
    initializeStore()
    Profiles = Config.Persistence.Enabled and loadJson(Config.Persistence.ProfilesFile, {}) or {}
    Batteries = Config.Persistence.Enabled and loadJson(Config.Persistence.BatteriesFile, {}) or {}
    local savedJammers = Config.Persistence.Enabled and loadJson(Config.Persistence.JammersFile, {}) or {}
    for key, profile in pairs(Profiles) do Profiles[key] = normalizeProfile(profile) end
    for _, data in ipairs(Config.Jammer.Defaults or {}) do
        data.persist = false
        data.canRemove = false
        spawnJammer(data)
    end
    for _, data in ipairs(savedJammers) do
        data.persist = true
        spawnJammer(data)
    end
end

if Config.EnableDiagnosticCommand ~= false then
    RegisterCommand(Config.DiagnosticCommand or 'rsradiodiag', function(src)
        if src <= 0 then
            print('[rs-radio] /rsradiodiag must be run by an in-game player so inventory ownership can be checked.')
            return
        end
        local d = Bridge.GetDiagnostics(src)
        local session = getSession(src)
        local assignment = resolveAssignment(src)
        d.radio = {
            channel = finiteNumber(session.channel) or 0,
            requestedChannel = finiteNumber(session.requestedChannel) or 0,
            confirmedChannel = finiteNumber(session.confirmedChannel) or 0,
            voiceConnected = session.voiceConnected == true,
            label = session.channel > 0 and channelLabel(session.channel) or 'OFFLINE',
            battery = session.battery,
            powered = session.powered == true,
            jammed = session.jammed == true,
            talking = session.talking == true,
            callsign = assignment.callsign,
            lastOwnershipReason = session.lastOwnershipReason,
            lastProviderConfirmation = session.lastProviderConfirmation
        }
        print(('[rs-radio][diag] src=%s framework=%s inventory=%s voiceProvider=%s voice=%s(%s) voice_enableRadios=%s radioMode=%s requireItem=%s')
            :format(src, tostring(d.framework), tostring(d.inventory), tostring(d.voiceProvider), tostring(d.voice), tostring(d.voiceState), tostring(d.voiceRadiosEnabled), tostring(d.accessMode), tostring(d.requireItem)))
        for _, item in ipairs(d.items or {}) do
            print(('[rs-radio][diag] item=%s registered=%s count=%s'):format(item.name, tostring(item.registered), tostring(item.count)))
        end
        local device = d.device or {}
        print(('[rs-radio][diag] device hasItem=%s item=%s slot=%s provider=%s reason=%s')
            :format(tostring(device.hasItem), tostring(device.item), tostring(device.slot), tostring(device.provider), tostring(device.reason)))
        print(('[rs-radio][diag] channel=%s label=%s powered=%s battery=%s jammed=%s talking=%s callsign=%s')
            :format(tostring(d.radio.channel), tostring(d.radio.label), tostring(d.radio.powered), tostring(d.radio.battery), tostring(d.radio.jammed), tostring(d.radio.talking), tostring(d.radio.callsign)))
        -- Backend keys are implementation detail, not an authorization secret.
        -- Access is enforced server-side regardless of whether source is public.
        print(('[rs-radio][diag] logicalChannels=%s logicalId=%s backend=[internal]')
            :format(tostring(RSRadioChannels.Enabled()),
                    tostring(RSRadioChannels.Logical(d.radio.channel) or 'n/a')))
        TriggerClientEvent('rs-radio:client:diagnostics', src, d)
    end, false)
end

do
    local coexistence = Config.Coexistence or {}
    if coexistence.EnableOwnershipDiagnosticCommand ~= false then
        RegisterCommand(tostring(coexistence.OwnershipDiagnosticCommand or 'rsradiostate'), function(src)
            if src <= 0 then
                print('[rs-radio] /rsradiostate must be run by an in-game player.')
                return
            end
            local session = getSession(src)
            local owner = Voice.GetOwnership(src)
            local siblings = Voice.DetectedSiblingRadios and Voice.DetectedSiblingRadios() or {}
            print(('^5[RS RADIO VOICE STATE]^7 src=%s controller=%s owner=%s requested=%s confirmed=%s provider=%s providerChannel=%s connected=%s tx=%s jammed=%s generation=%s reason=%s')
                :format(src, tostring(Voice.ControllerId()), tostring(owner.owner or 'none'),
                    tostring(session.requestedChannel or 0), tostring(session.confirmedChannel or 0),
                    tostring(Voice.Provider()), tostring(owner.providerChannel or 0), tostring(session.voiceConnected == true),
                    tostring(session.talking == true), tostring(session.jammed == true), tostring(owner.generation or 0),
                    tostring(session.lastOwnershipReason or 'none')))
            for name, state in pairs(siblings) do
                print(('[rs-radio][ownership] sibling=%s state=%s'):format(name, tostring(state)))
            end
        end, false)
    end
end

CreateThread(function()
    initializePersistence()
    Wait(500)
    registerChannelChecks()
    Bridge.RegisterUsableItems()
    if Bridge.ValidateConfiguredItems then Bridge.ValidateConfiguredItems() end
    broadcastJammers()
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= Voice.Resource() or Voice.Provider() ~= 'pma-voice' then return end
    SetTimeout(1500, function()
        registerChannelChecks()
        for src, session in pairs(Sessions) do
            if session.channel > 0 and GetPlayerName(src) then
                local allowed = isAllowed(src, session.channel)
                local jammer = jammerAffecting(src, session.channel)
                if allowed and not jammer then
                    if not setVoiceChannel(src, session.channel) then leaveRadio(src, 'no_voice') end
                elseif jammer then
                    setJammed(src, jammer)
                else
                    leaveRadio(src, 'denied')
                end
            end
        end
    end)
end)

CreateThread(function()
    while true do
        Wait(Config.ItemAuditInterval)
        for src, session in pairs(Sessions) do
            if session.channel > 0 and GetPlayerName(src) then
                if not canAccess(src, session.channel) then leaveRadio(src, 'assignment_changed')
                elseif Config.CloseWhenItemMissing and Config.RequireRadioItem then
                    local ok, reason = activateDevice(src)
                    if not ok then leaveRadio(src, 'item_missing')
                    elseif Config.Battery.Enabled and session.battery <= 0 then leaveRadio(src, 'dead_battery') end
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(60000)
        if Config.Battery.Enabled then
            for src, session in pairs(Sessions) do
                if session.channel > 0 and session.powered then
                    session.battery = math.max(0, session.battery - Config.Battery.DrainPerMinute)
                    persistBattery(session)
                    TriggerClientEvent('rs-radio:client:battery', src, session.battery)
                    if session.battery <= 0 then leaveRadio(src, 'dead_battery') end
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Jammer.AuditInterval or 1000)
        if Config.Jammer.Enabled then
            for id, jammer in pairs(Jammers) do
                if jammer.canDamage and jammer.entity and DoesEntityExist(jammer.entity) and GetEntityHealth(jammer.entity) <= 0 then
                    removeJammer(jammer, false)
                elseif jammer.entity and not DoesEntityExist(jammer.entity) then
                    Jammers[id] = nil
                    scheduleSave('jammers')
                    broadcastJammers()
                end
            end
            for src, session in pairs(Sessions) do
                if session.channel > 0 and GetPlayerName(src) then
                    setJammed(src, jammerAffecting(src, session.channel))
                end
            end
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Roster.FlushInterval)
        local now = os.time()
        local distressChanged = false
        -- Native PTT cannot depend on a dead/disconnected client sending key-up.
        if Voice.Provider() == 'cfx-native' then
            for src, session in pairs(Sessions) do
                if session.talking then
                    local allowed, reason = isAllowed(src, session.channel)
                    local ped = GetPlayerPed(src)
                    local metadata = (Bridge.GetPlayerData(src) or {}).metadata or {}
                    if not allowed then leaveRadio(src, reason)
                    elseif not ped or ped <= 0 or not DoesEntityExist(ped) or GetEntityHealth(ped) <= 100
                        or metadata.isdead == true or metadata.inlaststand == true then
                        session.talking = false
                        session.talkSerial = (session.talkSerial or 0) + 1
                        Voice.SetTransmitState(src, false)
                        syncReplicatedState(src)
                        markDirty(session.channel)
                        TriggerClientEvent('rs-radio:client:talkingTimeout', src)
                    end
                end
            end
        end
        for src, distress in pairs(Distress) do
            if distress.active and distress.expires <= now then
                distress.active = false
                distressChanged = true
                syncReplicatedState(src)
                TriggerClientEvent('rs-radio:client:distressState', src, { active = false, expired = true })
                local session = Sessions[src]
                if session and session.channel > 0 then markDirty(session.channel) end
            end
            if not distress.active and distress.cooldownUntil <= now then Distress[src] = nil end
        end
        if distressChanged then broadcastDistressBoards() end

        for channel, entries in pairs(LastKnown) do
            for src, entry in pairs(entries) do
                if now - entry.leftAt > Config.LastKnown.KeepSeconds then entries[src] = nil markDirty(channel) end
            end
        end
        for channel in pairs(DirtyChannels) do DirtyChannels[channel] = nil sendRoster(channel) end
    end
end)

AddEventHandler('playerDropped', function()
    local src = source
    -- Source ids are reused; a stale pending flag would suppress the first
    -- sync for whoever connects onto this id next.
    ReplicationPending[src] = nil
    local session = Sessions[src]
    if session and session.channel > 0 then
        local old = session.channel
        pcall(snapshotLastKnown, src, old)
        removeMember(src, old)
        SetTimeout(0, function() sendRoster(old) end)
    end
    Sessions[src], Telemetry[src], Assignments[src], Distress[src] = nil, nil, nil, nil
    broadcastDistressBoards()
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    saveJsonNow('profiles')
    saveJsonNow('batteries')
    saveJsonNow('jammers')
    for src, session in pairs(Sessions) do
        if session.channel > 0 and GetPlayerName(src) then
            local wasOwner = Voice.IsOwner(src)
            Voice.RemovePlayer(src, 'resource_stop')
            if wasOwner then
                session.channel, session.talking, session.jammed = 0, false, false
                Distress[src] = nil
                flushReplicatedState(src)
            end
        end
    end
    for _, jammer in pairs(Jammers) do
        if jammer.entity and DoesEntityExist(jammer.entity) then DeleteEntity(jammer.entity) end
    end
end)


-- ---------------------------------------------------------------------------
-- Communication events
--
-- Step 5. A dispatch exists ONCE on the server; this section is only how a
-- radio says it. The shape is defined in shared/commevent.lua and is identical
-- across every RS device -- what differs is everything below this comment.
--
-- Radio voice: short, shouted, no interactive controls. A handheld cannot offer
-- [Open Map] or [Acknowledge], so those are not rendered here even when the
-- event carries them. Putting every backend capability on every device is
-- exactly how three devices stop feeling like three devices.
--
-- Subscribed with AddEventHandler, never RegisterNetEvent: clients can only
-- reach net events, so no player can forge an officer-emergency broadcast.
-- ---------------------------------------------------------------------------
local function commEventRecipients(event)
    local dest = event.destination or {}
    local recipients = {}

    local function add(src)
        src = finiteNumber(src)
        if not src or not GetPlayerName(src) then return end
        local session = Sessions[src]
        -- A radio that is off or out of a channel is not a delivery target.
        -- Silently dropping here is correct: the pager is the device that
        -- queues, and duplicating that behaviour would make the radio lie.
        if not session or session.channel <= 0 then return end
        recipients[src] = true
    end

    if dest.channels then
        for _, channel in ipairs(dest.channels) do
            for src in pairs(Members[finiteNumber(channel) or -1] or {}) do add(src) end
        end
    end

    if dest.players then
        for _, src in ipairs(dest.players) do add(src) end
    end

    -- Departments are server-side aliases for a set of jobs. Resolving them
    -- here, rather than making every dispatcher learn job names, is what lets
    -- one dispatch reach radio, pager and tablet identically.
    local departmentJobs
    if dest.departments then
        for _, name in ipairs(dest.departments) do
            local department = Config.Departments and Config.Departments[tostring(name)]
            if department then
                departmentJobs = departmentJobs or {}
                for _, job in ipairs(department.names or {}) do
                    -- Each alias retains its own duty policy. An unrestricted
                    -- alias for a job also allows that job off duty.
                    if departmentJobs[job] == nil or department.dutyOnly ~= true then
                        departmentJobs[job] = department.dutyOnly == true
                    end
                end
            end
        end
    end

    -- ON `groups` VERSUS `gangs`
    -- --------------------------
    -- The common protocol treats these as DIFFERENT destinations: `groups` is
    -- a hidden, manually assigned set and `gangs` is the framework gang.
    -- rs-90sbeeper keeps a real group registry; a radio has none, so here
    -- `groups` is deliberately an ALIAS for the framework gang. Both keys are
    -- accepted and both match data.gang.
    --
    -- This is documented, not accidental. The previous code matched `groups`
    -- against data.gang while ignoring `gangs` entirely, so a gang-addressed
    -- dispatch -- the normal way to page a crew -- reached nobody at all.
    if dest.jobs or dest.gangs or dest.groups or departmentJobs or dest.broadcast then
        for src, session in pairs(Sessions) do
            if session.channel > 0 and GetPlayerName(src) then
                if dest.broadcast then
                    add(src)
                else
                    local data = Bridge.GetPlayerData(src) or {}
                    -- dutyOnly arrives on the event for jobs, and per-department
                    -- from Config.Departments. Ignoring it would put duty-only
                    -- traffic on off-duty radios.
                    local onDuty = data.onduty ~= false
                    if dest.jobs and listContains(dest.jobs, data.job)
                        and (dest.dutyOnly ~= true or onDuty) then add(src) end
                    if departmentJobs and departmentJobs[data.job] ~= nil
                        and (not departmentJobs[data.job] or onDuty) then add(src) end
                    if dest.gangs and listContains(dest.gangs, data.gang) then add(src) end
                    if dest.groups and listContains(dest.groups, data.gang) then add(src) end
                end
            end
        end
    end

    return recipients
end

--- Event -> radio traffic. Deliberately flat: the LCD has no room for a card.
local function renderForRadio(event, src)
    local session = Sessions[src]
    local assignment = resolveAssignment(event.source and event.source.player or src) or {}
    return {
        id = event.id,
        priority = event.priority,
        -- Emergency traffic gets the classic banner; anything calmer does not,
        -- so the banner keeps meaning something.
        banner = RSCommEvent.AtLeast(event, 'emergency') and 'EMERGENCY TRAFFIC'
            or (RSCommEvent.AtLeast(event, 'priority') and 'PRIORITY TRAFFIC' or nil),
        code = event.metadata and event.metadata.code or nil,
        callsign = (event.source and event.source.callsign) or assignment.callsign,
        title = event.message and event.message.title,
        body = event.message and event.message.body,
        -- Coordinates are sent, not a street name: the client already resolves
        -- streets natively and doing it server-side would be a second answer.
        location = event.location,
        channel = session and session.channel or 0,
        label = session and session.channel > 0 and channelLabel(session.channel) or nil,
        at = event.createdAt,
    }
end

AddEventHandler(RSCommEvent.EVENT, function(raw)
    if Config.CommEvents and Config.CommEvents.Enabled == false then return end

    local event, reason = RSCommEvent.Normalize(raw)
    if not event then
        if Config.Debug then
            print(('[rs-radio] communication event rejected: %s'):format(tostring(reason)))
        end
        return
    end
    if not RSCommEvent.TargetsDevice(event, 'radio') then return end
    if RSCommEvent.Expired(event) then return end

    -- Floor lets an owner keep routine chatter off the radio without the
    -- dispatcher having to know which devices a given server runs.
    local floor = (Config.CommEvents and Config.CommEvents.MinPriority) or 'routine'
    if not RSCommEvent.AtLeast(event, floor) then return end

    for src in pairs(commEventRecipients(event)) do
        TriggerClientEvent('rs-radio:client:traffic', src, renderForRadio(event, src))
    end
end)

--- Server-side helper so another RS resource can raise an event without
--- knowing which devices exist. Returns the normalized event for logging.
exports('DispatchCommEvent', function(raw)
    local event, reason = RSCommEvent.Normalize(raw)
    if not event then return false, reason end
    TriggerEvent(RSCommEvent.EVENT, event)
    return true, event
end)

-- ---------------------------------------------------------------------------
-- DISPATCH SMOKE TEST
--
-- Nothing on a stock install raises a communication event, so routing cannot be
-- exercised without first writing a dispatcher. This raises a REAL event on the
-- real bus: every installed RS device receives it exactly as it would from a
-- production dispatcher, and each normalizes it with its own vendored protocol
-- copy. That is the point -- a device on an older copy legitimately matching
-- zero recipients is the bug this command exists to make visible.
--
--   rsdispatchtest broadcast
--   rsdispatchtest job police
--   rsdispatchtest gang ballas
--   rsdispatchtest group detectives
--   rsdispatchtest department police emergency
--   rsdispatchtest channel 200
--   rsdispatchtest player 3 urgent
--
-- Server console always; in game it needs the rsradio.admin ace, matching
-- rsradioteam. Set Config.CommEvents.DispatchTestCommand = false to remove it entirely.
--
-- Everything lives inside the handler on purpose: Lua caps a chunk at 200
-- active locals and these files are long, so the harness adds none at file
-- scope.
-- ---------------------------------------------------------------------------
if Config.CommEvents and Config.CommEvents.DispatchTestCommand ~= false then
    RegisterCommand(Config.CommEvents.DispatchTestCommand or 'rsdispatchtest', function(src, args)
        if src ~= 0 and not IsPlayerAceAllowed(src, 'rsradio.admin') then return end

        local resource = GetCurrentResourceName()
        local function reply(line)
            print(('[%s] %s'):format(resource, line))
            if src > 0 then
                TriggerClientEvent('chat:addMessage', src, { args = { 'DISPATCH TEST', line } })
            end
        end

        local kinds = {
            broadcast = 'broadcast', player = 'players', players = 'players',
            channel = 'channels', job = 'jobs', jobs = 'jobs',
            gang = 'gangs', gangs = 'gangs', group = 'groups', groups = 'groups',
            department = 'departments', departments = 'departments',
        }

        local kind = string.lower(tostring(args[1] or ''))
        local key = kinds[kind]
        if not key then
            reply('usage: rsdispatchtest <broadcast|player|channel|job|gang|group|department> [value] [priority]')
            return
        end

        -- broadcast takes no value, so its priority sits one argument earlier.
        local value, priority
        if key == 'broadcast' then value, priority = nil, args[2] else value, priority = args[2], args[3] end
        priority = string.lower(tostring(priority or 'priority'))
        if priority ~= 'routine' and priority ~= 'priority' and priority ~= 'urgent' and priority ~= 'emergency' then
            priority = 'priority'
        end

        local destination
        if key == 'broadcast' then
            destination = { broadcast = true }
        elseif value == nil or value == '' then
            reply(('destination "%s" needs a value'):format(kind))
            return
        elseif key == 'players' or key == 'channels' then
            local number = finiteNumber(value)
            if not number then
                reply(('%s must be a number, got "%s"'):format(kind, tostring(value)))
                return
            end
            destination = { [key] = { math.floor(number) } }
        else
            destination = { [key] = { value } }
        end

        local raw = {
            type = 'dispatch',
            priority = priority,
            source = { player = src > 0 and src or nil, callsign = 'TEST-1', department = 'DISPATCH TEST' },
            destination = destination,
            message = {
                title = ('%s TEST'):format(kind:upper()),
                body = ('Raised from %s at %s.'):format(resource, os.date('%H:%M:%S')),
            },
            metadata = { code = '911', callback = '555-0199', instructions = 'USE PAYPHONE' },
            ttl = 120,
        }

        TriggerEvent(RSCommEvent.EVENT, raw)

        -- Report what THIS radio matched. Other devices report separately, and
        -- a mismatch between them is exactly the signal worth looking at.
        local event, reason = RSCommEvent.Normalize(raw)
        if not event then
            reply(('event REJECTED by this resource: %s'):format(tostring(reason)))
            return
        end
        local matched = 0
        for _ in pairs(commEventRecipients(event)) do matched = matched + 1 end
        reply(('raised %s=%s priority=%s -- %d radio(s) matched here')
            :format(kind, tostring(value or '-'), priority, matched))
    end, false)
end
