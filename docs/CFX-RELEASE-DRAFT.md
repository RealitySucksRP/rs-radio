# [FREE] RS Radio — server-owned Enhanced voice, Legacy pma, telemetry, SOS, jammers

RS Radio is a free modern handheld-radio resource for FiveM. It supports Qbox, QBCore, ESX and standalone setups through one bridge layer and automatically chooses the current Cfx server voice API on GTA V Enhanced or `pma-voice` on Legacy.

## Features

- Server-authoritative frequency access: public, team, role, job, gang and ACE rules.
- Current GTAV Enhanced server-owned voice channels and server-controlled PTT/deaf state.
- Legacy `pma-voice` support.
- Unit roster, callsigns, talking state, GPS/location, signal and last-known state.
- Medical/condition telemetry with optional `rs-bodyhealth` integration.
- SOS/distress board with GPS routing.
- Persistent profiles, favorites, recents, display name, layout and battery.
- Deployable RF jammers with permissions, range, pass-through frequencies, routing-bucket handling and persistence.
- Qbox/QBCore/ESX/standalone bridges; optional physical radio items.
- JSON persistence with Cfx KVP fallback; no SQL dependency.
- Server-written state bags and integration exports.
- Modern handset NUI with remappable controls.

## Requirements

- OneSync.
- Enhanced: `voice_internal` and a current FXServer build exposing the server voice API.
- Legacy: `pma-voice`.
- Framework/inventory dependencies only when that bridge is selected.

## Performance

**Replace this section with measured live `resmon`/profiler data from the final ZIP before posting.**

Idle: `[MEASURE]`
Active radio/roster: `[MEASURE]`

## Download

Attach `rs-radio-v1.0.0-free-cfx.zip` to the forum topic or provide the public repository/free delivery link.

## License

GPL-3.0-or-later.
