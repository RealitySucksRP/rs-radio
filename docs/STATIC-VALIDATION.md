# Validation report — RS Radio v1.0.4 candidate

Validation date: 2026-10-08

These checks run without a live FXServer/client pair. The complete flow, root causes, compatibility matrix and remaining gates are in [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md). This report does not certify real audio, OneSync or CEF behavior.

## Passed gates

- 50/50 executable Lua regression cases pass using Lua 5.4 and mocked Cfx/framework/inventory contracts. Cases include owner-bag spoofing, stale open/PTT/pose work, source reuse, item loss, native gate failures, duplicate joins, free jammer recovery, inventory capacity, profile coalescing and persistence fallback. Stress cases send 1,000 malformed requests and 1,000 repeated offline leaves.
- 16/16 Lua files compile, including the manifest and inventory examples.
- Both NUI JavaScript files pass `node --check`.
- All three JSON seed files parse and remain byte-identical to the pre-audit baseline.
- All explicit manifest assets and the sound glob resolve.
- 75 headless Edge cases pass with no page errors: six pages across four resolutions and three requested handset scales, plus profile/capability/escaped-traffic checks. Long text and 25 roster rows have no horizontal overflow; the handset and overlay remain inside the viewport and do not overlap. A screenshot was visually inspected.
- Current configured channel maps across City, Police, Gang and EMS Radio have no duplicate provider routes. City's reserved band no longer spans the sibling bands.
- No remote Lua loader, money mutation, mandatory SQL import or external RS bridge was found in executable source.
- The ownership integration event remains a server-local `AddEventHandler`. The private server ledger, rather than client-writable replicated mirrors, now authorizes City ownership decisions.
- The changed-files archive excludes old `.bak` files, runtime/test dependencies and player data. Existing development backups remain in the working folder and are not loaded by the manifest.

## Live checks still required

Run the exact candidate on the intended FXServer artifact with two clients and complete [CFX-RELEASE-CHECKLIST.md](CFX-RELEASE-CHECKLIST.md) and the scenario list in [PRODUCTION-AUDIT.md](PRODUCTION-AUDIT.md). Verify actual item activation, framework character transitions, native/pma audio, interrupted PTT, sibling takeover, provider/resource restart, routing buckets, persistent jammer entities, animation cleanup, CEF focus and measured performance on both Legacy and Enhanced.

The active inspected server configuration ensures EMS Radio rather than City Radio, and generic radio items still target Zombie Radio. This audit changes neither activation nor item routing. The sibling resources are unchanged and retain their own ownership-trust limitations. Persistence is debounced and cannot atomically commit an external inventory mutation with a world-record update; abrupt process failure still requires reconciliation.
