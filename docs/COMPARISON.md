# Reference-radio comparison

Snapshot reviewed: **2026-09-30**. This is a feature/architecture comparison from the public repositories named by the RS Radio author. No code or art from these projects is included in RS Radio.

References:

- AC Radio: https://github.com/acscripts/ac_radio
- MM Radio: https://github.com/SOH69/mm_radio
- KC Radio: https://github.com/KevinGbg/kc-radio

## Publicly documented reference features

### AC Radio

The current public README/manifest reviewed for this audit advertises two player presets, job/group restrictions, configurable frequency range/precision, command/item access, tooltips, radio volume controls/steps, and lockdown compatibility. The reviewed manifest identifies v2.1.0 and requires `ox_lib` plus `pma-voice`.

### MM Radio

The current public README/manifest reviewed for this audit advertises a radio UI/submix, job/gang-restricted channels, movable/resizable UI, display name, battery, notifications, overlay customization, and place/remove/configurable-range jammer behavior. The reviewed manifest identifies v2.0.7 and requires `pma-voice`, `ox_lib`, `bl_bridge`, and OneSync.

### KC Radio

The current public README/manifest reviewed for this audit describes QBCore/ESX + `pma-voice`, command/key/item opening modes, job-locked channels, and anonymous mode. Its reviewed manifest uses the older `adamant` FX version and mysql-async.

## RS Radio coverage

| Capability | RS Radio v1.0.0 |
|---|---|
| Modern NUI radio | yes |
| Favorites / recents / direct tune / channel stepping | yes |
| Public channels | yes |
| Job restrictions | yes |
| Gang restrictions | yes |
| Team restrictions | yes |
| Role restrictions | yes |
| ACE restrictions | yes |
| Battery persistence | yes |
| Movable/scalable handset | yes |
| Movable/scalable roster overlay | yes |
| Custom display name | yes |
| Deployable jammer | yes |
| Jammer pass-through channels | yes |
| Routing-bucket-aware jamming | yes |
| Damage/removal/persistence for jammers | yes |
| Unit roster | yes |
| Live talking state | yes |
| Unit GPS/location | yes |
| Last-known/offline unit state | yes |
| Medical/condition telemetry | yes |
| Distress/SOS board + GPS | yes |
| Server-written integration state bags | yes |
| Qbox bridge | yes |
| QBCore bridge | yes |
| ESX bridge | yes |
| Standalone/custom bridge | yes |
| Optional physical item requirement | yes |
| JSON + Cfx KVP persistence | yes |
| SQL required | no |
| GTA V Legacy `pma-voice` | yes |
| GTA V Enhanced current server-owned Cfx voice API | yes |
| Enhanced client-controlled Mumble required | no |
| Server-owned native PTT/deaf | yes |
| NUI RPC request IDs/timeouts | yes |
| Voice/provider diagnostics | yes |

## Important Enhanced limitation

The current Cfx Enhanced server voice API documents membership, mute, and deaf primitives but does not document a channel-only per-listener volume override or per-listener mute primitive. RS Radio therefore disables those two controls on the `cfx-native` backend. Legacy/pma mode retains them.

That is intentional: using deprecated Mumble compatibility only to preserve those controls would reintroduce the client-controlled channel path that Cfx tells new Enhanced resources to avoid.
