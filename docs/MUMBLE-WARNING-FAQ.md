# Enhanced voice: repeated Mumble warnings

## Does every Enhanced server get this warning?

No. Enhanced reports this warning when a running script calls the deprecated Mumble compatibility natives. A radio using the Cfx native backend does not need those calls. Another resource, including a Legacy Mumble-based proximity or phone voice provider, can still produce the warning while the radio is installed.

This is a voice-stack compatibility issue. It does not, by itself, prove that RS Radio is causing the repeated calls.

## Configure RS Radio for Enhanced

1. Use a current Enhanced-compatible FXServer artifact and enable OneSync.
2. In this resource's config.lua, change the existing setting:

```lua
Config.Voice.Backend = 'cfx-native'
```

Keep the other Config.Voice settings. The default 'auto' can also select native voice when it is available; an explicit backend prevents fallback to the Legacy provider.

3. In server.cfg, enable the internal voice server before starting the radio:

```cfg
voice_internal
ensure rs-radio
```

Start any required framework/inventory resources before the radio as usual. Keep your compatible proximity/phone voice provider configured separately. This two-line example is the radio setup, not a complete replacement voice system.

4. Restart during maintenance and reconnect. Run /rsradiodiag in-game using an account permitted to run diagnostics. Confirm the reported voiceProvider is cfx-native and the voice service is ready. If it is unavailable, check the artifact, voice_internal, startup errors, and resource config; do not force Mumble just to make the diagnostic look connected.

## If the warnings continue

Identify the resource still calling the old API. From the server's resources folder, a source search can help:

```powershell
rg -n 'Mumble[A-Za-z_]+\s*\(' . -g '*.lua' -g '*.js' -g '*.cs' -g '!node_modules'
```

A search hit is a lead, not proof the file is running. Check server.cfg, included cfg files, and the loaded resource before changing it. Compiled or escrowed scripts may need support from their publisher.

Update or migrate the affected voice provider using an Enhanced-compatible version. Preserve its proximity, call, radio, permission, and cleanup behavior. Disabling an old provider without a replacement can remove nearby speech or phone audio.

Do not suppress all F8 errors, remove every Mumble call blindly, or disable sv_mumble while other installed resources still require it. RS Radio's native radio backend does not require sv_mumble. Once every affected resource has migrated, remove the compatibility requirement and restart/reconnect to verify the complete voice stack.

voice_enableProximityCycle changes a key binding; it does not fix Mumble deprecation. The custom voice_useNativeChannels option used by some patched servers is not a standard PMA-Voice fix and must not be recommended without the matching, tested backend.

## Legacy servers

Use the Legacy pma-voice backend and its normal installation instructions. Do not copy the Enhanced-only server API setup into a Legacy server.

## Before calling the issue resolved

Use two real clients to check nearby speech, intended range, private phone calls, permitted radio channels, PTT/release, deafen, disconnect/reconnect, and provider restart. Confirm the warning has stopped without losing audio or leaking conversations.

## References

- [Cfx voice documentation](https://docs.fivem.net/docs/scripting-manual/voice/)
- [Cfx server voice compatibility settings](https://docs.fivem.net/docs/server-manual/server-commands/#voice)

This guide describes the native backend in the accompanying source. If your downloaded package has no Config.Voice.Backend option or native server voice implementation, obtain the matching updated release before applying these instructions.
