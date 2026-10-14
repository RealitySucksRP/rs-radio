RSRadioVoice = RSRadioVoice or {}
local Voice = RSRadioVoice

local function resourceName()
    local voice = type(Config.Voice) == 'table' and Config.Voice or {}
    return tostring(voice.Resource or Config.VoiceResource or 'pma-voice')
end

local function configuredBackend()
    local voice = type(Config.Voice) == 'table' and Config.Voice or {}
    local value = tostring(voice.Backend or Config.VoiceBackend or 'auto'):lower()
    if value == 'native' or value == 'cfx' or value == 'cfx_native' then value = 'cfx-native' end
    if value == 'pma' then value = 'pma-voice' end
    if value ~= 'auto' and value ~= 'cfx-native' and value ~= 'pma-voice' then value = 'auto' end
    return value
end

-- GTAV Enhanced's current voice API is server-owned. These are the minimum
-- primitives required for a real walkie-talkie channel: create, add/remove,
-- and server-side transmit/listen gating. Do not use a Mumble native as the
-- feature test; those are the deprecated compatibility path on Enhanced.
function Voice.NativeVoiceAvailable()
    return type(CreateVoiceChannel) == 'function'
        and type(DeleteVoiceChannel) == 'function'
        and type(AddPlayerToVoiceChannel) == 'function'
        and type(RemovePlayerFromVoiceChannel) == 'function'
        and type(SetPlayerMutedInVoiceChannel) == 'function'
        and type(SetPlayerDeafInVoiceChannel) == 'function'
end

local probeNativeVoice
local nativeRuntimeConfirmed = false

function Voice.Provider()
    local backend = configuredBackend()
    if backend == 'cfx-native' then
        return Voice.NativeVoiceAvailable() and 'cfx-native' or 'none'
    end
    if backend == 'pma-voice' then
        return GetResourceState(resourceName()) == 'started' and 'pma-voice' or 'none'
    end

    -- Auto prefers the secure server-owned Enhanced API. Legacy servers do not
    -- expose these natives and fall back to pma-voice.
    -- Some artifacts expose bindings for an API the runtime cannot execute.
    -- Probe once before selecting it; after native success never silently
    -- downgrade to client-controlled compatibility on a transient voice outage.
    if nativeRuntimeConfirmed or probeNativeVoice() then
        nativeRuntimeConfirmed = true
        return 'cfx-native'
    end
    if GetResourceState(resourceName()) == 'started' then return 'pma-voice' end
    return 'none'
end

function Voice.Resource()
    return resourceName()
end

local nativeProbeReady = nil
local nativeProbeAt = 0

probeNativeVoice = function()
    if not Voice.NativeVoiceAvailable() then return false end
    local now = GetGameTimer()
    if nativeProbeReady ~= nil and (now - nativeProbeAt) < 2000 then return nativeProbeReady end

    nativeProbeAt = now
    local ok, channelId = pcall(CreateVoiceChannel, 0, 0.0)
    channelId = ok and tonumber(channelId) or nil
    nativeProbeReady = channelId ~= nil and channelId >= 0 and channelId < 65535
    if nativeProbeReady then pcall(DeleteVoiceChannel, channelId) end
    return nativeProbeReady
end

function Voice.IsReady()
    local provider = Voice.Provider()
    if provider == 'cfx-native' then return probeNativeVoice() end
    if provider == 'pma-voice' then
        return GetResourceState(resourceName()) == 'started' and GetConvarInt('voice_enableRadios', 1) == 1
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Enhanced native channel ownership
-- ---------------------------------------------------------------------------
local nativeRoutes = {}       -- logical backend key -> { id, members = {} }
local nativePlayerRoute = {}  -- source -> logical backend key

local function deleteNativeRoute(routeKey)
    local route = nativeRoutes[routeKey]
    if not route then return end
    pcall(DeleteVoiceChannel, route.id)
    nativeRoutes[routeKey] = nil
end

local function releaseNativeMember(src)
    local routeKey = nativePlayerRoute[src]
    if not routeKey then return true end
    local route = nativeRoutes[routeKey]
    nativePlayerRoute[src] = nil
    if not route then return true end

    pcall(RemovePlayerFromVoiceChannel, route.id, src)
    route.members[src] = nil
    if next(route.members) == nil then deleteNativeRoute(routeKey) end
    return true
end

local function getOrCreateNativeRoute(routeKey)
    local route = nativeRoutes[routeKey]
    if route then return route end

    local ok, channelId = pcall(CreateVoiceChannel, 0, 0.0) -- non-spatial radio
    channelId = ok and tonumber(channelId) or nil
    if not channelId or channelId < 0 or channelId >= 65535 then return nil end

    route = { id = channelId, members = {} }
    nativeRoutes[routeKey] = route
    return route
end

local function setNativeChannel(src, routeKey)
    routeKey = math.floor(tonumber(routeKey) or 0)
    if routeKey <= 0 then return releaseNativeMember(src) end

    local currentKey = nativePlayerRoute[src]
    if currentKey == routeKey then
        local current = nativeRoutes[routeKey]
        if current and current.members[src] then return true end
    end

    releaseNativeMember(src)
    local route = getOrCreateNativeRoute(routeKey)
    if not route then return false end

    local ok, result = pcall(AddPlayerToVoiceChannel, route.id, src)
    if not ok or result == false then
        if next(route.members) == nil then deleteNativeRoute(routeKey) end
        return false
    end

    -- Confirm both gates before publishing membership. A thrown/failed mute
    -- must never advertise an unprotected sender as connected.
    local muteOk, muteResult = pcall(SetPlayerMutedInVoiceChannel, route.id, src, true)
    local deafOk, deafResult = pcall(SetPlayerDeafInVoiceChannel, route.id, src, false)
    if not muteOk or muteResult == false or not deafOk or deafResult == false then
        pcall(RemovePlayerFromVoiceChannel, route.id, src)
        if next(route.members) == nil then deleteNativeRoute(routeKey) end
        return false
    end
    route.members[src] = true
    nativePlayerRoute[src] = routeKey
    return true
end

-- ---------------------------------------------------------------------------
-- pma-voice write echo suppression
-- ---------------------------------------------------------------------------
local selfWrites = {}
local ECHO_WINDOW_MS = 1500
local MAX_SELF_WRITES = 8

local function pruneSelfWrites(src, now)
    local queue = selfWrites[src]
    if not queue then return nil end
    now = now or GetGameTimer()
    local kept = {}
    for _, record in ipairs(queue) do
        if (now - record.at) <= ECHO_WINDOW_MS then kept[#kept + 1] = record end
    end
    if #kept == 0 then selfWrites[src] = nil return nil end
    selfWrites[src] = kept
    return kept
end

local function noteSelfWrite(src, value)
    local queue = pruneSelfWrites(src) or {}
    queue[#queue + 1] = { value = math.floor(tonumber(value) or 0), at = GetGameTimer() }
    while #queue > MAX_SELF_WRITES do table.remove(queue, 1) end
    selfWrites[src] = queue
end

local function removeNewestSelfWrite(src, value)
    local queue = pruneSelfWrites(src)
    if not queue then return end
    value = math.floor(tonumber(value) or 0)
    for index = #queue, 1, -1 do
        if queue[index].value == value then table.remove(queue, index) break end
    end
    if #queue == 0 then selfWrites[src] = nil end
end

function Voice.ConsumeSelfWrite(src, value)
    local queue = pruneSelfWrites(src)
    if not queue then return false end
    value = math.floor(tonumber(value) or 0)
    for index, record in ipairs(queue) do
        if record.value == value then
            table.remove(queue, index)
            if #queue == 0 then selfWrites[src] = nil end
            return true
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- RS radio-family ownership arbitration
--
-- pma-voice has one real radio channel per player. Multiple independent UI
-- resources may exist, but only one RS controller may own the provider at a
-- time. These state keys are deliberately shared by every RS radio resource;
-- they are not a hard dependency and contain no sensitive data.
-- ---------------------------------------------------------------------------
local CONTROLLER_ID = GetCurrentResourceName()
local OWNER_KEY = 'rsRadioVoiceOwner'
local OWNER_CHANNEL_KEY = 'rsRadioVoiceOwnerChannel'
local OWNER_GENERATION_KEY = 'rsRadioVoiceOwnerGeneration'
local ownershipLostHandlers = {}
local localGeneration = {}
-- Authorization lives in this VM. Player state bags are client-writable by
-- default and serve only as replicated diagnostics. Sibling updates arrive
-- through the existing server-only ownership event.
local authoritativeOwners = {}

local function ownershipProtocolEnabled()
    local coexistence = Config.Coexistence or {}
    return coexistence.Enabled ~= false and coexistence.OwnershipProtocol ~= false
end

local function playerState(src)
    local ok, player = pcall(Player, src)
    if not ok or not player then return nil end
    return player.state
end

local function readOwner(src)
    local entry = authoritativeOwners[src]
    if not entry then return nil, 0, 0 end
    return entry.owner, entry.channel, entry.generation
end

local function writeOwner(src, owner, channel, generation)
    local state = playerState(src)
    if not state then return false end
    local ok = pcall(function()
        state:set(OWNER_KEY, owner or '', true)
        state:set(OWNER_CHANNEL_KEY, math.floor(tonumber(channel) or 0), true)
        state:set(OWNER_GENERATION_KEY, math.floor(tonumber(generation) or 0), true)
    end)
    if ok then
        authoritativeOwners[src] = { owner = owner, channel = channel or 0, generation = generation or 0 }
    end
    return ok
end

local function nextGeneration(src)
    local _, _, shared = readOwner(src)
    local current = math.max(math.floor(tonumber(localGeneration[src]) or 0), shared)
    current = current + 1
    localGeneration[src] = current
    return current
end

local function providerChannel(src)
    if Voice.Provider() == 'cfx-native' then
        return math.floor(tonumber(nativePlayerRoute[src]) or 0)
    end
    local state = playerState(src)
    if not state then return nil end
    local value = state.radioChannel
    if value == nil then return nil end
    return math.floor(tonumber(value) or 0)
end

local function performProviderWrite(src, channel)
    channel = math.floor(tonumber(channel) or 0)
    if Voice.Provider() == 'cfx-native' then
        return setNativeChannel(src, channel)
    end
    if Voice.Provider() ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return false end

    noteSelfWrite(src, channel)
    local ok = pcall(function()
        exports[resourceName()]:setPlayerRadio(src, channel)
    end)
    if not ok then
        removeNewestSelfWrite(src, channel)
        return false
    end

    -- Current pma-voice updates Player(source).state.radioChannel inside the
    -- server export. Verify it when available so a rejected channel is never
    -- advertised as connected. Compatibility forks without the state getter
    -- retain the previous pcall-success behavior.
    local actual = providerChannel(src)
    if actual ~= nil and actual ~= channel then
        -- Rejected pma requests commonly resolve to 0. Tag that provider-written
        -- result too so the asynchronous state-bag observer does not misclassify
        -- our failed attempt as a third-party takeover.
        noteSelfWrite(src, actual)
        return false
    end
    return true
end

local function notifyOwnershipLost(src, payload)
    for _, callback in ipairs(ownershipLostHandlers) do
        local ok, err = pcall(callback, src, payload)
        if not ok then
            print(('^1[%s] ownership-lost callback failed: %s^7'):format(CONTROLLER_ID, tostring(err)))
        end
    end
end

function Voice.ControllerId()
    return CONTROLLER_ID
end

function Voice.GetOwnership(src)
    local owner, channel, generation = readOwner(src)
    return {
        owner = owner,
        channel = channel,
        generation = generation,
        isOwner = owner == CONTROLLER_ID,
        providerChannel = providerChannel(src)
    }
end

function Voice.IsOwner(src)
    if not ownershipProtocolEnabled() then return true end
    local owner = readOwner(src)
    return owner == CONTROLLER_ID
end

function Voice.RegisterOwnershipLostHandler(callback)
    if type(callback) ~= 'function' then return false end
    ownershipLostHandlers[#ownershipLostHandlers + 1] = callback
    return true
end

-- Local cleanup after another controller wins. On pma this MUST NOT write 0;
-- doing so would disconnect the new owner. Enhanced native routes are private
-- to this resource, so releasing our old membership cannot affect the winner.
function Voice.StandDownLocal(src)
    if nativePlayerRoute[src] then return releaseNativeMember(src) end
    return true
end

local function clearOwnedState(src, reason, observedChannel)
    local owner, oldChannel, generation = readOwner(src)
    if owner ~= CONTROLLER_ID then return false end
    generation = math.max(generation, nextGeneration(src))
    writeOwner(src, nil, 0, generation)
    local payload = {
        owner = nil,
        previousOwner = CONTROLLER_ID,
        channel = math.floor(tonumber(observedChannel) or 0),
        previousChannel = oldChannel,
        generation = generation,
        reason = reason or 'external_provider'
    }
    TriggerEvent('rs-radio:ownership:released', src, payload)
    TriggerEvent('rs-radio:ownership:changed', src, payload)
    return true
end

function Voice.MarkExternalTakeover(src, observedChannel)
    if not ownershipProtocolEnabled() then return false end
    if clearOwnedState(src, 'external_provider', observedChannel) then return true end

    -- We may be logically suspended (for example jammed) and therefore have no
    -- shared owner at this instant. A third-party pma change still means this
    -- device must abandon any stale local session so it cannot later reassert or
    -- apply settings over the new controller.
    local owner, ownerChannel, generation = readOwner(src)
    notifyOwnershipLost(src, {
        owner = owner,
        previousOwner = nil,
        channel = math.floor(tonumber(observedChannel) or 0),
        previousChannel = ownerChannel,
        generation = generation,
        reason = 'external_provider'
    })
    return true
end

function Voice.SetPlayerChannel(src, channel, reason)
    if not Voice.IsReady() then return false end
    channel = math.floor(tonumber(channel) or 0)

    if not ownershipProtocolEnabled() then
        return performProviderWrite(src, channel)
    end

    if channel <= 0 then
        return Voice.RemovePlayer(src, reason or 'channel_zero')
    end

    local previousOwner, previousChannel = readOwner(src)
    local generation = nextGeneration(src)
    local request = {
        owner = CONTROLLER_ID,
        channel = channel,
        previousOwner = previousOwner,
        previousChannel = previousChannel,
        generation = generation,
        reason = reason or (previousOwner and previousOwner ~= CONTROLLER_ID and 'device_switch' or 'join')
    }
    TriggerEvent('rs-radio:ownership:request', src, request)

    local ok = performProviderWrite(src, channel)
    if not ok then
        request.reason = 'provider_failed'
        TriggerEvent('rs-radio:ownership:providerFailed', src, request)
        return false
    end

    if not writeOwner(src, CONTROLLER_ID, channel, generation) then
        -- We changed the provider but could not publish authoritative owner state.
        -- Fail closed and undo only our own write before reporting failure.
        performProviderWrite(src, 0)
        request.reason = 'owner_state_failed'
        TriggerEvent('rs-radio:ownership:providerFailed', src, request)
        return false
    end

    TriggerEvent('rs-radio:ownership:changed', src, request)
    return true
end

function Voice.RemovePlayer(src, reason)
    if not ownershipProtocolEnabled() then
        return performProviderWrite(src, 0)
    end

    local owner, previousChannel, generation = readOwner(src)
    if owner ~= CONTROLLER_ID then
        -- Critical invariant: a stale/non-owner radio performs local cleanup only.
        Voice.StandDownLocal(src)
        return true
    end

    local ok = performProviderWrite(src, 0)
    if not ok then return false end

    generation = math.max(generation, nextGeneration(src))
    writeOwner(src, nil, 0, generation)
    local payload = {
        owner = nil,
        previousOwner = CONTROLLER_ID,
        channel = 0,
        previousChannel = previousChannel,
        generation = generation,
        reason = reason or 'leave',
        intentionalRelease = true
    }
    TriggerEvent('rs-radio:ownership:released', src, payload)
    TriggerEvent('rs-radio:ownership:changed', src, payload)
    return true
end

-- Every sibling uses the same local server event. A client cannot forge this
-- with TriggerServerEvent because it is intentionally not registered as a net
-- event. Only the previous owner tears down its own logical/UI state.
AddEventHandler('rs-radio:ownership:changed', function(src, payload)
    src = tonumber(src)
    if not src or src <= 0 or type(payload) ~= 'table' then return end
    authoritativeOwners[src] = { owner = payload.owner, channel = tonumber(payload.channel) or 0,
        generation = tonumber(payload.generation) or 0 }
    local newOwner = payload.owner
    local previousOwner = payload.previousOwner
    if newOwner ~= CONTROLLER_ID and payload.intentionalRelease ~= true then
        -- Every RS radio hears the shared event. The gameplay callback decides
        -- whether this resource actually has live state to tear down, which also
        -- covers a jammed/suspended device whose shared owner was temporarily nil.
        Voice.StandDownLocal(src)
        notifyOwnershipLost(src, payload)
    end
end)

-- On pma-voice the provider owns PTT. On the Enhanced native backend RS Radio
-- owns it by muting/unmuting this member in the server-owned channel.
function Voice.SetTransmitState(src, active)
    if Voice.Provider() ~= 'cfx-native' then return true end
    if active == true and ownershipProtocolEnabled() and not Voice.IsOwner(src) then return false end
    local routeKey = nativePlayerRoute[src]
    local route = routeKey and nativeRoutes[routeKey]
    if not route or not route.members[src] then return false end
    local ok, result = pcall(SetPlayerMutedInVoiceChannel, route.id, src, active ~= true)
    return ok and result ~= false
end

function Voice.SetPlayerDeaf(src, deafened)
    if Voice.Provider() ~= 'cfx-native' then return true end
    if ownershipProtocolEnabled() and not Voice.IsOwner(src) then return false end
    local routeKey = nativePlayerRoute[src]
    local route = routeKey and nativeRoutes[routeKey]
    if not route or not route.members[src] then return false end
    local ok, result = pcall(SetPlayerDeafInVoiceChannel, route.id, src, deafened == true)
    return ok and result ~= false
end

function Voice.Capabilities()
    if Voice.Provider() == 'cfx-native' then
        return {
            serverOwnedChannels = true,
            serverOwnedPTT = true,
            deaf = true,
            -- Current documented Enhanced API does not expose a radio-only
            -- per-listener volume or per-listener mute primitive.
            volume = false,
            perPlayerMute = false,
            providerMicClicks = false
        }
    end
    if Voice.Provider() == 'pma-voice' then
        return {
            serverOwnedChannels = true,
            serverOwnedPTT = false,
            deaf = true,
            volume = true,
            perPlayerMute = true,
            providerMicClicks = true
        }
    end
    return {
        serverOwnedChannels = false,
        serverOwnedPTT = false,
        deaf = false,
        volume = false,
        perPlayerMute = false,
        providerMicClicks = false
    }
end

-- ---------------------------------------------------------------------------
-- Coexistence + pma state-bag observer
-- ---------------------------------------------------------------------------
local DEFAULT_SIBLING_RADIOS = {
    'rs-radio',
    'rs-zombieradio',
    'rs-zombieradio_lcd',
    'rs-radiogangs',
    'rs-radiopolice',
    'rs-radioems'
}
local pendingExternal = {}
local providerRestartUntil = 0
AddEventHandler('onResourceStart', function(resource)
    if resource == resourceName() and Voice.Provider() == 'pma-voice' then
        providerRestartUntil = GetGameTimer() + 2000
        selfWrites = {}
    end
end)

function Voice.DetectedSiblingRadios()
    local coexistence = Config.Coexistence or {}
    local radios = coexistence.KnownRadioResources
    if type(radios) ~= 'table' then radios = DEFAULT_SIBLING_RADIOS end
    local me, result = GetCurrentResourceName(), {}
    for _, name in ipairs(radios) do
        if type(name) == 'string' and name ~= '' and name ~= me then
            result[name] = GetResourceState(name)
        end
    end
    return result
end

function Voice.ConflictingRadio()
    if Voice.Provider() ~= 'pma-voice' then return nil end
    local coexistence = Config.Coexistence or {}
    if coexistence.Enabled == false then return nil end
    for name, state in pairs(Voice.DetectedSiblingRadios()) do
        if state == 'started' or state == 'starting' then return name end
    end
    return nil
end

function Voice.RegisterChannelCheck(channel, callback)
    if Voice.Provider() == 'cfx-native' then
        -- Only rs-radio server code can add players to native channels, and the
        -- gameplay layer validates access before calling SetPlayerChannel.
        return true
    end
    if GetResourceState(resourceName()) ~= 'started' then return false end
    return pcall(function()
        exports[resourceName()]:addChannelCheck(tonumber(channel), callback)
    end)
end

function Voice.GetDiagnostics(src)
    local provider = Voice.Provider()
    local nativeCount = 0
    for _ in pairs(nativeRoutes) do nativeCount = nativeCount + 1 end
    local ownership = src and Voice.GetOwnership(src) or nil
    return {
        provider = provider,
        configuredBackend = configuredBackend(),
        resource = resourceName(),
        state = provider == 'cfx-native' and 'server-native' or GetResourceState(resourceName()),
        radiosEnabled = provider == 'cfx-native' or GetConvarInt('voice_enableRadios', 1) == 1,
        nativeVoiceApi = Voice.NativeVoiceAvailable(),
        nativeChannelCount = nativeCount,
        capabilities = Voice.Capabilities(),
        conflictingRadio = Voice.ConflictingRadio(),
        siblingRadios = Voice.DetectedSiblingRadios(),
        ownershipProtocol = ownershipProtocolEnabled(),
        ownership = ownership,
        observerMode = provider == 'pma-voice' and (ownershipProtocolEnabled() and 'ownership-stand-down' or 'deferred-safe') or 'server-owned'
    }
end

local function queueExternal(callback, src, value)
    local pending = pendingExternal[src]
    if pending then
        pending.value = value
        return
    end

    pending = { value = value }
    pendingExternal[src] = pending
    SetTimeout(0, function()
        local entry = pendingExternal[src]
        if entry ~= pending then return end
        pendingExternal[src] = nil
        if not entry or not GetPlayerName(src) or Voice.Provider() ~= 'pma-voice' then return end
        if ownershipProtocolEnabled() then Voice.MarkExternalTakeover(src, entry.value)
        else callback(src, entry.value) end
    end)
end

function Voice.RegisterExternalChannelObserver(callback)
    if type(callback) ~= 'function' then return false end

    AddStateBagChangeHandler('radioChannel', nil, function(bagName, _, value)
        if Voice.Provider() ~= 'pma-voice' then return end
        local src = GetPlayerFromStateBagName(bagName)
        if not src or src == 0 then return end

        if Voice.ConsumeSelfWrite(src, value) then return end

        local observed = tonumber(value)
        if not observed or observed ~= observed or observed == math.huge or observed == -math.huge then return end
        observed = math.floor(observed)
        -- pma initializes its state to 0 before RS restores authorized sessions.
        if observed == 0 and GetGameTimer() < providerRestartUntil then return end
        if ownershipProtocolEnabled() then
            -- A provider change we did not write means another radio/controller
            -- won. Never write channel 0 and never "correct" it back. Stand down.
            queueExternal(callback, src, observed)
            return
        end

        -- Legacy opt-out path for servers that explicitly disable arbitration.
        -- Preserve the old conflict guard so disabling the protocol does not make
        -- two known sibling radios fight over the same pma state.
        if Voice.ConflictingRadio() then return end
        queueExternal(callback, src, observed)
    end)
    return true
end

AddEventHandler('playerDropped', function()
    local src = source
    selfWrites[src] = nil
    pendingExternal[src] = nil
    localGeneration[src] = nil
    authoritativeOwners[src] = nil
    if nativePlayerRoute[src] then releaseNativeMember(src) end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    for routeKey in pairs(nativeRoutes) do deleteNativeRoute(routeKey) end
    nativePlayerRoute = {}
end)
