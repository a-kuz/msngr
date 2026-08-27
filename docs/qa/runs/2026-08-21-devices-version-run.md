# The device cache survives a reconnect, run

Two fresh simulators (`rundev-a`, `rundev-b`, iPhone 17 / iOS 26.5) as the
fixture accounts `alfa` and `bravo`, against a private stand on :8803 running
the branch server code over a copy of the shared stand's state (so the fixture
homes opened their real chats and history; the shared stand itself was not
touched). Both apps reached the stand through a small logging proxy on :8804
(`2026-08-21-devices-version/run-proxy.mjs`): one log line per HTTP request and
per `/ws` upgrade, and killing the proxy is what drops both sockets at once.

The scenario, scripted (`run-cycles.sh`): launch both apps, alfa opens the
direct chat with bravo and sends one warm-up message, then 8 cycles of "kill
the proxy — 4 s — restart it — wait until both apps re-upgrade — alfa sends
one message". Identical for both builds; the same homes and stand state carried
over from one build to the next, so the second run started where the first
ended.

## Numbers

Counted from the sanitized proxy logs in `2026-08-21-devices-version/`:

| build | socket upgrades | GET /api/devices | messages delivered |
| --- | --- | --- | --- |
| before (5a830c2, blanket drop) | 18 | 9 | 9/9 |
| after (this branch) | 18 | 1 | 9/9 |

Before: the warm-up costs one read (the cache is empty in a fresh process) and
then every one of the 8 reconnects costs another on the next send — the
`connected` handler had thrown the whole cache away. After: the same warm-up
read, and every reconnect after that costs nothing — the sync's
`deviceVersions` answer confirmed the cached entry and the sends went out of
the cache. Upgrades are 2 initial + 2 per cycle in both runs, so the stretch
of socket drops is the same on both sides of the comparison.

Delivery held in both runs: every message showed up on bravo readable
(screenshots checked after each run; the second run ended with «18
непрочитанных сообщений» and both runs' texts in the feed). Zero unreadable
messages.

## What the change is

`users.devices_version` in D1, bumped in the same batch as every device link
(`/api/provision/:id/claim`) and revocation. `GET /api/devices` returns
`versions` read in the same batch as the lists; the `devices` frame names the
version the set changed to; the client sends the versions it holds in the
`sync` frame and the server answers with a `deviceVersions` frame. On
reconnect cached entries turn suspect instead of being dropped: the answer
confirms the unchanged ones, drops the changed and the unknown, and a send
that races the answer treats a suspect entry as absent and re-reads the list —
so a device linked while the client was offline is encrypted to before the
next message, and a revoked one stops being addressed. Details in
`docs/protocol.md`.

## Verified with

- `swift test` in MsngrKit against the private stand: 373 tests, 0 failures.
  `DeviceVersionTests` covers the three cache cases offline (unchanged
  confirmed, changed dropped, unknown dropped);
  `DeviceCacheTests.testReconnectKeepsCurrentCacheAndRefetchesChanged` does
  the same end-to-end — a quiet reconnect costs no `/api/devices` and a
  device linked while the sender was offline receives the very next message.
- `BASE_URL=http://localhost:8803 PUSH_PORT=9873 node test/smoke.mjs`: ALL
  PASS.
- `tsc --noEmit` on the server: clean.
- The live run above.

## To do at merge

The branch lands `server/migrations/0006_devices_version.sql`. `wrangler dev`
on the shared stand hot-reloads the merged server code, and the new
`/api/devices` 500s until the column exists — apply the migration in the same
breath as the merge:
`cd server && ./node_modules/.bin/wrangler d1 migrations apply msngr --local`.

## Found on the way

A `SyncEngine` started again after `stop()` never drained its outbox: the
wakeup `AsyncStream`s are single-iteration and died with the cancelled tasks.
No app path restarts an engine, so nothing user-visible; fixed in passing
(`start()` recreates the streams) and logged in `docs/qa/defects.md`.
