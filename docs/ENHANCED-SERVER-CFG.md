# GTA V Enhanced Server CFG

RS Radio v1.0.0 uses the current server-owned Cfx voice channel API on GTA V Enhanced when `Config.Voice.Backend = 'auto'`.

Recommended minimum:

```cfg
voice_internal
ensure rs-radio
```

If framework or inventory resources are used, ensure them before `rs-radio` as usual.

## Do not enable sv_mumble for RS Radio

Cfx documents the Enhanced Mumble compatibility layer as deprecated and warns that `sv_mumble` allows client-controlled voice channels. RS Radio's Enhanced backend does not need it.

If another installed resource still requires `sv_mumble`, that is a server-wide compatibility/security decision outside RS Radio. It removes one of the main security benefits of migrating the radio to the new server-side API.

## PTT

Default Enhanced radio PTT is `LMENU` (Left Alt) through `+rs_radio_talk`. The client sends only transmit intent. The server decides whether the player is a valid channel member and calls the Cfx mute native.

## Voice capability note

The currently documented native API owns membership, mute and deaf state, but does not expose a radio-only per-listener volume or per-listener mute operation. RS Radio hides those unsupported controls on this backend rather than emulating them through deprecated Mumble calls.
