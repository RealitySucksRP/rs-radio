# RS Radio Voice Backends

## Automatic selection

`Config.Voice.Backend = 'auto'` chooses:

1. `cfx-native` when the Enhanced server-side voice natives are available.
2. `pma-voice` otherwise when the configured pma resource is started.
3. `none` when neither transport is ready; radio opening is denied instead of pretending voice works.

## cfx-native

Server-owned calls:

- `CreateVoiceChannel(0, 0.0)`
- `AddPlayerToVoiceChannel`
- `RemovePlayerFromVoiceChannel`
- `SetPlayerMutedInVoiceChannel`
- `SetPlayerDeafInVoiceChannel`
- `DeleteVoiceChannel`

A stable RS logical route key indexes the runtime channel, but only the server receives or manipulates the Cfx channel ID. PTT starts muted and is explicitly opened/closed by the server.

## pma-voice

Used for Legacy compatibility. RS Radio:

- calls the server `setPlayerRadio` export;
- registers `addChannelCheck` for every configured provider channel;
- observes `radioChannel` state changes with self-write echo suppression;
- defaults to rejecting external changes to RS-owned channels;
- stands down its observer if a known sibling radio is started, preventing a state-bag write loop.

## Feature capability differences

| Capability | Cfx native Enhanced | pma-voice Legacy |
|---|---:|---:|
| Server-owned membership | yes | via pma server export/checks |
| Server-owned PTT mute | yes | provider-managed |
| Server-owned deaf | yes | client/provider setting |
| Radio-only volume | not in documented native API | yes |
| Per-listener player mute | not in documented native API | yes |
| RS telemetry/distress/jammers/access | yes | yes |

Unsupported native controls are hidden/declined; no deprecated Mumble call is used as a silent fallback in native mode.
