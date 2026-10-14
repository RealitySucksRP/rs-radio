RSRadioVoiceClient = RSRadioVoiceClient or {}
local Voice = RSRadioVoiceClient

local serverProvider = nil

local function resourceName()
    local voice = type(Config.Voice) == 'table' and Config.Voice or {}
    return tostring(voice.Resource or Config.VoiceResource or 'pma-voice')
end

function Voice.SetServerProvider(provider)
    provider = tostring(provider or '')
    if provider == 'cfx-native' or provider == 'pma-voice' or provider == 'none' then
        serverProvider = provider
        if provider == 'pma-voice' and GetResourceState(resourceName()) == 'started' then
            pcall(function() exports[resourceName()]:setDisableRadioAnim(true) end)
        end
    end
end

function Voice.Provider()
    -- Backend choice is made by the server. The client deliberately does not
    -- guess from a running pma resource because Enhanced servers may have pma
    -- installed for unrelated compatibility while RS Radio uses native voice.
    return serverProvider or 'none'
end

function Voice.Resource()
    return resourceName()
end

function Voice.IsReady()
    local provider = Voice.Provider()
    if provider == 'cfx-native' then return true end
    if provider == 'pma-voice' then return GetResourceState(resourceName()) == 'started' end
    return false
end

function Voice.ApplySettings(volume, deafened, micClicks)
    local provider = Voice.Provider()
    if provider == 'cfx-native' then
        -- Enhanced channel deaf state is server-owned and synchronized by the
        -- profile event. There is currently no documented radio-only volume or
        -- per-listener mute primitive in the new API, so do not fake one here.
        return true
    end
    if provider ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return false end

    local desired = deafened and 0 or math.max(0, math.min(100, tonumber(volume) or Config.DefaultVolume))
    pcall(function() exports[resourceName()]:setVoiceProperty('radioEnabled', true) end)
    pcall(function() exports[resourceName()]:setRadioVolume(desired) end)
    pcall(function() exports[resourceName()]:setVoiceProperty('micClicks', micClicks == true) end)
    return true
end

function Voice.SetControllerAnimationDisabled(disabled)
    if Voice.Provider() == 'cfx-native' then return true end
    if Voice.Provider() ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return false end
    return pcall(function() exports[resourceName()]:setDisableRadioAnim(disabled == true) end)
end

-- Server owns membership. This remains only for backwards-compatible exports;
-- native Enhanced mode intentionally has no client-side join primitive.
function Voice.RestoreChannel(channel)
    if Voice.Provider() ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return false end
    return pcall(function() exports[resourceName()]:setRadioChannel(tonumber(channel) or 0) end)
end

function Voice.ToggleMutePlayer(serverId)
    if Voice.Provider() ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return false end
    return pcall(function() exports[resourceName()]:toggleMutePlayer(serverId) end)
end

function Voice.GetMutedPlayers()
    if Voice.Provider() ~= 'pma-voice' or GetResourceState(resourceName()) ~= 'started' then return {} end
    local muted = {}
    pcall(function() muted = exports[resourceName()]:getMutedPlayers() or {} end)
    return muted
end

function Voice.RegisterTalkingHandlers(onLocalTalking, onRemoteTalking)
    if type(onLocalTalking) == 'function' then
        RegisterNetEvent('pma-voice:radioActive', function(active)
            if Voice.Provider() ~= 'pma-voice' then return end
            onLocalTalking(active == true)
        end)
    end

    if type(onRemoteTalking) == 'function' then
        RegisterNetEvent('pma-voice:setTalkingOnRadio', function(source, active)
            if Voice.Provider() ~= 'pma-voice' then return end
            onRemoteTalking(tonumber(source), active == true)
        end)
    end
end
