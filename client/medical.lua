RSRadioMedical = RSRadioMedical or {}
local Medical = RSRadioMedical
local externalStatus

local function numberOr(value, fallback)
    value = tonumber(value)
    return value or fallback
end

local function normalize(data)
    if type(data) ~= 'table' then return nil end
    local health = numberOr(data.percent or data.healthPercent or data.hp or data.health, 100)
    local dead = data.dead == true or data.isDead == true
    local unconscious = data.unconscious == true or data.laststand == true or data.inLaststand == true or data.downed == true
    local bleeding = data.bleeding == true or numberOr(data.bleed, 0) > 0
    local condition = data.condition
    if not condition then
        if dead then condition = 'DECEASED'
        elseif unconscious then condition = 'UNCONSCIOUS'
        elseif health >= Config.Medical.StableAbove then condition = 'STABLE'
        elseif health >= Config.Medical.InjuredAbove then condition = 'INJURED'
        elseif health >= Config.Medical.CriticalAbove then condition = 'CRITICAL'
        else condition = 'DECEASED' end
    end
    return {
        health = math.max(0, math.min(100, health)),
        armor = math.max(0, math.min(100, numberOr(data.armor, GetPedArmour(PlayerPedId())))),
        dead = dead,
        unconscious = unconscious,
        bleeding = bleeding,
        condition = tostring(condition):upper(),
        vitals = type(data.vitals) == 'table' and data.vitals or nil
    }
end

local function tryBodyHealth()
    if Config.Medical.Provider == 'native' then return nil end
    if GetResourceState(Config.Medical.BodyHealthResource) ~= 'started' then return nil end
    -- GetHealthStatus is the installed rs-bodyhealth client contract. Its health
    -- is raw GTA health; percent is the normalized value and downed means laststand.
    local candidates = { 'GetHealthStatus', 'GetRadioStatus', 'GetPlayerVitals', 'GetVitals' }
    for _, exportName in ipairs(candidates) do
        local ok, result = pcall(function()
            return exports[Config.Medical.BodyHealthResource][exportName]()
        end)
        if ok and type(result) == 'table' then
            if exportName == 'GetHealthStatus' then
                local vitalsOk, vitals = pcall(function() return exports[Config.Medical.BodyHealthResource]:GetHudVitals() end)
                if vitalsOk and type(vitals) == 'table' then
                    result.vitals = { hr = vitals.bpm or vitals.hr,
                        sys = vitals.systolic, dia = vitals.diastolic,
                        spo2 = vitals.spo2, rr = vitals.respiratoryRate or vitals.rr,
                        temp = vitals.temperature or vitals.temp }
                end
            end
            return normalize(result)
        end
    end
    return nil
end

local function nativeStatus()
    local ped = PlayerPedId()
    local rawHealth = GetEntityHealth(ped)
    local maxHealth = math.max(GetEntityMaxHealth(ped), 101)
    local health = math.floor(math.max(0, math.min(100, ((rawHealth - 100) / (maxHealth - 100)) * 100)))
    local state = LocalPlayer.state
    return normalize({
        health = health,
        armor = GetPedArmour(ped),
        dead = IsEntityDead(ped) or state.isDead == true,
        unconscious = state.inLaststand == true or state.laststand == true,
        bleeding = state.bleeding == true or tonumber(state.bleed or 0) > 0
    })
end

function Medical.GetStatus()
    return normalize(externalStatus) or tryBodyHealth() or nativeStatus()
end

function Medical.SetStatus(status)
    externalStatus = type(status) == 'table' and status or nil
end
exports('SetMedicalStatus', Medical.SetStatus)

RegisterNetEvent('rs-radio:client:setMedicalStatus', function(status)
    Medical.SetStatus(status)
end)
