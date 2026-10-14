RSRadioClientBridge = RSRadioClientBridge or {}
local Bridge = RSRadioClientBridge
local QBCore, ESX

local function resourceStarted(name)
    return GetResourceState(name) == 'started'
end

function Bridge.Init()
    local requested = string.lower(Config.Framework or 'auto')
    if requested == 'auto' then
        if resourceStarted('qbx_core') then requested = 'qbox'
        elseif resourceStarted('qb-core') then requested = 'qbcore'
        elseif resourceStarted('es_extended') then requested = 'esx'
        else requested = 'standalone' end
    end
    Bridge.Framework = requested
    QBCore, ESX = nil, nil
    if requested == 'qbcore' and resourceStarted('qb-core') then
        local ok, core = pcall(function() return exports['qb-core']:GetCoreObject() end)
        if ok then QBCore = core end
    elseif requested == 'esx' and resourceStarted('es_extended') then
        local ok, core = pcall(function() return exports['es_extended']:getSharedObject() end)
        if ok then ESX = core end
    end
end

function Bridge.Notify(message, kind)
    if resourceStarted('ox_lib') and lib and lib.notify then
        lib.notify({ description = message, type = kind or 'inform' })
    elseif Bridge.Framework == 'qbcore' and QBCore then
        QBCore.Functions.Notify(message, kind == 'error' and 'error' or 'primary')
    elseif Bridge.Framework == 'qbox' and resourceStarted('qbx_core') then
        exports.qbx_core:Notify(message, kind or 'inform')
    elseif Bridge.Framework == 'esx' and ESX then
        ESX.ShowNotification(message)
    else
        BeginTextCommandThefeedPost('STRING')
        AddTextComponentSubstringPlayerName(message)
        EndTextCommandThefeedPostTicker(false, false)
    end
end

Bridge.Init()

AddEventHandler('onResourceStop', function(resource)
    if resource == 'qb-core' then QBCore = nil end
    if resource == 'es_extended' then ESX = nil end
end)

AddEventHandler('onClientResourceStart', function(resource)
    if resource == 'qbx_core' or resource == 'qb-core' or resource == 'es_extended' then
        Bridge.Init()
    end
end)
