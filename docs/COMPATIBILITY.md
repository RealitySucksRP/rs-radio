# RS Radio Compatibility

## Frameworks

- Qbox
- QBCore
- ESX
- Standalone/custom

Framework and inventory selection can be explicit or `auto`.

## Voice

- GTA V Enhanced: current Cfx server-side voice channel API.
- GTA V Legacy: `pma-voice`.

Use `Config.Voice.Backend` to force a backend only when needed.

## Inventory

- `ox_inventory`
- QBCore framework inventory
- ESX framework inventory
- custom standalone exports/events
- no physical item requirement when `Config.RequireRadioItem = false`

## OneSync

`/onesync` is a manifest dependency. Server-side player entities and routing buckets are used for position/bucket validation, and player state bags publish integration state.

## Co-start guidance

Multiple RS radio products may be installed together. They remain separate standalone resources and coordinate only when the shared ownership protocol is enabled. On Legacy/pma-voice, the last successfully authorized RS device to claim the provider becomes the active owner; older RS radios stand down and cannot disconnect the winner. Third-party pma radio changes are treated as external takeover and are not fought or reset to zero by stale RS state.

## Persistence

JSON primary, Cfx resource KVP fallback. No SQL dependency.
