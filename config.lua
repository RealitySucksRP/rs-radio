Config = {}

Config.Debug = false
Config.Framework = 'auto' -- auto, qbcore, qbox, esx, standalone
Config.Inventory = 'auto' -- auto, ox_inventory, framework, standalone
-- Voice transport. `auto` prefers GTAV Enhanced's current server-owned Cfx
-- voice API when those natives exist, and falls back to pma-voice on Legacy.
-- Do not enable `sv_mumble` on Enhanced for RS Radio; that compatibility mode
-- permits client-controlled voice channels and is intentionally not required.
Config.Voice = {
    Backend = 'auto', -- auto, cfx-native, pma-voice
    Resource = 'pma-voice',
    NativePTTKey = 'LMENU',
    NativePTTCommand = '+rs_radio_talk',
    MaxTransmitSeconds = 120
}
-- Backwards-compatible alias for integrations that still read this field.
Config.VoiceResource = Config.Voice.Resource

-- Allows RS Radio to run alongside specialized RS radio resources without
-- fighting their pma-voice state changes. Add custom sibling radio resource
-- names here when they also own radioChannel state on the same server.
Config.Coexistence = {
    Enabled = true,
    -- Shared, dependency-free ownership protocol. Every RS radio can remain a
    -- standalone resource; when more than one is running they coordinate through
    -- server events + small player state keys instead of calling each other.
    OwnershipProtocol = true,
    OwnershipDiagnosticCommand = 'rsradiostate',
    EnableOwnershipDiagnosticCommand = true,
    KnownRadioResources = {
        'rs-radio',
        'rs-zombieradio',
        'rs-zombieradio_lcd',
        'rs-radiogangs',
        'rs-radiopolice',
        'rs-radioems'
    }
}

-- Item / opening behavior
-- Default: the RS resource IS the radio device. Players do not need a separate
-- qb-radio/ox_inventory radio item just to use the system. Set this true only
-- on servers that intentionally want a physical inventory item requirement.
Config.RequireRadioItem = false
Config.RadioItems = { 'radio', 'rs_radio' }
Config.EnableTestCommand = false
Config.TestCommand = 'radio'
Config.EnableDiagnosticCommand = false
Config.DiagnosticCommand = 'rsradiodiag'
Config.CloseWhenItemMissing = true
Config.ItemAuditInterval = 5000

-- Standalone/custom inventories must explicitly prove ownership when item checks
-- are enabled. Either configure an export or answer the callback event documented
-- in README.md. The resource never silently grants a radio anymore.
Config.StandaloneInventory = {
    Resource = nil,
    HasItemExport = nil,
    HasNamedItemExport = nil,
    RemoveItemExport = nil,
    AddItemExport = nil
}

-- Do not toggle pma voice state from the NUI close path.
Config.Keybind = {
    Enabled = true,
    Default = 'F11',
    Command = 'rs_radio_toggle',
    Description = 'Open / close RS Radio',
    -- Coalesces key-repeat/spam while preserving deliberate open/close presses.
    ToggleDebounce = 600,
    -- Prevents a lost server response from leaving the client transition locked.
    OpenRequestTimeoutMs = 3000,
    NextChannel = { Enabled = true, Default = 'PERIOD', Command = 'rs_radio_next', Description = 'Next available radio channel' },
    PreviousChannel = { Enabled = true, Default = 'COMMA', Command = 'rs_radio_previous', Description = 'Previous available radio channel' }
}

-- No unknown frequency can bypass the server's named-channel rules.
Config.AllowCustomFrequencies = false
Config.MaxFrequency = 999
Config.DefaultChannel = 200
Config.DefaultVolume = 55

Config.Persistence = {
    Enabled = true,
    ProfilesFile = 'data/profiles.json',
    BatteriesFile = 'data/batteries.json',
    JammersFile = 'data/jammers.json',
    SaveDebounceMs = 1200,
    -- When supported by the inventory, a stable ID is written into item metadata.
    -- Frameworks without item metadata fall back to a per-character device ID.
    DeviceMetadataKey = 'rsRadioId'
}

Config.Battery = {
    Enabled = true,
    StartingLevel = 100,
    DrainPerMinute = 1,
    LowThreshold = 15,
    RechargeItems = { 'radiocell' },
    RechargeAmount = 100,
    RechargeCommand = 'rechargeradio'
}

Config.Telemetry = {
    Enabled = true,
    Interval = 1500,
    StaleAfterSeconds = 10,
    MaxStreetLength = 48,
    MaxZoneLength = 32
}

Config.Roster = {
    FlushInterval = 1000
}

Config.LastKnown = {
    Enabled = true,
    KeepSeconds = 600
}

Config.Security = {
    OpenCooldownMs = 300,
    JoinCooldownMs = 400,
    TelemetryMinIntervalMs = 700,
    TalkingMinIntervalMs = 120,
    SettingsMinIntervalMs = 250,
    DistressMinIntervalMs = 500,
    JammerActionCooldownMs = 750,
    EnforceVoiceChannels = true,
    -- pma-voice compatibility only. `reject` keeps RS Radio authoritative;
    -- `adopt` may be used only when another trusted server resource deliberately
    -- moves players into RS Radio's configured pma channels.
    ExternalVoicePolicy = 'reject'
}

Config.Animation = {
    Enabled = true,
    Dict = 'random@arrests',
    Enter = 'generic_radio_enter',
    Chatter = 'generic_radio_chatter',
    EnterBlendTime = 650,
    WatchdogInterval = 350,
    UseProp = true,
    PropModel = 'prop_cs_hand_radio',
    -- Left shoulder, upright, face forward.
    PropBone = 60309, -- PH_L_Hand
    PropOffset = vector3(0.075, 0.047, 0.011),
    PropRotation = vector3(-97.9442, 3.7058, -23.2367),
    DisableInVehicle = true
}

Config.UI = {
    ShowWindowLabels = false,
    Position = 'right', -- right or left; individual saved preference can override
    KeepGameInput = true,
    AllowMovementToggle = true,
    AllowPositionSettings = true,
    AllowScaleSettings = true,
    ScaleMin = 75,
    ScaleMax = 120,
    DefaultScale = 100,
    DefaultRadioX = 66,
    DefaultRadioY = 2,
    Overlay = 'default', -- default, always, never
    DefaultOverlayVisible = false,
    DefaultOverlayScale = 100,
    DefaultOverlayX = 78,
    DefaultOverlayY = 8
}

Config.Profile = {
    AllowCustomDisplayName = true,
    MaxDisplayNameLength = 32,
    MaxFavorites = 12,
    MaxRecentChannels = 8,
    MicClicksDefault = true,
    MovementDefault = true,
    ResetCommand = 'rsradioreset'
}

-- Teams are server-authoritative assignments. Another resource can assign them with:
-- exports['rs-radio']:SetPlayerTeam(source, 'lspd', '2-LINCOLN-14', 'officer')
Config.Teams = {
    lspd = { label = 'LSPD', channel = 101 },
    bcso = { label = 'BCSO', channel = 102 },
    ems = { label = 'EMS', channel = 110 },
    fire = { label = 'FIRE', channel = 111 },
    services = { label = 'CITY SERVICES', channel = 201 }
}

-- These are sensible examples only. Server owners can rename jobs/teams/channels
-- without touching the radio brain. Metadata/manual SetPlayerTeam assignments still
-- override the job-derived team when present.
Config.JobTeams = {
    police = { team = 'lspd', role = 'officer' },
    sheriff = { team = 'bcso', role = 'deputy' },
    ambulance = { team = 'ems', role = 'medic' },
    fire = { team = 'fire', role = 'firefighter' },
    mechanic = { team = 'services', role = 'mechanic' },
    taxi = { team = 'services', role = 'driver' }
}

Config.TeamMetadataKey = 'radio_team'
Config.RoleMetadataKey = 'radio_role'
Config.CallsignMetadataKey = 'callsign'

-- Access modes: public, team, roles, jobs, gangs, ace.
-- Logical channels.
--
-- On pma-voice, the number a player sees is NOT the provider channel. Each
-- configured channel gets a stable logical id and an internal backend number.
-- This prevents accidental collisions with other radio resources; authorization
-- still comes from server checks, never from secrecy. On Cfx native Enhanced
-- voice, the server maps these keys to runtime-owned voice channel IDs.
--
-- pma backend keys are derived, not random, so all RS Radio code agrees on the
-- same mapping. Cfx native runtime channel IDs are created and owned server-side.
--
-- Set Enabled = false only if something on your server genuinely needs the
-- displayed number to be the voice channel. That reinstates the weakness.
Config.LogicalChannels = {
    Enabled = true,
    -- High band so backends cannot collide with the low, human-looking numbers
    -- other radio or phone scripts hand the voice provider directly.
    BackendBase = 20000,
    -- Reserve 20000-29999 for City Radio; police/gangs/EMS use the next bands.
    BackendSpan = 10000,
}

-- Channels may pin an `id`. Pinning means renumbering a channel on the LCD
-- keeps everyone in the same voice room instead of silently moving them:
--   [101] = { id = 'police_dispatch_primary', label = 'LSPD DISPATCH', ... }
-- Without one, the id is derived from the number ('ch_101').
Config.Channels = {
    [101] = { label = 'LSPD DISPATCH', access = { mode = 'team', teams = { 'lspd' } }, telemetry = true },
    [102] = { label = 'BCSO DISPATCH', access = { mode = 'team', teams = { 'bcso' } }, telemetry = true },
    [110] = { label = 'EMS DISPATCH', access = { mode = 'team', teams = { 'ems' } }, telemetry = true },
    [111] = { label = 'FIRE DISPATCH', access = { mode = 'team', teams = { 'fire' } }, telemetry = true },
    [120] = { label = 'EMERGENCY INTEROP', access = { mode = 'jobs', jobs = { 'police', 'sheriff', 'ambulance', 'fire' } }, telemetry = true },
    [200] = { label = 'CITYWIDE PUBLIC', access = { mode = 'public' }, telemetry = false, roster = true },
    [201] = { label = 'SERVICES NET', access = { mode = 'jobs', jobs = { 'mechanic', 'taxi' } }, telemetry = false, roster = true },
    [911] = { label = 'EMERGENCY NETWORK', access = { mode = 'public' }, telemetry = false, roster = true }
}

Config.Medical = {
    Provider = 'auto', -- auto, native, external
    BodyHealthResource = 'rs-bodyhealth',
    StableAbove = 70,
    InjuredAbove = 35,
    CriticalAbove = 1,
    ShowVitals = true,
    VitalsRoles = { 'medic', 'doctor', 'ems', 'command', 'supervisor' }
}

Config.Distress = {
    Enabled = true,
    DurationSeconds = 60,
    CooldownSeconds = 20,
    BoardEnabled = true,
    WaypointEnabled = true,
    -- Default recipients hear/see SOS calls from their current channel.
    DefaultRecipientModes = { 'channel' },
    -- 911 reaches every powered radio user, even when they are tuned elsewhere.
    ChannelOverrides = {
        [911] = { modes = { 'radio' } }
    },
    -- Optional extra recipients used by modes jobs/roles/teams.
    Jobs = { 'ambulance', 'police', 'sheriff', 'fire' },
    Roles = { 'medic', 'doctor', 'command', 'supervisor' },
    Teams = { 'ems', 'fire' }
}

Config.Jammer = {
    Enabled = true,
    Model = 'sm_prop_smug_jammer',
    Item = 'jammer',
    RequireItem = true,
    Command = 'rsjammer',
    Permission = {
        Jobs = { 'police', 'sheriff' },
        Gangs = {},
        Roles = { 'supervisor', 'command' },
        Aces = { 'rsradio.jammer' }
    },
    Range = { Min = 10.0, Max = 100.0, Step = 5.0, Default = 30.0 },
    AuditInterval = 1000,
    InteractionDistance = 4.0,
    MaxPlacementDistance = 5.0,
    CanDamage = true,
    ReturnItemOnRemove = true,
    PersistPlaced = true,
    Defaults = {
        -- { id = 'military_blackout', coords = vector4(x, y, z, h), range = 45.0,
        --   allowedChannels = { 120 }, enabled = true, canDamage = true }
    }
}

Config.Locale = {
    no_item = 'You need a working radio item in your inventory. (This server has physical-radio mode enabled.)',
    radio_item_unregistered = 'The server has RS Radio running, but no configured radio item is registered in the active inventory.',
    inventory_not_ready = 'Your inventory is not ready yet. Try the radio again in a moment.',
    dead_battery = 'The radio battery is dead.',
    denied = 'Access denied to that frequency.',
    joined = 'Connected to %s.',
    left = 'Radio disconnected.',
    no_voice = 'The configured voice resource is not running.',
    team_set = 'Radio team assignment updated.',
    distress_sent = 'Distress beacon activated.',
    distress_cancelled = 'Distress beacon cancelled.',
    distress_alert = 'DISTRESS -- %s at %s',
    distress_expired = 'Distress beacon expired.',
    jammed = 'Radio signal jammed.',
    jammer_clear = 'Radio signal restored.',
    jammer_denied = 'You are not authorized to configure radio jammers.',
    jammer_placed = 'Radio jammer deployed.',
    jammer_removed = 'Radio jammer recovered.',
    jammer_not_found = 'No radio jammer is close enough.',
    jammer_spawn_failed = 'The jammer could not be deployed here.',
    recharged = 'Radio battery recharged to %s%%.',
    no_cell = 'You need a radio battery cell.',
    muted = '%s muted on radio.',
    unmuted = '%s unmuted on radio.',
    profile_reset = 'Radio settings restored to defaults.'
}

-- Optional organization aliases for the common communication bus. These create
-- no dependencies -- they are server-side route definitions so a dispatcher can
-- address `destination.departments = { 'police' }` without knowing this
-- server's job names. Kept aligned with rs-90sbeeper's block on purpose: the
-- same dispatch must reach radio, pager and tablet identically.
Config.Departments = {
    police = { type = 'jobs', names = { 'police', 'sheriff' }, dutyOnly = true },
    ems = { type = 'jobs', names = { 'ambulance', 'ems', 'doctor' }, dutyOnly = true },
    fire = { type = 'jobs', names = { 'fire' }, dutyOnly = true },
    services = { type = 'jobs', names = { 'mechanic', 'taxi', 'tow' }, dutyOnly = false }
}

-- Communication events.
--
-- Any server script can raise one with:
--   TriggerEvent('rs-comms:dispatch', { ... })
-- or exports['rs-radio']:DispatchCommEvent({ ... })
--
-- The same event reaches every installed RS device and each renders it in its
-- own voice. Nothing depends on anything: with no dispatcher installed nothing
-- raises events, and with no devices installed nothing listens.
--
-- MinPriority keeps routine chatter off the radio without the dispatcher
-- needing to know which devices this server runs.
-- routine | priority | urgent | emergency
Config.CommEvents = {
    Enabled = true,
    MinPriority = 'routine',
    -- Server-console smoke test for the shared bus. Raises a REAL communication
    -- event so routing can be exercised before any dispatcher exists. In game it
    -- needs the rsradio.admin ace. Set to false to remove the command entirely.
    DispatchTestCommand = 'rsdispatchtest',
}
