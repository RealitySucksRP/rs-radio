local Bridge = RSRadioClientBridge
local Medical = RSRadioMedical
local Voice = RSRadioVoiceClient

local radioOpen, joinedChannel, currentState = false, 0, nil
local radioTalking, jammerActive = false, false
local syncedJammers = {}
-- Timestamp of the most recent toggle command invocation, including rejected
-- key-repeat/spam input. A burst must go quiet before another focus transition
-- is allowed; otherwise a held/hammered F11 still toggles every debounce period.
local toggleLastInputAt = -100000
local openRequestPending, desiredRadioOpen = false, false
local openRequestSerial = 0
local radioFocusActive, radioKeepInputActive = false, false
local keyClosePending, keyCloseSerial = false, 0
local profile = {
    volume = Config.DefaultVolume,
    deafened = false,
    micClicks = Config.Profile.MicClicksDefault ~= false,
    allowMovement = Config.Profile.MovementDefault ~= false,
    overlayVisible = Config.UI.DefaultOverlayVisible == true,
    overlayMode = Config.UI.Overlay or 'default',
    overlayScale = Config.UI.DefaultOverlayScale or 100,
    overlayX = Config.UI.DefaultOverlayX or 78,
    overlayY = Config.UI.DefaultOverlayY or 8,
    radioPosition = Config.UI.Position or 'right',
    radioX = Config.UI.Position == 'left' and 1 or (Config.UI.DefaultRadioX or 62),
    radioY = Config.UI.DefaultRadioY or 15,
    radioScale = Config.UI.DefaultScale or 100,
    favorites = {},
    recent = {}
}

local function locale(key, ...)
    local message = Config.Locale[key] or key
    if select('#', ...) > 0 then return message:format(...) end
    return message
end

local function send(action, data)
    data = data or {}
    data.action = action
    SendNUIMessage(data)
end

local function applyVoiceSettings()
    -- pma volume/mic-click settings are global to the player's current radio.
    -- An inactive RS Radio must not overwrite the settings of a sibling device
    -- that currently owns pma-voice. Enhanced settings remain server-owned.
    if Voice.Provider() == 'pma-voice' and joinedChannel <= 0 then return true end
    return Voice.ApplySettings(profile.volume, profile.deafened == true, profile.micClicks == true)
end

local function mergeProfile(nextProfile)
    if type(nextProfile) ~= 'table' then return end
    profile.displayName = nextProfile.displayName
    for key, value in pairs(nextProfile) do profile[key] = value end
    applyVoiceSettings()
    send('profile', { profile = profile })
end

-- ---------------------------------------------------------------------------
-- Radio pose
--
-- The prop/animation lifecycle now lives in client/pose.lua, shared with the
-- other RS devices. This section is only the radio's opinion of it: which
-- clips, which prop, and when it should be up. Everything about loading,
-- attaching, interrupting and tearing down is the manager's problem.
--
-- The context policy is deliberately radio-specific. A handheld radio survives
-- walking and riding as a passenger, so those stay allowed; the old inline code
-- had the same intent via Config.Animation.DisableInVehicle, which is preserved
-- below and mapped onto the manager's Vehicle policy.
-- ---------------------------------------------------------------------------
local Pose = RSDevicePose

Pose.Configure({
    Enabled = Config.Animation.Enabled,
    Dict = Config.Animation.Dict,
    Enter = Config.Animation.Enter,
    Loop = Config.Animation.Chatter,
    EnterBlendMs = Config.Animation.EnterBlendTime,
    UseProp = Config.Animation.UseProp,
    PropModel = Config.Animation.PropModel,
    PropBone = Config.Animation.PropBone,
    PropOffset = Config.Animation.PropOffset,
    PropRotation = Config.Animation.PropRotation,
    Context = {
        Vehicle = Config.Animation.DisableInVehicle and 'block' or 'allow',
        -- A radio is still usable riding shotgun; only the driver rule and the
        -- physical-state rules come from the shared defaults.
        Driver = 'allow',
    },
})

-- The manager asks this before raising or holding the pose.
Pose.SetWanted(function()
    return radioOpen or radioTalking
end)

local function stopRadioAnimation()
    Pose.Close()
end

local function refreshRadioAnimation()
    Pose.Refresh()
end

if Config.Debug then
    RegisterCommand('radioalign', function(_, args)
        if #args == 6 then
            local values = {}
            for index = 1, 6 do
                values[index] = tonumber(args[index])
                if not values[index] then print('[rs-radio] Usage: /radioalign x y z rx ry rz') return end
            end
            Config.Animation.PropOffset = vector3(values[1], values[2], values[3])
            Config.Animation.PropRotation = vector3(values[4], values[5], values[6])
            local spec = Pose.Spec()
            spec.PropOffset, spec.PropRotation = Config.Animation.PropOffset, Config.Animation.PropRotation
            Pose.ReattachProp()
        end
        local offset, rotation = Config.Animation.PropOffset, Config.Animation.PropRotation
        print(('[rs-radio] left radio: offset %.4f %.4f %.4f | rotation %.4f %.4f %.4f'):format(
            offset.x, offset.y, offset.z, rotation.x, rotation.y, rotation.z
        ))
    end, false)
end

local function keepInputEnabled()
    return Config.UI.KeepGameInput ~= false and profile.allowMovement ~= false
end

local function setRadioFocus(enabled)
    enabled = enabled == true
    local keepInput = enabled and keepInputEnabled()

    -- NUI focus is process-wide. Only cross each focus boundary once so a
    -- repeated toggle cannot hammer CEF with duplicate focus transitions.
    -- On close, release KeepInput FIRST and keyboard focus LAST. This avoids
    -- leaving raw mapped input enabled during the focus-pop itself. On open the
    -- order is reversed: acquire focus first, then allow game input through.
    if not enabled then
        if radioKeepInputActive ~= keepInput then
            radioKeepInputActive = keepInput
            SetNuiFocusKeepInput(keepInput)
        end
        if radioFocusActive ~= enabled then
            radioFocusActive = enabled
            SetNuiFocus(enabled, enabled)
        end
        return
    end

    if radioFocusActive ~= enabled then
        radioFocusActive = enabled
        SetNuiFocus(enabled, enabled)
    end
    if radioKeepInputActive ~= keepInput then
        radioKeepInputActive = keepInput
        SetNuiFocusKeepInput(keepInput)
    end
end

local function openRadio()
    if radioOpen or openRequestPending then return false end
    if RSRadioUiGuard and RSRadioUiGuard.Blocked() then return false end

    desiredRadioOpen = true
    openRequestPending = true
    openRequestSerial = openRequestSerial + 1
    local requestSerial = openRequestSerial
    TriggerServerEvent('rs-radio:server:requestOpen', requestSerial)

    local timeoutMs = (Config.Keybind and tonumber(Config.Keybind.OpenRequestTimeoutMs)) or 3000
    SetTimeout(math.max(500, timeoutMs), function()
        if not openRequestPending or requestSerial ~= openRequestSerial then return end
        openRequestPending = false
        desiredRadioOpen = false
        if Config.Debug then print('[rs-radio] Radio open request timed out.') end
    end)
    return true
end
exports('useRadio', openRadio)
exports('OpenRadio', openRadio)

local function closeRadio()
    keyClosePending = false
    keyCloseSerial = keyCloseSerial + 1
    local hadOpenState = radioOpen or openRequestPending or desiredRadioOpen or radioFocusActive
    desiredRadioOpen = false
    openRequestPending = false
    openRequestSerial = openRequestSerial + 1
    radioOpen = false
    if not hadOpenState then return false end
    setRadioFocus(false)
    send('visible', { visible = false })
    if not radioTalking then stopRadioAnimation() end
    return true
end
exports('CloseRadio', closeRadio)

-- F11 is delivered to both CEF (because the NUI owns keyboard focus) and the
-- RegisterKeyMapping command (because KeepInput is enabled). Closing focus
-- directly from that command can tear CEF focus down while CEF is still inside
-- the same F11 key dispatch. ESC/X do not have that race because they close via
-- the asynchronous NUI callback. Route keybind-close through CEF too so every
-- user close path converges on the same callback. The delayed fallback is only
-- for a dead/unresponsive NUI and runs well after the original key event.
local function requestKeyClose()
    if not radioOpen or keyClosePending then return false end

    keyClosePending = true
    keyCloseSerial = keyCloseSerial + 1
    local requestSerial = keyCloseSerial
    send('requestClose', { source = 'keybind' })

    SetTimeout(750, function()
        if not keyClosePending or requestSerial ~= keyCloseSerial or not radioOpen then return end
        keyClosePending = false
        closeRadio()
    end)

    return true
end

local function toggleRadio()
    local now = GetGameTimer()
    local debounce = (Config.Keybind and tonumber(Config.Keybind.ToggleDebounce)) or 600
    local previousInputAt = toggleLastInputAt
    -- Record EVERY invocation, not just an accepted toggle. This turns the
    -- debounce into a quiet-period gate: continuous key repeat can no longer
    -- reopen/close CEF at one transition per debounce interval.
    toggleLastInputAt = now
    if now - previousInputAt < debounce then return end
    -- An open is a server-authoritative round trip. Do not queue another open
    -- or a contradictory close while its response is still in flight.
    if openRequestPending then return end

    if radioOpen then requestKeyClose() else openRadio() end
end
exports('ToggleRadio', toggleRadio)

local function availableChannels()
    local channels = currentState and currentState.channels or {}
    local result = {}
    for _, channel in ipairs(channels) do
        if not channel.locked then result[#result + 1] = channel.id end
    end
    table.sort(result)
    return result
end

local function stepChannel(direction)
    if joinedChannel <= 0 then return end
    local channels = availableChannels()
    if #channels == 0 then return end
    local index = 1
    for i, channel in ipairs(channels) do if channel == joinedChannel then index = i break end end
    index = ((index - 1 + direction) % #channels) + 1
    TriggerServerEvent('rs-radio:server:join', channels[index])
end
exports('JoinRadio', function(channel) TriggerServerEvent('rs-radio:server:join', tonumber(channel)) end)
exports('LeaveRadio', function() TriggerServerEvent('rs-radio:server:leave') end)

RegisterNetEvent('rs-radio:client:use', openRadio)
RegisterNetEvent('rs-radio:client:recharge', function() TriggerServerEvent('rs-radio:server:recharge') end)

if Config.Keybind and Config.Keybind.Enabled then
    RegisterCommand(Config.Keybind.Command, toggleRadio, false)
    RegisterKeyMapping(Config.Keybind.Command, Config.Keybind.Description or 'Open / close RS Radio', 'keyboard', Config.Keybind.Default or 'F11')
    local nextCfg, previousCfg = Config.Keybind.NextChannel or {}, Config.Keybind.PreviousChannel or {}
    if nextCfg.Enabled then
        RegisterCommand(nextCfg.Command, function() stepChannel(1) end, false)
        RegisterKeyMapping(nextCfg.Command, nextCfg.Description or 'Next available radio channel', 'keyboard', nextCfg.Default or 'PERIOD')
    end
    if previousCfg.Enabled then
        RegisterCommand(previousCfg.Command, function() stepChannel(-1) end, false)
        RegisterKeyMapping(previousCfg.Command, previousCfg.Description or 'Previous available radio channel', 'keyboard', previousCfg.Default or 'COMMA')
    end
end

RegisterNetEvent('rs-radio:client:state', function(state)
    state = type(state) == 'table' and state or {}
    if state.open and (not openRequestPending or state.requestId ~= openRequestSerial) then return end
    if state.open and RSRadioUiGuard and RSRadioUiGuard.Blocked() then
        closeRadio()
        return
    end
    if state.voice then Voice.SetServerProvider(state.voice.provider) end
    currentState = state
    joinedChannel = tonumber(state.channel) or 0
    jammerActive = state.jammed == true
    mergeProfile(state.profile)
    applyVoiceSettings()
    if state.open then
        openRequestPending = false
        openRequestSerial = openRequestSerial + 1

        -- A CloseRadio export may cancel an in-flight request. Never let its
        -- late server response reopen the NUI or reclaim focus.
        if not desiredRadioOpen and not radioOpen then
            setRadioFocus(false)
            send('state', state)
            send('visible', { visible = false })
            return
        end

        desiredRadioOpen = true
        radioOpen = true
        keyClosePending = false
        keyCloseSerial = keyCloseSerial + 1
        toggleLastInputAt = GetGameTimer()
        setRadioFocus(true)
        send('state', state)
        send('visible', { visible = true })
        if Config.Jammer.Enabled then
            TriggerServerEvent('rs-radio:server:requestJammers')
        end
        refreshRadioAnimation()
    else
        send('state', state)
    end
end)

RegisterNetEvent('rs-radio:client:joined', function(data)
    data = type(data) == 'table' and data or {}
    if data.voice then Voice.SetServerProvider(data.voice.provider) end
    joinedChannel = tonumber(data.channel) or 0
    jammerActive = data.jammed == true
    if currentState then
        currentState.channel, currentState.channelLabel = joinedChannel, data.label
        currentState.powered, currentState.battery, currentState.jammed = true, data.battery, jammerActive
        if data.channels then currentState.channels = data.channels end
    end
    if data.profile then mergeProfile(data.profile) end
    if Voice.Provider() == 'cfx-native' then
        radioTalking = data.talking == true
        send('localTalking', { talking = radioTalking })
        refreshRadioAnimation()
    end
    if data.volume ~= nil then profile.volume = data.volume end
    applyVoiceSettings()
    send('joined', data)
    Bridge.Notify(locale('joined', data.label or tostring(joinedChannel)), 'success')
end)

RegisterNetEvent('rs-radio:client:left', function(reason)
    joinedChannel, jammerActive = 0, false
    if radioTalking then
        radioTalking = false
        send('localTalking', { talking = false })
        refreshRadioAnimation()
    end
    if currentState then currentState.channel, currentState.powered, currentState.jammed = 0, false, false end
    send('left', { reason = reason })
    if reason == 'external_takeover' or reason == 'item_missing' or reason == 'player_unloaded' then closeRadio() end
    if reason == 'dead_battery' then Bridge.Notify(locale('dead_battery'), 'error')
    elseif reason == 'item_missing' then Bridge.Notify(locale('no_item'), 'error')
    elseif reason ~= 'voice_sync' then Bridge.Notify(locale('left'), 'inform') end
end)

RegisterNetEvent('rs-radio:client:denied', function(reason, requestId)
    if requestId and requestId ~= openRequestSerial then return end
    if openRequestPending and requestId == openRequestSerial then
        openRequestPending = false
        desiredRadioOpen = false
        openRequestSerial = openRequestSerial + 1
        radioOpen = false
        setRadioFocus(false)
        send('visible', { visible = false })
        if not radioTalking then stopRadioAnimation() end
    end
    Bridge.Notify(locale(reason), 'error')
    send('denied', { reason = reason })
end)

RegisterNetEvent('rs-radio:client:roster', function(roster)
    if currentState then currentState.roster = roster or {} end
    send('roster', { roster = roster or {} })
end)

RegisterNetEvent('rs-radio:client:talking', function(memberId, active)
    send('memberTalking', { id = memberId, talking = active == true })
end)

RegisterNetEvent('rs-radio:client:distressBoard', function(board)
    if currentState then currentState.distressBoard = board or {} end
    send('distressBoard', { distressBoard = board or {} })
end)

RegisterNetEvent('rs-radio:client:distressState', function(data)
    data = data or {}
    send('distressState', { active = data.active == true, seconds = data.seconds })
    if data.active then Bridge.Notify(locale('distress_sent'), 'error')
    elseif data.cancelled then Bridge.Notify(locale('distress_cancelled'), 'inform')
    elseif data.expired then Bridge.Notify(locale('distress_expired'), 'inform') end
end)

RegisterNetEvent('rs-radio:client:distressAlert', function(data)
    data = data or {}
    send('distressAlert', data)
    Bridge.Notify(locale('distress_alert', tostring(data.callsign or 'UNKNOWN'), tostring(data.street or 'UNKNOWN POSITION')), 'error')
end)

-- Incoming communication event, already rendered server-side into radio shape.
-- The client's only jobs are resolving the street natively and deciding how
-- loudly to announce it.
RegisterNetEvent('rs-radio:client:traffic', function(data)
    if type(data) ~= 'table' then return end

    local where
    if data.location and data.location.x then
        local s1 = GetStreetNameAtCoord(data.location.x, data.location.y, data.location.z or 0.0)
        if s1 and s1 ~= 0 then where = GetStreetNameFromHashKey(s1) end
    end

    send('traffic', {
        id = data.id,
        priority = data.priority,
        banner = data.banner,
        code = data.code,
        callsign = data.callsign,
        title = data.title,
        body = data.body,
        street = where,
        label = data.label,
        at = data.at
    })

    -- Only emergency traffic interrupts. A radio that toasts every routine
    -- dispatch trains the player to ignore the one that matters.
    if data.priority == 'emergency' then
        local line = data.banner or 'EMERGENCY TRAFFIC'
        if data.callsign then line = ('%s | %s'):format(line, data.callsign) end
        if data.title then line = ('%s | %s'):format(line, data.title) end
        if where then line = ('%s | %s'):format(line, where) end
        Bridge.Notify(line, 'error')
    end
end)

RegisterNetEvent('rs-radio:client:battery', function(level, recharged)
    if currentState then currentState.battery = level end
    send('battery', { battery = level })
    if recharged then Bridge.Notify(locale('recharged', level), 'success') end
end)

RegisterNetEvent('rs-radio:client:volume', function(level, deafened)
    profile.volume, profile.deafened = level, deafened == true
    applyVoiceSettings()
    send('volume', { volume = level, deafened = profile.deafened })
end)

RegisterNetEvent('rs-radio:client:profile', function(nextProfile, channels)
    mergeProfile(nextProfile)
    if currentState and channels then currentState.channels = channels end
    send('profile', { profile = profile, channels = channels })
    if radioOpen then setRadioFocus(true) end
end)

RegisterNetEvent('rs-radio:client:diagnostics', function(data)
    data = type(data) == 'table' and data or {}
    local parts = {
        ('Framework: %s'):format(tostring(data.framework or 'unknown')),
        ('Inventory: %s'):format(tostring(data.inventory or 'unknown')),
        ('Voice: %s [%s] radios=%s'):format(tostring(data.voice or 'unknown'), tostring(data.voiceState or 'unknown'), tostring(data.voiceRadiosEnabled)),
        ('Radio mode: %s'):format(tostring(data.accessMode or (data.requireItem and 'physical-item' or 'built-in')))
    }
    for _, item in ipairs(data.items or {}) do
        parts[#parts + 1] = ('%s registered=%s count=%s'):format(tostring(item.name), tostring(item.registered), tostring(item.count))
    end
    local device = data.device or {}
    parts[#parts + 1] = ('Detected radio: %s (%s)'):format(tostring(device.hasItem == true), tostring(device.reason or device.item or 'ok'))
    local radio = data.radio or {}
    parts[#parts + 1] = ('Channel: %s %s | Callsign: %s | Battery: %s%% | Jammed: %s')
        :format(tostring(radio.channel or 0), tostring(radio.label or 'OFFLINE'), tostring(radio.callsign or 'UNKNOWN'), tostring(radio.battery or '?'), tostring(radio.jammed == true))
    Bridge.Notify(table.concat(parts, ' | '), device.hasItem == true and 'success' or 'error')
end)

local nearestJammerSignature = nil

local function refreshNearestJammer(force)
    if not Config.Jammer.Enabled then
        if force or nearestJammerSignature ~= 'disabled' then
            nearestJammerSignature = 'disabled'
            send('jammerStatus', { jammer = false })
        end
        return
    end
    local ped = PlayerPedId()
    if not ped or ped <= 0 then return end
    local coords = GetEntityCoords(ped)
    local nearest, nearestDistance
    for _, jammer in ipairs(syncedJammers or {}) do
        local point = jammer.coords or {}
        local dx = coords.x - (tonumber(point.x) or 0.0)
        local dy = coords.y - (tonumber(point.y) or 0.0)
        local dz = coords.z - (tonumber(point.z) or 0.0)
        local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
        if not nearestDistance or distance < nearestDistance then
            nearest, nearestDistance = jammer, distance
        end
    end
    local within = nearest and nearestDistance <= (Config.Jammer.InteractionDistance or 4.0)
    local jammer = within and nearest or false
    local signature = 'none'
    if jammer then
        local allowed = {}
        for _, frequency in ipairs(jammer.allowedChannels or {}) do allowed[#allowed + 1] = tostring(frequency) end
        table.sort(allowed)
        signature = table.concat({
            tostring(jammer.id or ''),
            jammer.enabled and '1' or '0',
            tostring(jammer.range or ''),
            table.concat(allowed, ',')
        }, '|')
    end
    if force or signature ~= nearestJammerSignature then
        nearestJammerSignature = signature
        send('jammerStatus', { jammer = jammer, distance = nearestDistance })
    end
end

RegisterNetEvent('rs-radio:client:jammer', function(data)
    data = data or {}
    local wasJammed = jammerActive
    jammerActive = data.jammed == true
    if currentState then currentState.jammed = jammerActive end
    if jammerActive and radioTalking and Voice.Provider() == 'cfx-native' then
        radioTalking = false
        send('localTalking', { talking = false })
        refreshRadioAnimation()
    end
    send('jammer', { jammed = jammerActive, id = data.id, range = data.range })
    if jammerActive and not wasJammed then Bridge.Notify(locale('jammed'), 'error')
    elseif not jammerActive and wasJammed then Bridge.Notify(locale('jammer_clear'), 'success') end
end)

RegisterNetEvent('rs-radio:client:jammers', function(jammers)
    syncedJammers = type(jammers) == 'table' and jammers or {}
    send('jammers', { jammers = syncedJammers })
    refreshNearestJammer(true)
end)

RegisterNetEvent('rs-radio:client:jammerAction', function(action)
    if action == 'placed' then Bridge.Notify(locale('jammer_placed'), 'success')
    elseif action == 'removed' then Bridge.Notify(locale('jammer_removed'), 'success') end
end)

RegisterNetEvent('rs-radio:client:jammerStatus', function(jammer, distance)
    send('jammerStatus', { jammer = jammer or false, distance = distance })
    if not jammer then Bridge.Notify(locale('jammer_not_found'), 'error') return end
    Bridge.Notify(('Jammer %s | %s | %.0fm range | %.1fm away'):format(jammer.id, jammer.enabled and 'ON' or 'OFF', jammer.range, distance or 0), 'inform')
end)

RegisterNetEvent('rs-radio:client:profileReset', function()
    Bridge.Notify(locale('profile_reset'), 'success')
end)

local function placeJammer(range)
    local ped = PlayerPedId()
    local coords, heading = GetEntityCoords(ped), GetEntityHeading(ped)
    local radians = math.rad(heading)
    local x = coords.x - math.sin(radians) * 1.35
    local y = coords.y + math.cos(radians) * 1.35
    local z = coords.z - 1.0
    local foundGround, groundZ = GetGroundZFor_3dCoord(x, y, coords.z + 2.0, false)
    if foundGround then z = groundZ end
    TriggerServerEvent('rs-radio:server:placeJammer', {
        coords = { x = x, y = y, z = z, w = heading },
        range = tonumber(range) or Config.Jammer.Range.Default,
        allowedChannels = {}
    })
end
RegisterNetEvent('rs-radio:client:placeJammer', placeJammer)
exports('placeJammer', placeJammer)
exports('RechargeRadio', function() TriggerServerEvent('rs-radio:server:recharge') end)

Voice.RegisterTalkingHandlers(function(active)
    radioTalking = active == true and not jammerActive and joinedChannel > 0
    TriggerServerEvent('rs-radio:server:talking', radioTalking)
    send('localTalking', { talking = radioTalking })
    refreshRadioAnimation()
end, function(source, active)
    if joinedChannel <= 0 then return end
    send('memberTalking', { id = tonumber(source), talking = active == true })
end)

-- GTAV Enhanced native voice has no client-side channel join primitive. The
-- only client request is PTT intent; the server validates the active RS session
-- and owns the actual mute state in the Cfx voice channel.
local nativePTTCommand = tostring((Config.Voice or {}).NativePTTCommand or '+rs_radio_talk')
if nativePTTCommand:sub(1, 1) ~= '+' then nativePTTCommand = '+' .. nativePTTCommand end
local nativePTTReleaseCommand = '-' .. nativePTTCommand:sub(2)

local function setNativePTT(active)
    if Voice.Provider() ~= 'cfx-native' then return end
    active = active == true
    if active and (joinedChannel <= 0 or jammerActive) then return end
    if radioTalking == active then return end
    radioTalking = active
    TriggerServerEvent('rs-radio:server:talking', active)
    send('localTalking', { talking = active })
    if profile.micClicks then send('nativePttClick', { active = active }) end
    refreshRadioAnimation()
end

RegisterCommand(nativePTTCommand, function() setNativePTT(true) end, false)
RegisterCommand(nativePTTReleaseCommand, function() setNativePTT(false) end, false)
RegisterKeyMapping(nativePTTCommand, 'Talk over RS Radio', 'keyboard', tostring((Config.Voice or {}).NativePTTKey or 'LMENU'))

RegisterNetEvent('rs-radio:client:talkingTimeout', function()
    if Voice.Provider() ~= 'cfx-native' then return end
    radioTalking = false
    send('localTalking', { talking = false })
    refreshRadioAnimation()
end)

CreateThread(function()
    while not Voice.IsReady() do Wait(500) end
    Voice.SetControllerAnimationDisabled(true)
    applyVoiceSettings()
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= Voice.Resource() then return end
    SetTimeout(1000, function()
        Voice.SetControllerAnimationDisabled(true)
        applyVoiceSettings()
    end)
end)

CreateThread(function()
    while true do
        if radioOpen and keepInputEnabled() then
            Wait(0)
            SetNuiFocusKeepInput(true)
            DisableControlAction(0, 24, true)
            DisableControlAction(0, 25, true)
            DisableControlAction(0, 37, true)
            DisableControlAction(0, 44, true)
            DisableControlAction(0, 140, true)
            DisableControlAction(0, 141, true)
            DisableControlAction(0, 142, true)
            DisableControlAction(0, 257, true)
        else
            Wait(250)
        end
    end
end)

CreateThread(function()
    while true do
        if radioOpen or radioTalking then
            Wait(Config.Animation.WatchdogInterval or 350)
        else
            Wait(500)
        end
        -- Ticks in both states on purpose. When the radio is up this keeps the
        -- clip alive; when it is down this is how the pose comes off even if a
        -- future call site forgets to close it. Refresh() early-returns once the
        -- pose is closed and the prop is gone, so the idle tick costs nothing.
        refreshRadioAnimation()
    end
end)

local function currentLocationPayload()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    local streetHash, crossingHash = GetStreetNameAtCoord(coords.x, coords.y, coords.z)
    local street = GetStreetNameFromHashKey(streetHash)
    if crossingHash and crossingHash ~= 0 then
        local crossing = GetStreetNameFromHashKey(crossingHash)
        if crossing and crossing ~= '' then street = street .. ' / ' .. crossing end
    end
    local zone = GetLabelText(GetNameOfZone(coords.x, coords.y, coords.z))
    local status = Medical.GetStatus()
    return {
        coords = { x = coords.x, y = coords.y, z = coords.z },
        street = street ~= '' and street or 'WILDERNESS',
        zone = zone ~= 'NULL' and zone or '',
        condition = status.condition,
        health = status.health,
        armor = status.armor,
        dead = status.dead,
        unconscious = status.unconscious,
        bleeding = status.bleeding,
        vitals = status.vitals,
        signal = jammerActive and 0 or 100
    }
end

local RPC = RSRadioRPC

RPC.Register('close', function()
    closeRadio()
    return { ok = true }
end)

RPC.Register('join', function(data)
    local channel = math.floor(tonumber(data.channel) or 0)
    if channel <= 0 or channel > Config.MaxFrequency then return { ok = false, error = 'invalid_channel' } end
    TriggerServerEvent('rs-radio:server:join', channel)
    return { ok = true, queued = true }
end)

RPC.Register('leave', function()
    TriggerServerEvent('rs-radio:server:leave')
    return { ok = true, queued = true }
end)

RPC.Register('volume', function(data)
    if Voice.Provider() == 'cfx-native' then
        return { ok = false, error = 'unsupported_by_native_voice', volume = profile.volume }
    end
    local volume = math.floor(math.max(0, math.min(100, tonumber(data.volume) or Config.DefaultVolume)))
    profile.volume = volume
    applyVoiceSettings()
    TriggerServerEvent('rs-radio:server:setVolume', volume)
    return { ok = true, volume = volume, queued = true }
end)

RPC.Register('distress', function()
    TriggerServerEvent('rs-radio:server:distress', currentLocationPayload())
    return { ok = true, queued = true }
end)

RPC.Register('profile', function(data)
    data = type(data) == 'table' and data or {}
    for key, value in pairs(data) do profile[key] = value end
    applyVoiceSettings()
    if radioOpen then setRadioFocus(true) end
    TriggerServerEvent('rs-radio:server:updateProfile', data)
    return { ok = true, queued = true }
end)

RPC.Register('favorite', function(data)
    local channel = math.floor(tonumber(data.channel) or 0)
    if channel <= 0 or channel > Config.MaxFrequency then return { ok = false, error = 'invalid_channel' } end
    TriggerServerEvent('rs-radio:server:updateProfile', { favoriteChannel = channel, favorite = data.favorite == true })
    return { ok = true, queued = true }
end)

RPC.Register('toggleMutePlayer', function(data)
    if Voice.Provider() == 'cfx-native' then return { ok = false, error = 'unsupported_by_native_voice', muted = {} } end
    local serverId = tonumber(data.id)
    if not serverId or serverId == GetPlayerServerId(PlayerId()) then return { ok = false, error = 'invalid_player' } end
    local ok = Voice.ToggleMutePlayer(serverId)
    local muted = Voice.GetMutedPlayers()
    return { ok = ok, muted = muted }
end)

RPC.Register('getMutedPlayers', function()
    local muted = Voice.GetMutedPlayers()
    return { ok = true, muted = muted }
end)

RPC.Register('jammerAction', function(data)
    TriggerServerEvent('rs-radio:server:jammerAction', tostring(data.action or 'status'), tonumber(data.value))
    return { ok = true, queued = true }
end)

RPC.Register('placeJammer', function(data)
    placeJammer(tonumber(data.range) or Config.Jammer.Range.Default)
    return { ok = true, queued = true }
end)

RPC.Register('requestJammerStatus', function()
    TriggerServerEvent('rs-radio:server:requestJammers')
    refreshNearestJammer()
    return { ok = true, queued = true }
end)

RPC.Register('resetProfile', function()
    TriggerServerEvent('rs-radio:server:resetProfile')
    return { ok = true, queued = true }
end)

RPC.Register('waypoint', function(data)
    local coords = data.coords
    if coords and tonumber(coords.x) and tonumber(coords.y) and Config.Distress.WaypointEnabled then
        SetNewWaypoint(tonumber(coords.x) + 0.0, tonumber(coords.y) + 0.0)
        return { ok = true }
    end
    return { ok = false, error = 'invalid_waypoint' }
end)

if Config.EnableTestCommand then RegisterCommand(Config.TestCommand, openRadio, false) end

CreateThread(function()
    while true do
        Wait(1000)
        if radioOpen and Config.Jammer.Enabled then
            -- Refresh the bucket-filtered list after an instance change.
            TriggerServerEvent('rs-radio:server:requestJammers')
            refreshNearestJammer()
        end
    end
end)

CreateThread(function()
    while true do
        Wait(Config.Telemetry.Interval)
        if joinedChannel > 0 and Config.Telemetry.Enabled then
            local channelCfg = Config.Channels[joinedChannel]
            if channelCfg and channelCfg.telemetry then
                TriggerServerEvent('rs-radio:server:telemetry', currentLocationPayload())
            end
        end
    end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource ~= Voice.Resource() then return end
    SetTimeout(750, function()
        -- Restore local volume/click settings only. The server owns channel
        -- membership and reasserts it in server/main.lua after pma-voice starts.
        -- Avoiding a client setRadioChannel write is especially important on
        -- GTAV Enhanced's Mumble compatibility layer.
        applyVoiceSettings()
    end)
end)

local function clearClientRuntime(reason)
    desiredRadioOpen = false
    openRequestPending = false
    openRequestSerial = openRequestSerial + 1
    keyClosePending = false
    keyCloseSerial = keyCloseSerial + 1
    radioTalking, joinedChannel, jammerActive = false, 0, false
    currentState, syncedJammers = nil, {}
    closeRadio()
    stopRadioAnimation()
    send('reset', {})
end

RegisterNetEvent('rs-radio:client:forceClose', clearClientRuntime)
RegisterNetEvent('QBCore:Client:OnPlayerUnload', clearClientRuntime)
RegisterNetEvent('qbx_core:client:playerLoggedOut', clearClientRuntime)
RegisterNetEvent('esx:onPlayerLogout', clearClientRuntime)

AddEventHandler('onResourceStop', function(resource)
    if resource ~= GetCurrentResourceName() then return end
    desiredRadioOpen = false
    openRequestPending = false
    openRequestSerial = openRequestSerial + 1
    radioOpen = false
    setRadioFocus(false)
    send('visible', { visible = false })
    stopRadioAnimation()
    Voice.SetControllerAnimationDisabled(false)
end)
