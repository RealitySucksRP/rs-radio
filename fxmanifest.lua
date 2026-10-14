fx_version 'cerulean'
game 'gta5'

name 'rs-radio'
author 'RealitySucksRP'
description 'RS Radio - modern multiplayer radio with protected voice, unit telemetry, emergency alerts, profiles, batteries, overlays, and RF jammers'
version '1.0.4'
license 'GPL-3.0-or-later'

ui_page 'html/index.html'

shared_scripts {
    'config.lua',
    -- Common communication-event format, byte-identical across RS devices.
    -- After config.lua so anything reading Config at load time already has it.
    'shared/commevent.lua'
}

client_scripts {
    -- Must stay first. This resource binds F11 by default (open radio) plus channel
    -- next/previous. ox_inventory calls SetNuiFocusKeepInput(true), so raw
    -- input keeps flowing while the inventory is open and a RegisterKeyMapping
    -- command is dispatched by the command system, not as a control -- meaning
    -- DisableControlAction cannot stop it. Without this the radio pops open
    -- mid drag-and-drop.
    'bridge/rs_uiguard.lua',
    'client/bridge.lua',
    'client/voice.lua',
    'client/rpc.lua',
    -- Shared device prop/animation lifecycle. Before main.lua, which configures
    -- it with the radio's clips and context policy at load time.
    'client/pose.lua',
    'client/medical.lua',
    'client/main.lua'
}

server_scripts {
    -- Logical channel map. Before main.lua, whose voice boundary depends on it.
    'server/channels.lua',
    'server/bridge.lua',
    'server/voice.lua',
    'server/main.lua'
}

files {
    'html/index.html',
    'html/style.css',
    'html/app.js',
    'html/rs-enhanced.js',
    'html/img/radio.png',
    'html/sounds/*.ogg'
}

-- Voice/framework resources are detected at runtime so custom voice resource
-- names and standalone inventory adapters remain supported.
dependencies {
    '/onesync'
}
