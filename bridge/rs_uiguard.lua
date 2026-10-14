-- =============================================================================
-- RS Radio -- keybind guard
-- =============================================================================
-- Included directly so radio key mappings can be suppressed while another
-- full-screen UI owns input, without requiring another resource.
-- =============================================================================

--[[
    RS Radio -- keybind guard for full-screen UIs

    ox_inventory calls SetNuiFocusKeepInput(true) so it can decide for itself
    which controls survive while the inventory is open. That means raw game input
    keeps flowing. ox then calls DisableAllControlActions(0) every frame, which
    stops standard controls -- but a command bound through RegisterKeyMapping is
    dispatched by the command system, NOT as a control, so DisableControlAction
    has no effect on it. Every other resource's menu keybind therefore still
    fires while the player is dragging items around the inventory, which is why
    other menus open mid-drag.

    This file is loaded first in the resource's own Lua VM. Overriding the two
    natives here guards the radio key mappings without modifying ox_inventory.

    MUST be listed FIRST in client_scripts, ahead of the resource's own files --
    the overrides have to exist before that resource calls RegisterCommand or
    RegisterKeyMapping.
]]

local nativeRegisterKeyMapping = RegisterKeyMapping
local nativeRegisterCommand = RegisterCommand

-- Commands that are reachable from a key. Only these get suppressed; a command
-- typed deliberately is left alone unless it is also bound to a key.
local keyCommands = {}

local function stripPrefix(command)
    return (tostring(command or ''):gsub('^[%+%-~]', ''))
end

--- True while a full-screen UI owns the screen and keybinds must not fire.
--- `invOpen` is ox_inventory's own player statebag. `rsUiOpen` is ours, so any
--- RS resource with a full-screen NUI can opt in with:
---     LocalPlayer.state:set('rsUiOpen', true, false)
local function uiOwnsInput()
    local state = LocalPlayer and LocalPlayer.state
    if not state then return false end
    return state.invOpen == true or state.rsUiOpen == true
end

RSRadioUiGuard = RSRadioUiGuard or {}
RSRadioUiGuard.Blocked = uiOwnsInput

function RegisterKeyMapping(command, description, mapper, key)
    if type(command) == 'string' then
        keyCommands[command] = true
        keyCommands[stripPrefix(command)] = true
    end
    return nativeRegisterKeyMapping(command, description, mapper, key)
end

function RegisterCommand(name, handler, restricted)
    if type(name) ~= 'string' or type(handler) ~= 'function' then
        return nativeRegisterCommand(name, handler, restricted)
    end

    local isRelease = name:sub(1, 1) == '-'

    return nativeRegisterCommand(name, function(source, args, raw)
        -- The membership test happens at invocation, not registration, because
        -- resources commonly call RegisterCommand before RegisterKeyMapping.
        --
        -- Release halves are never blocked: if the key went down before the UI
        -- opened, swallowing the matching -command would leave whatever it
        -- started stuck on.
        if not isRelease and keyCommands[name] and uiOwnsInput() then
            return
        end

        return handler(source, args, raw)
    end, restricted)
end
