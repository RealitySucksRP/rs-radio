-- RS Device Pose Manager
--
-- Step 4 of the communication-systems build order: one prop/animation
-- lifecycle that every RS device shares. This file is device-agnostic -- it
-- knows nothing about tablets. It is handed a spec (dict, clips, prop, bone,
-- offsets, context policy) and owns the state machine from there.
--
-- This copy includes cancellation and ped-identity guards. Other RS devices
-- must adopt compatible lifecycle fixes separately; no runtime dependency.
--
-- WHY A STATE MACHINE AND NOT A BOOLEAN
-- ------------------------------------
-- The old inline version tracked `animationRunning` plus a token. That is
-- enough to stop two animations racing, but not enough to answer "is the prop
-- attached yet" during the two awaits (anim dict, then model) where the player
-- can die, ragdoll, get in a car, or close the UI. Those windows are exactly
-- where an orphaned prop comes from -- a radio welded to a corpse's hand until
-- the next resource restart.
--
-- So every stage is explicit, and every stage re-checks both the token and the
-- context before continuing. An interrupted open tears itself down instead of
-- completing into a state nobody asked for.
--
--   CLOSED -> OPENING (load anim -> spawn prop -> attach) -> ACTIVE
--                                                             |
--   CLOSED <- DELETE <- DETACH <- CLOSING <--------------------+
--
-- CONTEXT IS A POLICY, NOT A HARDCODED RULE
-- -----------------------------------------
-- A radio goes to the mouth and should survive walking. A tablet cannot be
-- read while driving. A pager comes off the belt and should not appear at all
-- while swimming. Rather than bake one device's opinion in, each context is a
-- named policy the device sets to 'allow' or 'block'.
-- ASCII only, no BOM, LF endings.

RSDevicePose = RSDevicePose or {}
local Pose = RSDevicePose

local CLOSED, OPENING, ACTIVE, CLOSING = 'closed', 'opening', 'active', 'closing'

local spec = nil
local state = CLOSED
local prop = nil
local token = 0
local wanted = nil       -- predicate supplied by the device
local lastBlock = nil
-- True from the moment this manager issues one of its animation tasks until
-- teardown completes. Do not infer ownership only from IsEntityPlayingAnim():
-- GTA can keep a secondary task/pose alive even when that query no longer
-- reports the clip, which is exactly how an invisible-tablet pose survived
-- after the NUI and prop were already gone.
local animationClaimed = false
local posePed = nil

local function defaults()
    return {
        Enabled = true,
        Dict = nil,
        Enter = nil,
        Loop = nil,
        EnterBlendMs = 650,
        EnterFlag = 48,
        LoopFlag = 49,
        DictTimeoutMs = 2500,
        ModelTimeoutMs = 2000,
        UseProp = false,
        PropModel = nil,
        PropBone = 60309,
        PropOffset = vector3(0.0, 0.0, 0.0),
        PropRotation = vector3(0.0, 0.0, 0.0),
        -- Context policy. 'block' refuses the pose while the condition holds.
        Context = {
            Dead = 'block',
            Ragdoll = 'block',
            Falling = 'block',
            Swimming = 'block',
            Climbing = 'block',
            Cuffed = 'block',
            Vehicle = 'allow',
            Driver = 'allow',
        },
    }
end

local function merge(into, from)
    for key, value in pairs(from or {}) do
        if type(value) == 'table' and type(into[key]) == 'table' and key ~= 'PropOffset' and key ~= 'PropRotation' then
            merge(into[key], value)
        else
            into[key] = value
        end
    end
    return into
end

function Pose.Configure(newSpec)
    spec = merge(defaults(), newSpec)
    return spec
end

function Pose.Spec()
    return spec
end

function Pose.SetWanted(predicate)
    wanted = type(predicate) == 'function' and predicate or nil
end

function Pose.State()
    return state
end

function Pose.IsActive()
    return state == ACTIVE
end

-- ---------------------------------------------------------------------------
-- Context
--
-- Returns nil when the pose may be held, or the name of the first blocking
-- condition. The name is kept so a device can surface "not while driving"
-- instead of silently doing nothing.
-- ---------------------------------------------------------------------------
local function blockedBy(ped)
    if not spec or spec.Enabled == false then return 'disabled' end
    if not ped or ped == 0 or not DoesEntityExist(ped) then return 'no_ped' end

    local ctx = spec.Context or {}
    local function blocks(name) return ctx[name] == 'block' end

    if blocks('Dead') and (IsEntityDead(ped) or IsPedFatallyInjured(ped)) then return 'dead' end
    if blocks('Ragdoll') and IsPedRagdoll(ped) then return 'ragdoll' end
    if blocks('Falling') and IsPedFalling(ped) then return 'falling' end
    if blocks('Swimming') and IsPedSwimming(ped) then return 'swimming' end
    if blocks('Climbing') and (IsPedClimbing(ped) or IsPedVaulting(ped)) then return 'climbing' end
    -- Cuffed is the common RP restraint flag; guarded because not every
    -- framework sets it and the native is absent on some builds.
    if blocks('Cuffed') then
        local ok, cuffed = pcall(IsPedCuffed, ped)
        if ok and cuffed then return 'cuffed' end
    end

    if IsPedInAnyVehicle(ped, false) then
        if blocks('Vehicle') then return 'vehicle' end
        if blocks('Driver') and GetPedInVehicleSeat(GetVehiclePedIsIn(ped, false), -1) == ped then
            return 'driver'
        end
    end

    return nil
end

function Pose.Blocked()
    return blockedBy(PlayerPedId())
end

function Pose.LastBlock()
    return lastBlock
end

local function shouldHold(ped)
    if wanted and wanted() ~= true then return false end
    lastBlock = blockedBy(ped)
    return lastBlock == nil
end

-- ---------------------------------------------------------------------------
-- Prop
-- ---------------------------------------------------------------------------
local function deleteProp()
    if prop and DoesEntityExist(prop) then
        DetachEntity(prop, true, true)
        DeleteEntity(prop)
    end
    prop = nil
end

function Pose.Prop()
    return prop
end

local function spawnProp(ped, mine)
    mine = mine or token
    if mine ~= token or ped ~= PlayerPedId() or not shouldHold(ped) then return false end
    if not spec.UseProp or not spec.PropModel then return true end
    if prop and DoesEntityExist(prop) then return true end

    local model = joaat(spec.PropModel)

    -- A model name that does not exist on this build never loads, so the wait
    -- below would burn its full timeout on every single open and then fail.
    -- Checking validity first turns that into one clear message.
    if IsModelValid and not IsModelValid(model) then
        if not spec.__warnedModel then
            spec.__warnedModel = true
            print(('[%s] prop model "%s" does not exist on this game build. The animation will play without a prop. Set a valid model in the config, or disable the prop.')
                :format(GetCurrentResourceName(), tostring(spec.PropModel)))
        end
        -- Continue WITHOUT the prop rather than refusing the pose. An empty
        -- hand is a cosmetic flaw; refusing would silently disable the device.
        return true
    end

    RequestModel(model)
    local deadline = GetGameTimer() + (spec.ModelTimeoutMs or 2000)
    while not HasModelLoaded(model) and GetGameTimer() < deadline do
        if mine ~= token or ped ~= PlayerPedId() or not shouldHold(ped) then
            SetModelAsNoLongerNeeded(model)
            return false
        end
        Wait(0)
    end
    if mine ~= token or ped ~= PlayerPedId() or not shouldHold(ped) then
        SetModelAsNoLongerNeeded(model)
        return false
    end
    if not HasModelLoaded(model) then
        SetModelAsNoLongerNeeded(model)
        if not spec.__warnedModel then
            spec.__warnedModel = true
            print(('[%s] prop model "%s" failed to load within %dms. The animation will play without a prop.')
                :format(GetCurrentResourceName(), tostring(spec.PropModel), spec.ModelTimeoutMs or 2000))
        end
        return true
    end

    -- Local cosmetic only: not networked, so no OneSync entity to clean up
    -- server-side and no mission-entity budget consumed.
    prop = CreateObject(model, 0.0, 0.0, 0.0, false, false, false)
    if not prop or prop == 0 then
        SetModelAsNoLongerNeeded(model)
        prop = nil
        return false
    end

    local offset, rotation = spec.PropOffset, spec.PropRotation
    AttachEntityToEntity(
        prop, ped, GetPedBoneIndex(ped, spec.PropBone),
        offset.x, offset.y, offset.z, rotation.x, rotation.y, rotation.z,
        true, true, false, true, 1, true
    )
    SetModelAsNoLongerNeeded(model)
    return true
end

-- Re-attach after a live offset change, used by alignment tooling.
function Pose.ReattachProp()
    deleteProp()
    if state == ACTIVE then spawnProp(PlayerPedId()) end
end

-- ---------------------------------------------------------------------------
-- Animation
-- ---------------------------------------------------------------------------
local function loadDict(mine)
    mine = mine or token
    if not spec.Dict then return true end
    if HasAnimDictLoaded(spec.Dict) then return true end
    RequestAnimDict(spec.Dict)
    local deadline = GetGameTimer() + (spec.DictTimeoutMs or 2500)
    while not HasAnimDictLoaded(spec.Dict) and GetGameTimer() < deadline do
        if mine ~= token or not shouldHold(PlayerPedId()) then return false end
        Wait(0)
    end
    return mine == token and HasAnimDictLoaded(spec.Dict)
end

local function stopClips(ped, forceSecondary, forcePrimary)
    if not spec or not ped or ped == 0 or not DoesEntityExist(ped) then return false end

    local exactClip = false
    if spec.Dict then
        -- STOP_ANIM_TASK expects an exit speed, not a boolean-like 0.0.  A real
        -- blend-out value also behaves consistently on Legacy and Enhanced.
        -- We still call it even when IsEntityPlayingAnim already says false:
        -- the task manager can retain the pose for a frame after that query
        -- stops reporting it.
        if spec.Enter then
            if IsEntityPlayingAnim(ped, spec.Dict, spec.Enter, 3) then exactClip = true end
            StopAnimTask(ped, spec.Dict, spec.Enter, 3.0)
        end
        if spec.Loop then
            if IsEntityPlayingAnim(ped, spec.Dict, spec.Loop, 3) then exactClip = true end
            StopAnimTask(ped, spec.Dict, spec.Loop, 3.0)
        end
    end

    local owned = forceSecondary or animationClaimed or exactClip
    if owned then
        -- First release only the upper-body/secondary slot.  This is the gentle
        -- path and is sufficient on most clients.
        ClearPedSecondaryTask(ped)

        -- Some GTA/FiveM builds can leave the tablet's scripted pose in the
        -- primary task tree even though it was started with flag 49
        -- (upper-body + secondary).  That is the exact invisible-tablet state
        -- seen after close: prop gone, NUI gone, hands still frozen.
        --
        -- Because this fallback only runs when THIS manager owned the tablet
        -- pose (or an explicit ForceClose was requested), clearing normal ped
        -- tasks here is not a blind global cleanup.  Do not do it in a vehicle:
        -- broad task clears can interfere with seat/vehicle tasks.
        if forcePrimary and not IsPedInAnyVehicle(ped, false) then
            ClearPedTasks(ped)
        end
        return true
    end
    return false
end

local function playLoop(ped)
    if not spec.Dict or not spec.Loop then return end
    animationClaimed = true
    TaskPlayAnim(ped, spec.Dict, spec.Loop, 8.0, 2.0, -1, spec.LoopFlag or 49, 0.0, false, false, false)
end

-- ---------------------------------------------------------------------------
-- Teardown
--
-- Always safe to call. Bumping the token first invalidates any open sequence
-- still sitting in an await, so a close during OPENING cannot be overtaken by
-- the open it interrupted.
-- ---------------------------------------------------------------------------
function Pose.Close(force)
    local forced = force == true

    -- Snapshot ownership BEFORE changing state. If the tablet was opening,
    -- active, or had already issued its animation task, it owns the task slot
    -- and must release it even if IsEntityPlayingAnim says false. ForceClose
    -- deliberately treats a desynchronised CLOSED state as owned so the manual
    -- recovery command can clean up a pose left behind by an older build.
    local hadPose = forced or animationClaimed or state == OPENING or state == ACTIVE or prop ~= nil
    local hadAnimation = forced or animationClaimed

    token = token + 1
    local closeToken = token
    state = CLOSING

    local ped = posePed or PlayerPedId()
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        -- When this manager actually owned the pose, use the on-foot primary
        -- fallback as part of normal close. This is intentionally stronger than
        -- v0.4.2: ClearPedSecondaryTask alone did not release the frozen hands
        -- on the affected Enhanced client.
        stopClips(ped, hadAnimation, hadAnimation)
    end
    animationClaimed = false
    posePed = nil
    deleteProp()
    state = CLOSED

    -- Re-assert the targeted release on the next frame. The token/state guard
    -- means a newly reopened tablet can never be cancelled by this cleanup.
    if hadPose then
        CreateThread(function()
            Wait(0)
            if token ~= closeToken or state ~= CLOSED then return end
            local currentPed = PlayerPedId()
            if hadAnimation and currentPed == ped and DoesEntityExist(ped) then
                stopClips(ped, true, not IsPedInAnyVehicle(ped, false))
            end
        end)
    end
end

-- Explicit recovery path for /tabletrelease and diagnostics. Unlike Close(),
-- this does not trust the state machine: it assumes the player may already be
-- stuck in an orphaned tablet pose from a prior resource version.
function Pose.ForceClose()
    Pose.Close(true)
end

-- ---------------------------------------------------------------------------
-- Open
-- ---------------------------------------------------------------------------
local function openSequence(mine)
    if mine ~= token or state ~= OPENING then return end
    local ped = PlayerPedId()

    if not loadDict(mine) then
        if mine == token then state = CLOSED end
        return
    end
    -- The dict await is a real window. Re-check before committing.
    if mine ~= token or not shouldHold(PlayerPedId()) then
        if mine == token then Pose.Close() end
        return
    end

    ped = PlayerPedId()
    if not spawnProp(ped, mine) then
        if mine == token then Pose.Close() end
        return
    end
    if mine ~= token or not shouldHold(PlayerPedId()) then
        if mine == token then Pose.Close() end
        return
    end

    ped = PlayerPedId()
    if spec.Dict and spec.Enter then
        animationClaimed = true
        TaskPlayAnim(ped, spec.Dict, spec.Enter, 8.0, 2.0, spec.EnterBlendMs or 650, spec.EnterFlag or 48, 0.0, false, false, false)
        Wait(spec.EnterBlendMs or 650)
        if mine ~= token or not shouldHold(PlayerPedId()) then
            if mine == token then Pose.Close() end
            return
        end
        ped = PlayerPedId()
    end

    playLoop(ped)
    if mine == token then state = ACTIVE end
end

function Pose.Open()
    if not spec then return false end
    if state == OPENING or state == ACTIVE then return true end
    if not shouldHold(PlayerPedId()) then return false end
    token = token + 1
    state = OPENING
    posePed = PlayerPedId()
    local mine = token
    CreateThread(function() openSequence(mine) end)
    return true
end

-- ---------------------------------------------------------------------------
-- Watchdog
--
-- Called on a timer by the device. Three jobs: drop the pose when context turns
-- against it, raise it when the device wants it and context allows, and re-play
-- the loop when something else (a scenario, a stumble, another script) knocked
-- our clip off without clearing the prop.
-- ---------------------------------------------------------------------------
function Pose.Refresh()
    if not spec then return end
    local ped = PlayerPedId()
    if state ~= CLOSED and posePed ~= ped then Pose.Close() end

    if not shouldHold(ped) then
        if state ~= CLOSED or prop then Pose.Close() end
        return
    end

    if state == CLOSED then
        Pose.Open()
        return
    end
    if state ~= ACTIVE then return end
    local mine = token

    if spec.Dict and spec.Loop then
        local playingEnter = spec.Enter and IsEntityPlayingAnim(ped, spec.Dict, spec.Enter, 3) or false
        local playingLoop = IsEntityPlayingAnim(ped, spec.Dict, spec.Loop, 3)
        if not playingEnter and not playingLoop then
            if not loadDict(mine) then return end
            if mine ~= token or state ~= ACTIVE or ped ~= PlayerPedId() or not shouldHold(ped) then return end
            if not spawnProp(ped, mine) then return end
            if mine ~= token or state ~= ACTIVE or not shouldHold(ped) then return end
            playLoop(ped)
        end
    end

    -- The prop can be destroyed underneath us (death cleanup, another script)
    -- while the clip keeps playing. Put it back rather than leaving a mime.
    if spec.UseProp and spec.PropModel and (not prop or not DoesEntityExist(prop)) then
        prop = nil
        spawnProp(PlayerPedId())
    end
end

-- ---------------------------------------------------------------------------
-- Guaranteed cleanup
--
-- Doctrine requires teardown on resource stop, death and logout. The device
-- still owns NUI focus and voice membership; this file owns the prop and the
-- clips, and nothing else should have to remember them.
-- ---------------------------------------------------------------------------
local function emergencyPoseCleanup(resource)
    if resource ~= GetCurrentResourceName() then return end
    -- onResourceStop fires while the resource is still alive, so this is the
    -- primary teardown hook. onClientResourceStop is retained as a harmless
    -- second guard for unusual restart ordering.
    local hadPose = animationClaimed or state ~= CLOSED or prop ~= nil
    local hadAnimation = animationClaimed
    token = token + 1
    state = CLOSING
    local ped = posePed or PlayerPedId()
    if ped and ped ~= 0 and DoesEntityExist(ped) then
        stopClips(ped, hadAnimation, hadAnimation)
    end
    animationClaimed = false
    posePed = nil
    deleteProp()
    state = CLOSED
end

AddEventHandler('onResourceStop', emergencyPoseCleanup)
AddEventHandler('onClientResourceStop', emergencyPoseCleanup)

RegisterNetEvent('QBCore:Client:OnPlayerUnload', function() Pose.Close() end)
RegisterNetEvent('esx:onPlayerLogout', function() Pose.Close() end)
RegisterNetEvent('qbx_core:client:playerLoggedOut', function() Pose.Close() end)

CreateThread(function()
    while true do
        Wait(500)
        -- Death is the one context change that must not wait for the device's
        -- own watchdog interval: a prop attached to a dying ped is the most
        -- visible failure this manager exists to prevent.
        if state ~= CLOSED or prop then
            local ped = PlayerPedId()
            if not ped or ped == 0 or not DoesEntityExist(ped) or IsEntityDead(ped) then
                Pose.Close()
            end
        end
    end
end)
