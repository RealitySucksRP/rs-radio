RSRadioBridge = RSRadioBridge or {}
local Bridge = RSRadioBridge
local QBCore, ESX
local customInventoryProvider
Bridge.Inventory = Bridge.Inventory or 'unknown'

local function resourceStarted(name)
    return name and name ~= '' and GetResourceState(name) == 'started'
end

local function callConfiguredExport(exportName, ...)
    local cfg = Config.StandaloneInventory or {}
    if not cfg.Resource or not cfg[exportName] or not resourceStarted(cfg.Resource) then return nil end
    local args = { ... }
    local ok, result = pcall(function()
        return exports[cfg.Resource][cfg[exportName]](table.unpack(args))
    end)
    if ok then return result end
    return nil
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

    local inventory = string.lower(tostring(Config.Inventory or 'auto'))
    if inventory == 'auto' then
        if resourceStarted('ox_inventory') then inventory = 'ox_inventory'
        elseif requested == 'qbcore' or requested == 'esx' then inventory = 'framework'
        else inventory = 'standalone' end
    end
    Bridge.Inventory = inventory

    print(('[rs-radio] Framework bridge: %s | inventory: %s'):format(Bridge.Framework, Bridge.Inventory))
end

local function normalizeName(first, last, fallback)
    local full = (('%s %s'):format(first or '', last or '')):gsub('^%s+', ''):gsub('%s+$', '')
    return full ~= '' and full or fallback
end

function Bridge.GetPlayerData(src)
    local fallback = GetPlayerName(src) or ('Player %s'):format(src)
    if Bridge.Framework == 'qbcore' and QBCore then
        local player = QBCore.Functions.GetPlayer(src)
        if not player then return nil end
        local pd = player.PlayerData or {}
        return {
            name = normalizeName(pd.charinfo and pd.charinfo.firstname, pd.charinfo and pd.charinfo.lastname, fallback),
            citizenid = pd.citizenid,
            identifier = pd.citizenid,
            job = pd.job and pd.job.name or 'unemployed',
            onduty = pd.job and pd.job.onduty == true,
            gang = pd.gang and pd.gang.name or 'none',
            metadata = pd.metadata or {}
        }
    elseif Bridge.Framework == 'qbox' and resourceStarted('qbx_core') then
        local player = exports.qbx_core:GetPlayer(src)
        if not player then return nil end
        local pd = player.PlayerData or {}
        return {
            name = normalizeName(pd.charinfo and pd.charinfo.firstname, pd.charinfo and pd.charinfo.lastname, fallback),
            citizenid = pd.citizenid,
            identifier = pd.citizenid,
            job = pd.job and pd.job.name or 'unemployed',
            onduty = pd.job and pd.job.onduty == true,
            gang = pd.gang and pd.gang.name or 'none',
            metadata = pd.metadata or {}
        }
    elseif Bridge.Framework == 'esx' and ESX then
        local player = ESX.GetPlayerFromId(src)
        if not player then return nil end
        return {
            name = player.getName and player.getName() or fallback,
            citizenid = player.identifier,
            identifier = player.identifier,
            job = player.job and player.job.name or 'unemployed',
            onduty = true,
            gang = 'none',
            metadata = {}
        }
    end

    if Bridge.Framework ~= 'standalone' then return nil end
    local identifiers = GetPlayerIdentifiers(src)
    return {
        name = fallback,
        citizenid = identifiers[1] or tostring(src),
        identifier = identifiers[1] or tostring(src),
        job = 'unemployed',
        onduty = true,
        gang = 'none',
        metadata = {}
    }
end

function Bridge.GetIdentifier(src)
    local data = Bridge.GetPlayerData(src)
    return tostring((data and (data.identifier or data.citizenid)) or GetPlayerIdentifierByType(src, 'license') or src)
end

local function stableDeviceId(src, itemName)
    local seed = ('%s:%s'):format(Bridge.GetIdentifier(src), itemName or 'radio')
    return ('RSR-%08x-%s'):format(joaat(seed) & 0xffffffff, itemName or 'radio')
end

local deviceSequence = 0
local function newDeviceId(src, itemName)
    deviceSequence = deviceSequence + 1
    return ('%s-%x-%x-%x-%x'):format(stableDeviceId(src, itemName), os.time(), GetGameTimer(),
        deviceSequence, math.random(0, 0x7fffffff))
end

local function oxItemRegistered(itemName)
    if not resourceStarted('ox_inventory') then return false end
    local ok, item = pcall(function() return exports.ox_inventory:Items(itemName) end)
    return ok and type(item) == 'table'
end

local function oxFindItem(src, names)
    if not resourceStarted('ox_inventory') then return nil, 'not_running' end
    local anyRegistered = false
    local inventoryReady = false

    for _, itemName in ipairs(names or {}) do
        if oxItemRegistered(itemName) then anyRegistered = true end

        local slotOk, slotItem = pcall(function()
            return exports.ox_inventory:GetSlotWithItem(src, itemName, nil, false)
        end)
        if slotOk then
            inventoryReady = true
            if type(slotItem) == 'table' and (tonumber(slotItem.count) or 0) > 0 then
                slotItem.name = slotItem.name or itemName
                return slotItem
            end
        end

        local countOk, count = pcall(function()
            return exports.ox_inventory:GetItemCount(src, itemName, nil, false)
        end)
        if countOk then
            inventoryReady = true
            if (tonumber(count) or 0) > 0 then
                return { name = itemName, count = tonumber(count), slot = 0, metadata = {} }
            end
        end

        local searchOk, slots = pcall(function()
            return exports.ox_inventory:Search(src, 'slots', itemName)
        end)
        if searchOk then
            inventoryReady = true
            if type(slots) == 'table' then
                for _, item in pairs(slots) do
                    if item and (tonumber(item.count) or 0) > 0 then
                        item.name = item.name or itemName
                        return item
                    end
                end
            end
        end
    end

    if not anyRegistered then return nil, 'unregistered' end
    if not inventoryReady then return nil, 'not_ready' end
    return nil, 'missing'
end

local function qbFindItem(src, names)
    if not QBCore then return nil end
    local player = QBCore.Functions.GetPlayer(src)
    if not player then return nil end
    for _, itemName in ipairs(names or {}) do
        local item = player.Functions.GetItemByName(itemName)
        if item and (tonumber(item.amount or item.count) or 0) > 0 then return item, player end
    end
    return nil, player
end

local function standaloneQuery(src)
    if customInventoryProvider and type(customInventoryProvider.HasItem) == 'function' then
        local ok, result, device = pcall(customInventoryProvider.HasItem, src, Config.RadioItems)
        if ok then return result == true, device end
    end

    local result = callConfiguredExport('HasItemExport', src, Config.RadioItems)
    if result ~= nil then
        if type(result) == 'table' then return result.hasItem == true, result end
        return result == true, nil
    end

    local answered, allowed, device = false, false, nil
    TriggerEvent('rs-radio:server:hasItem', src, Config.RadioItems, function(value, deviceData)
        answered, allowed, device = true, value == true, deviceData
    end)
    if answered then return allowed, device end
    return false, nil
end

function Bridge.GetRadioDevice(src)
    if not Config.RequireRadioItem then
        local id = ('PERSONAL:%s'):format(Bridge.GetIdentifier(src))
        return { hasItem = true, id = id, item = 'personal', slot = 0, metadata = {} }
    end

    local metadataKey = Config.Persistence.DeviceMetadataKey or 'rsRadioId'

    if Bridge.Inventory == 'ox_inventory' then
        local oxItem, oxReason = oxFindItem(src, Config.RadioItems)
        if oxItem then
            local metadata = type(oxItem.metadata) == 'table' and oxItem.metadata or {}
            local deviceId = metadata[metadataKey]
            if not deviceId then
                if (tonumber(oxItem.slot) or 0) > 0 then
                    deviceId = newDeviceId(src, oxItem.name)
                    metadata[metadataKey] = deviceId
                    local wrote, result = pcall(function() return exports.ox_inventory:SetMetadata(src, oxItem.slot, metadata) end)
                    if not wrote or result == false then
                        return { hasItem = false, reason = 'inventory_not_ready', provider = 'ox_inventory' }
                    end
                else
                    deviceId = stableDeviceId(src, oxItem.name)
                end
            end
            return { hasItem = true, id = tostring(deviceId), item = oxItem.name, slot = oxItem.slot, metadata = metadata, provider = 'ox_inventory' }
        end
        if oxReason == 'unregistered' then return { hasItem = false, reason = 'radio_item_unregistered', provider = 'ox_inventory' } end
        if oxReason == 'not_ready' then return { hasItem = false, reason = 'inventory_not_ready', provider = 'ox_inventory' } end
        return { hasItem = false, reason = 'no_item', provider = 'ox_inventory' }
    end

    if Bridge.Inventory == 'framework' and Bridge.Framework == 'qbcore' and QBCore then
        local item, player = qbFindItem(src, Config.RadioItems)
        if not item then return { hasItem = false, reason = 'no_item', provider = 'framework' } end
        item.info = type(item.info) == 'table' and item.info or {}
        local deviceId = item.info[metadataKey]
        if not deviceId then
            deviceId = stableDeviceId(src, item.name)
            local inventoryItem = player and player.PlayerData.items and player.PlayerData.items[item.slot]
            if inventoryItem then
                deviceId = newDeviceId(src, item.name)
                inventoryItem.info = type(inventoryItem.info) == 'table' and inventoryItem.info or {}
                inventoryItem.info[metadataKey] = deviceId
            end
            item.info[metadataKey] = deviceId
            if player and player.Functions and player.Functions.SetPlayerData then
                pcall(function() player.Functions.SetPlayerData('items', player.PlayerData.items) end)
            end
        end
        return { hasItem = true, id = tostring(deviceId), item = item.name, slot = item.slot, metadata = item.info }
    end

    if Bridge.Inventory == 'framework' and Bridge.Framework == 'esx' and ESX then
        local player = ESX.GetPlayerFromId(src)
        if not player then return { hasItem = false, reason = 'inventory_not_ready', provider = 'framework' } end
        for _, itemName in ipairs(Config.RadioItems) do
            local item = player.getInventoryItem(itemName)
            if item and (item.count or 0) > 0 then
                return {
                    hasItem = true,
                    id = ('ESX:%s:%s'):format(Bridge.GetIdentifier(src), itemName),
                    item = itemName,
                    slot = 0,
                    metadata = {}
                }
            end
        end
        return { hasItem = false, reason = 'no_item', provider = 'framework' }
    end

    if Bridge.Inventory ~= 'standalone' then
        return { hasItem = false, reason = 'inventory_not_ready', provider = Bridge.Inventory }
    end
    local allowed, supplied = standaloneQuery(src)
    if not allowed then return { hasItem = false, reason = 'no_item', provider = 'standalone' } end
    supplied = type(supplied) == 'table' and supplied or {}
    return {
        hasItem = true,
        id = tostring(supplied.id or supplied.deviceId or ('CUSTOM:%s'):format(Bridge.GetIdentifier(src))),
        item = supplied.item or supplied.name or 'radio',
        slot = supplied.slot or 0,
        metadata = supplied.metadata or {}
    }
end

function Bridge.ValidateConfiguredItems()
    if Bridge.Inventory ~= 'ox_inventory' or not resourceStarted('ox_inventory') then return true end
    local found = false
    for _, itemName in ipairs(Config.RadioItems or {}) do
        if oxItemRegistered(itemName) then
            found = true
            break
        end
    end
    if not found then
        print(('^3[rs-radio] WARNING: none of Config.RadioItems are registered in ox_inventory (%s). '
            .. 'The resource and pma-voice can both be started, but players will still receive the no-radio message until the item is added.^7')
            :format(table.concat(Config.RadioItems or {}, ', ')))
    end
    return found
end

function Bridge.GetDiagnostics(src)
    local voiceDiag = RSRadioVoice and RSRadioVoice.GetDiagnostics and RSRadioVoice.GetDiagnostics(src) or {
        provider = 'pma-voice',
        resource = tostring(Config.VoiceResource or 'pma-voice'),
        state = GetResourceState(tostring(Config.VoiceResource or 'pma-voice')),
        radiosEnabled = GetConvarInt('voice_enableRadios', 1) == 1
    }
    local data = {
        framework = Bridge.Framework,
        inventory = Bridge.Inventory,
        voiceProvider = voiceDiag.provider,
        voice = voiceDiag.resource,
        voiceState = voiceDiag.state,
        voiceRadiosEnabled = voiceDiag.radiosEnabled,
        requireItem = Config.RequireRadioItem == true,
        accessMode = Config.RequireRadioItem == true and 'physical-item' or 'built-in',
        configuredItems = Config.RadioItems or {},
        oxInventoryState = GetResourceState('ox_inventory'),
        items = {}
    }
    if resourceStarted('ox_inventory') then
        for _, itemName in ipairs(Config.RadioItems or {}) do
            local registered = oxItemRegistered(itemName)
            local count = 0
            local ok, result = pcall(function() return exports.ox_inventory:GetItemCount(src, itemName, nil, false) end)
            if ok then count = tonumber(result) or 0 end
            data.items[#data.items + 1] = { name = itemName, registered = registered, count = count }
        end
    end
    data.device = Bridge.GetRadioDevice(src)
    return data
end
exports('GetDiagnostics', Bridge.GetDiagnostics)

function Bridge.HasItem(src)
    if not Config.RequireRadioItem then return true end
    return Bridge.GetRadioDevice(src).hasItem == true
end

function Bridge.HasNamedItem(src, names)
    names = names or {}
    if Bridge.Inventory == 'ox_inventory' then return oxFindItem(src, names) ~= nil end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'qbcore' and QBCore then return qbFindItem(src, names) ~= nil end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'esx' and ESX then
        local player = ESX.GetPlayerFromId(src)
        if not player then return false end
        for _, itemName in ipairs(names) do
            local item = player.getInventoryItem(itemName)
            if item and (item.count or 0) > 0 then return true end
        end
        return false
    end
    if Bridge.Inventory ~= 'standalone' then return false end
    if customInventoryProvider then
        local checker = customInventoryProvider.HasNamedItem or customInventoryProvider.HasItem
        if type(checker) == 'function' then
            local ok, result = pcall(checker, src, names)
            if ok then
                if type(result) == 'table' then return result.hasItem == true end
                return result == true
            end
        end
    end
    local result = callConfiguredExport('HasNamedItemExport', src, names)
    if result == nil then result = callConfiguredExport('HasItemExport', src, names) end
    if type(result) == 'table' then return result.hasItem == true end
    return result == true
end

function Bridge.RemoveItem(src, itemName, amount)
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    if Bridge.Inventory == 'ox_inventory' then
        local ok, result = pcall(function() return exports.ox_inventory:RemoveItem(src, itemName, amount) end)
        return ok and result == true
    end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'qbcore' and QBCore then
        local player = QBCore.Functions.GetPlayer(src)
        return player and player.Functions.RemoveItem(itemName, amount) == true
    end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'esx' and ESX then
        local player = ESX.GetPlayerFromId(src)
        if not player then return false end
        local item = player.getInventoryItem(itemName)
        if not item or (item.count or 0) < amount then return false end
        player.removeInventoryItem(itemName, amount)
        return true
    end
    if Bridge.Inventory ~= 'standalone' then return false end
    if customInventoryProvider and type(customInventoryProvider.RemoveItem) == 'function' then
        local ok, result = pcall(customInventoryProvider.RemoveItem, src, itemName, amount)
        return ok and result == true
    end
    local result = callConfiguredExport('RemoveItemExport', src, itemName, amount)
    return result == true
end

function Bridge.AddItem(src, itemName, amount, metadata)
    amount = math.max(1, math.floor(tonumber(amount) or 1))
    if Bridge.Inventory == 'ox_inventory' then
        local ok, result = pcall(function() return exports.ox_inventory:AddItem(src, itemName, amount, metadata) end)
        return ok and result == true
    end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'qbcore' and QBCore then
        local player = QBCore.Functions.GetPlayer(src)
        return player and player.Functions.AddItem(itemName, amount, false, metadata) == true
    end
    if Bridge.Inventory == 'framework' and Bridge.Framework == 'esx' and ESX then
        local player = ESX.GetPlayerFromId(src)
        if not player then return false end
        if player.canCarryItem and not player.canCarryItem(itemName, amount) then return false end
        local before = player.getInventoryItem(itemName)
        local count = before and tonumber(before.count) or 0
        player.addInventoryItem(itemName, amount)
        local after = player.getInventoryItem(itemName)
        return after and (tonumber(after.count) or 0) >= count + amount or false
    end
    if Bridge.Inventory ~= 'standalone' then return false end
    if customInventoryProvider and type(customInventoryProvider.AddItem) == 'function' then
        local ok, result = pcall(customInventoryProvider.AddItem, src, itemName, amount, metadata)
        return ok and result == true
    end
    local result = callConfiguredExport('AddItemExport', src, itemName, amount, metadata)
    return result == true
end

function Bridge.RemoveFirstAvailableItem(src, names, amount)
    for _, itemName in ipairs(names or {}) do
        if Bridge.HasNamedItem(src, { itemName }) and Bridge.RemoveItem(src, itemName, amount or 1) then
            return itemName
        end
    end
    return nil
end

function Bridge.IsOnDuty(src)
    local data = Bridge.GetPlayerData(src)
    return not data or data.onduty ~= false
end

function Bridge.RegisterUsableItems()
    -- Build the full set once so every backend registers exactly the same items.
    local registrations = {}

    -- Built-in radio mode does not require or register a framework inventory item.
    -- Physical-radio servers can opt back in with Config.RequireRadioItem = true.
    if Config.RequireRadioItem == true then
        for _, item in ipairs(Config.RadioItems or {}) do
            registrations[#registrations + 1] = { item = item, event = 'rs-radio:client:use' }
        end
    end

    if Config.Jammer.Enabled and Config.Jammer.Item then
        registrations[#registrations + 1] = { item = Config.Jammer.Item, event = 'rs-radio:client:placeJammer' }
    end

    for _, item in ipairs(Config.Battery.RechargeItems or {}) do
        registrations[#registrations + 1] = { item = item, event = 'rs-radio:client:recharge' }
    end

    -- Qbox must be checked before QBCore because qbx_core provides qb-core.
    if Bridge.Framework == 'qbox' and resourceStarted('qbx_core') then
        local registered = true
        for _, registration in ipairs(registrations) do
            local event = registration.event
            local ok = pcall(function()
                exports.qbx_core:CreateUseableItem(registration.item, function(src)
                    TriggerClientEvent(event, src)
                end)
            end)
            if not ok then registered = false end
        end
        if registered then return end
    end

    if Bridge.Framework == 'qbcore' and QBCore then
        for _, registration in ipairs(registrations) do
            local event = registration.event
            QBCore.Functions.CreateUseableItem(registration.item, function(src)
                TriggerClientEvent(event, src)
            end)
        end
    elseif Bridge.Framework == 'esx' and ESX then
        for _, registration in ipairs(registrations) do
            local event = registration.event
            ESX.RegisterUsableItem(registration.item, function(src)
                TriggerClientEvent(event, src)
            end)
        end
    end
end

function Bridge.SetCustomInventoryProvider(provider)
    customInventoryProvider = type(provider) == 'table' and provider or nil
    return customInventoryProvider ~= nil
end
exports('SetStandaloneInventoryProvider', Bridge.SetCustomInventoryProvider)

Bridge.Init()

AddEventHandler('onResourceStop', function(resource)
    if resource == 'qb-core' then QBCore = nil end
    if resource == 'es_extended' then ESX = nil end
end)

AddEventHandler('onResourceStart', function(resource)
    if resource ~= 'qbx_core' and resource ~= 'qb-core' and resource ~= 'es_extended' and resource ~= 'ox_inventory' then return end
    Bridge.Init()
    Bridge.RegisterUsableItems()
end)
