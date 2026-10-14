# Voice ownership

## One active RS radio owner per player

Every RS radio remains a standalone resource. There is no required shared controller resource and no hard dependency between `rs-radio`, Zombie, Gang/Burner, Police, EMS, or future variants.

When `Config.Coexistence.OwnershipProtocol = true`, the running radios coordinate through server-only events plus three small replicated player-state values:

- `rsRadioVoiceOwner`
- `rsRadioVoiceOwnerChannel`
- `rsRadioVoiceOwnerGeneration`

In City Radio v1.0.4, these bags are diagnostic mirrors. Authorization reads a private server ledger updated by successful provider writes and the server-only `rs-radio:ownership:changed` event. Client mutation of a mirror cannot change City Radio's owner. At a late resource start the ledger may not know a sibling's previous claim; a new successful claim still broadcasts to every sibling, whose existing stand-down handler performs local cleanup. No external bridge is needed. Older siblings retain their existing implementation and are not hardened by this patch.

Only the current owner may change or disconnect the real voice transport. A stale/non-owner radio may clear its own roster, UI, animation and local state, but on Legacy it must never write pma channel `0`.

The standard regression is:

1. Radio A joins 101.
2. Radio B joins 666.
3. Radio A closes.
4. The provider must remain on Radio B / 666.

Use `/rsradiostate` while testing to print owner, requested/confirmed channel, provider channel, generation, TX/jammer state, and detected sibling resources.

## Enhanced

RS Radio owns only the native voice-channel membership it creates. Membership, PTT mute, deaf state, and cleanup are server-controlled. The same one-active-device ownership rule is kept for player-facing consistency even though Enhanced can support more sophisticated membership models. When another RS radio takes ownership, this resource releases only its own native membership.

The Cfx documentation warns that enabling Enhanced `sv_mumble` re-enables client-controlled compatibility channels. RS Radio does not require that compatibility mode.

## Legacy / pma-voice

`pma-voice` exposes one current radio channel per player. Its server implementation removes the old radio membership before adding the new one, so two independent active pma radio controllers cannot both own different channels for the same player.

RS Radio protects the Legacy path by:

1. validating RS channel access server-side with `addChannelCheck`;
2. tagging its own provider writes so the state-bag observer ignores self echoes;
3. claiming shared RS ownership only after the provider write succeeds;
4. standing down on external `radioChannel` changes instead of fighting/reasserting the old channel;
5. refusing provider disconnects from stale/non-owner sessions;
6. gating RS PTT and pma volume/mic-click writes to the active device state.

`Config.Security.ExternalVoicePolicy` remains only as an opt-out compatibility setting when the ownership protocol is explicitly disabled. With the ownership protocol enabled, an external provider change is treated as loss of ownership and RS Radio stands down safely.

## Logical channel mapping is not a secret

The display frequency, logical ID, and provider route key are identifiers. Authorization must always succeed or fail from server-side identity/job/team/ACE/inventory/jammer state.
