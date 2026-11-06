# GTA V Enhanced Server CFG

RS Radio uses the current server-owned Cfx voice channel API on GTA V Enhanced when `Config.Voice.Backend = 'auto'`.

Recommended minimum:

```cfg
voice_internal
ensure rs-radio
```

If framework or inventory resources are used, ensure them before `rs-radio` as usual.

To require the Enhanced backend instead of permitting automatic Legacy fallback, set the existing `Config.Voice.Backend` option to `'cfx-native'`. Leave other voice options intact.

This config enables the radio transport. Your server still needs a compatible proximity/phone voice provider. Starting a Legacy Mumble-based provider beside the native radio can still produce Mumble deprecation warnings. See [Mumble warning troubleshooting](MUMBLE-WARNING-FAQ.md).

## Do not enable sv_mumble for RS Radio

Cfx documents the Enhanced Mumble compatibility layer as deprecated and warns that `sv_mumble` allows client-controlled voice channels. RS Radio's Enhanced backend does not need it.

If another installed resource still requires `sv_mumble`, that is a server-wide compatibility/security decision outside RS Radio. It removes one of the main security benefits of migrating the radio to the new server-side API.

## PTT

Default Enhanced radio PTT is `RSHIFT` (Right Shift) through `+rs_radio_talk`. Saved FiveM key bindings take precedence over this default. The client sends only transmit intent. The server decides whether the player is a valid channel member and calls the Cfx mute native.

## Voice capability note

The currently documented native API owns membership, mute and deaf state, but does not expose a radio-only per-listener volume or per-listener mute operation. RS Radio hides those unsupported controls on this backend rather than emulating them through deprecated Mumble calls.
