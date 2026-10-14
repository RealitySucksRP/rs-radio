# RS Radio Security Review

## Trust boundary

The server is authoritative for channel access, voice membership, battery/device state, item consumption, jammer permissions, distress eligibility, and framework identity.

Client telemetry is treated as presentation input where no authoritative game/native value exists. Health, armor, death state, and player position are replaced with server-observed entity data when available before they are redistributed.

## Network events

Client-callable server events validate type/range, active session, access, rate limits, inventory/permissions, and/or server position as appropriate. The common server-to-server communication bus is registered with `AddEventHandler`, not `RegisterNetEvent`.

## Enhanced voice

The Cfx native backend creates and joins voice channels on the server. PTT events cannot select a channel; they can only request transmit on/off for the caller's already-authorized session. Release (`false`) is never rate-limited, preventing a stuck unmute. A maximum continuous-transmit watchdog also closes a stuck PTT.

## Legacy voice

pma channel checks call RS authorization before membership is accepted. With ownership arbitration enabled, external changes cause local stand-down without writing channel zero over the new controller. Reject/adopt reconciliation is the opt-out compatibility path. Internal echoes are suppressed and observer work is deferred outside state-bag callbacks. Legacy transport security remains limited by the provider and Mumble client API.

## State bags

RS integration keys are written by server code, but are client-writable by default on ordinary Cfx configurations. They are presentation state, never authorization. City Radio now keeps ownership in a private server ledger updated through server-only sibling events. `setr sv_stateBagStrictMode true` can further prevent client mutation of replicated player/entity state, but server owners should first verify compatibility with all installed resources because the ConVar is global. Older sibling resources require their own audit/upgrade.

## NUI

All browser actions go through one allowlisted RPC registry. Every callback receives a response, request IDs are checked, browser calls have a timeout, and sensitive operations continue to server validation.

## Remaining operator responsibilities

- Keep FXServer artifacts current.
- Use only owned/licensed artwork and sounds.
- Do not expose privileged ACEs broadly.
- Review custom standalone inventory callbacks/exports before enabling physical-item mode.
- Test every framework bridge actually installed on the target server.
