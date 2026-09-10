# Our Durable Objects against Cloudflare's own guidance

Written 2026-09-03 at the owner's request: download what Cloudflare says about
Durable Objects and check whether we do it their way, because the platform
has counter-intuitive corners (the storage API keeps its own in-memory cache,
so copying stored values into instance fields buys nothing and can go stale;
input and output gates already make a read-then-write sequence atomic; an
alarm may fire twice).

## Sources

Downloaded into `docs/research/cloudflare-do/` on 2026-09-03 so the check
can be repeated against the same text:

- `durable-objects.txt` — the whole Durable Objects documentation as
  Cloudflare serves it for language models (`llms-full.txt`, 15 389 lines).
  The parts this check leans on: the KV and SQLite storage APIs (lines
  6600–7700), the State API (7705–7995), "Access Durable Objects Storage"
  (8284–8624), "Rules of Durable Objects" (9023–11592), "Use WebSockets"
  (11592–12379), the lifecycle (12379–12525), known issues and limits
  (12962–13212), "In-memory state" (15333–end).
- `workers.txt` — the Workers documentation the same way, for the platform
  limits that apply to the Worker in front of the objects.
- Three blog posts, as text: "Durable Objects: Easy, Fast, Correct — Choose
  three" (the input/output gates design), "Zero-latency SQLite storage in
  every Durable Object", "Durable Objects Alarms".

Line numbers below refer to `durable-objects.txt`.

## What the docs say that is easy to get wrong

- The storage has its own in-memory cache: a `get()` of a key read or written
  recently returns from memory, so "load into an instance field once and read
  the field" is an optimisation the runtime already makes (15371). Instance
  fields are still legitimate for things that are not stored data — sockets,
  timers, a flag that says an alarm handler is running — and the docs allow a
  cached copy of stored data when it is invalidated on every write (9887–9988);
  a copy that is not invalidated, or that survives across an `await` of
  non-storage I/O, is where it goes wrong.
- Input gates pause delivery of other events while a storage operation is in
  flight, and a run of writes with no `await` between them is one atomic
  implicit transaction; a read followed by writes with no other I/O between
  them behaves as a transaction without `transaction()` (6769, 10078–10246).
  The gate opens on any non-storage `await` — a `fetch()` to another object,
  a timer — and that is where a real race lives (10246–10298).
- Output gates hold outgoing messages until pending writes are confirmed, so
  a client never sees an acknowledgement of a write that did not land; the
  cost is that every network message after a write waits for the disk unless
  `allowUnconfirmed` is set (6665–6670).
- `blockConcurrencyWhile()` belongs in the constructor for schema setup and
  almost nowhere else (7791–7797, 10298–10396).
- An alarm may fire more than once; the handler must be idempotent
  (11209–11291). One alarm per object at a time.
- In-memory state is gone on eviction, on a crash from an uncaught exception,
  and on every deploy; hibernation of WebSockets also drops it while the
  sockets stay (9887, 12379–12525, 11592–12379).
- Use the hibernatable WebSocket API and `setWebSocketAutoResponse` so a
  ping does not wake the object; keep per-socket state in the serialized
  attachment, under 2 KiB (10817–11097).
- Model objects around the atom of coordination, never a global singleton;
  a single object is a serial queue with a throughput ceiling (9162–9330,
  11353–11431).
- Call objects through RPC methods, always `await` them, and treat the
  errors the platform raises (`retryable`, `overloaded`) as signals
  (10396–10817, 8624–9023).

## Findings

Three sweeps, each reading the doc sections above and then our objects; the
sharpest claims were read back in the code before being written down.
`file:line` is as of 1503c04.

### What we do the way the docs want

- All seven classes are SQLite-backed (`wrangler.jsonc`). Stubs are created
  per call and every call is awaited. Ids are deterministic where they
  should be (`idFromName` for user, chat, author, handle, lookup key) and
  ULIDs where they must be unique.
- Sockets go through the hibernatable API (`acceptWebSocket`,
  `webSocketMessage/Close/Error`), the only socket list is
  `getWebSockets()`, the attachment is tens of bytes and written only on a
  change, the constructor of `UserDO` does almost nothing, and presence is
  rebuilt from attachments after a wake.
- One alarm per object is shared correctly between jobs (`shouldArmAlarm`,
  the running-alarm flag with a deferred re-arm) and is not re-armed when
  the queue is empty. The fan-out and stories queues are idempotent on the
  receiving side (`in:<chatId>` marks, the inbox dedupe).
- `put`/`delete` are chunked at 128 in most places; the catch-up has three
  ceilings at once; `deleteAlarm()` then `deleteAll()` on account wipe
  (needed at our compatibility date).
- No `transaction()`, no `blockConcurrencyWhile` outside what the docs
  allow, no `waitUntil`, no module-level mutable state (the one module
  constant is an immutable `Set`).

### Where we do not — defects

- D1. `DirectoryDO.ts:99–100`: phone hashes are bound 200 per `IN (...)`;
  the SQLite backend allows 100 bound parameters per query (doc 13055).
  Any discover call with more than 100 matching hashes fails.
- D2. `DirectoryDO.ts:117` with `index.ts` `/api/users`: the search string
  goes into `LIKE '%q%'` uncut; a LIKE pattern is capped at 50 bytes (doc
  13057), so a query longer than about 48 bytes fails the search.
- D3. `UserDO.ts:1726–1738`: the push drain sends to APNs and deletes the
  job afterwards; an alarm may fire twice (doc 11209), and a repeat between
  the send and the delete shows the banner twice and burns a `badgeStamp`.
- D4. `ConversationDO.ts:268–287`: `marksMigrated` is set before the
  migration runs, and the migration awaits; a `markOf`/`markMap` in that
  window reads 0. The docs put migrations in the constructor under
  `blockConcurrencyWhile` for exactly this (9761, 7793).
- D5. `ConversationDO.ts:352–362`: `this.blockers` caches another object's
  state (fetched from `UserDO`) in an instance field, invalidated only by a
  `/block-changed` whose result nobody checks (`index.ts` `/api/block`).
  A block can stay unseen by the chat until the object is evicted. The
  comment there still says the truth lives in D1; D1 is empty.
- D6. `ApnsTokenDO.ts:27–37`: between `storage.get("jwt")` and the `put`
  stands an `await` on the JWT mint, which opens the input gate (doc
  10246); two concurrent forced remints both mint. The docs allow
  `blockConcurrencyWhile` for exactly this shape (7797).
- D7. `StoriesDO.ts:440–449`: `/wipe` runs `DELETE FROM` on five tables;
  the docs say only `deleteAll()` removes an object's storage and metadata
  (8366–8370), so a wiped author's object stays alive and billable, and the
  `link:<code>` pointer objects are never wiped at all.
- D8. `UserDO.ts` `webSocketClose`/`webSocketError`: `ws.close()` without a
  code or reason (docs pass both), and «the last socket is gone» is judged
  by `getWebSockets().length`, which still returns a socket in `CLOSING`
  (doc 7865) at our compatibility date, so the offline presence waits for
  the 35 s alarm instead of going out at once.

### Where we do not — costs and gaps, not failures

- The application-level `{"t":"ping"}` every 12 s defeats hibernation: a
  data frame wakes the object (only protocol control frames are handled
  without a wake, doc 11815), and each wake runs `presenceFresh`, rewrites
  the attachment and re-arms the presence alarm with a `storage.put`.
  `setWebSocketAutoResponse` is used nowhere. The docs' shape: the client
  sends the literal `ping`, the object answers `pong` from the runtime
  without waking, and freshness is read from
  `getWebSocketAutoResponseTimestamp` (7881–7913); the presence TTL alarm
  stays as the one timer.
- Instance fields used as caches of stored data, which the built-in cache
  already provides (15371): `UserDO.this.userId` (written from six places),
  `ConversationDO.this.meta` (the seq allocation in `journal()` is correct
  only because every caller mutates the same object reference, not because
  of the gate), `this.blockers` (D5). `this.members`, the pumping/kicked
  sets, `alarmRunning`, the perf counters are legitimate ephemeral state.
- `alarmRunning` + `rearmDelay`/`rearmAt` in `UserDO` and `StoriesDO`: the
  wanted next wake lives only in memory during a drain; an eviction or a
  crash inside `alarm()` loses it and the queue waits for the next enqueue.
  Write the wanted deadline to storage before draining.
- `alarmInfo.retryCount` is read by no handler; the docs suggest giving up
  the platform retry after a few and re-arming (11142–11150).
- Schema versioning: `StoriesDO` grows columns with `ALTER TABLE` in a
  `try/catch`; the docs want a `_sql_schema_migrations` table and numbered
  migrations (9776–9800). `deliveries` has no index on `next_at`, which
  `pump()` filters and orders by (9988).
- `UserDO` and `ConversationDO` keep everything in KV prefixes and `list()`
  scans (the push queue, the fan-out queue, the chat flags) on a SQLite
  object; the docs' default for relational shapes is SQL with indexes.
- Calls between objects are `stub.fetch` on URL paths, not RPC methods
  (10398): no types on either side, errors reduced to HTTP statuses, and
  nowhere is `e.retryable` or `e.overloaded` inspected (8908–8910). Being
  rewritten by another session at the time of writing.
- `ApnsTokenDO("apns-jwt")` is a global singleton on the path of every push
  (11355; 9240 sends frequently read global config to KV); `DirectoryDO`
  has four fixed shards and every search hits all four. No location hints.
- Incoming socket frames are `JSON.parse`d with no length check; the
  platform accepts up to 32 MiB per message. `ws.send` failures are
  swallowed in an empty `catch`. Frames are sent one by one; the docs
  suggest batching small messages (11823–11831).
- The upgrade path checks the `Upgrade` header but not `GET`.
- `compatibility_date` is 2025-06-01: `web_socket_auto_reply_to_close`
  and the automatic `deleteAlarm` on `deleteAll` are both off. Moving the
  date is a decision with other consequences; recorded, not proposed here.
- `docs/protocol.md` says nothing about hibernation, auto-response or the
  fact that presence is bought with wakes.

## Tasks

- C1. Server: the two hard limits — 100 bound parameters per query in
  `DirectoryDO`, the LIKE pattern cut to 40 bytes in the Worker.
- C2. Server: `StoriesDO /wipe` as `deleteAlarm()` + `deleteAll()`, and the
  link pointer objects wiped with the author (keep the codes issued).
- C3. Server: the marks migration into the `ConversationDO` constructor
  under `blockConcurrencyWhile`; a `_sql_schema_migrations` table in
  `StoriesDO` and `DirectoryDO` in place of `ALTER TABLE` in `try/catch`;
  an index on `deliveries(next_at)`.
- C4. Server: the push drain idempotent — mark a job sent in the same
  write that records the devices served, before APNs is called.
- C5. Server: `this.blockers` gone from `ConversationDO`; `blockCheck`
  asks the user's object each time (a storage read there) or holds a
  versioned copy in storage. `this.meta` re-read inside the gate window
  before `journal()` writes.
- C6. Server: `ApnsTokenDO` mint under `blockConcurrencyWhile`, and the
  JWT off the hot path (KV with a TTL or a per-`UserDO` cached copy).
- C7. Server: the wanted next alarm written to storage before a drain in
  `UserDO` and `StoriesDO`; `alarmInfo.retryCount` read.
- C8. Server + client: ping as `setWebSocketAutoResponse("ping","pong")`,
  presence freshness from `getWebSocketAutoResponseTimestamp`, the
  attachment without `lastPing`; the client sends the literal `ping`.
- C9. Server: `webSocketClose(ws, code, reason, wasClean)` echoing the code,
  the last-socket test on `readyState === OPEN` excluding the closing one;
  a length cap before `JSON.parse`; `send` failures logged and the socket
  closed; `GET` checked on the upgrade.
- C10. Server: `stub.fetch` → RPC methods with one wrapper that classifies
  `overloaded` (no retry) and `retryable` (bounded retry, fresh stub) — in
  progress in another session.
- C11. Server: `DirectoryDO` shard count in config with a plan for
  resharding; consider location hints for `UserDO` at registration.
- C12. Docs: hibernation, auto-response and the presence trade-off in
  `docs/protocol.md`; the doc-check repeated after C8/C10 land.
- C13. Push delivery as its own service (the owner's call, 2026-09-03): a
  Go process on `sideshow/apns2` in place of the node relay — HTTP/2
  connection pools per key (APNs is HTTP/2 only and workerd's fetch is
  HTTP/1.1, which is why a relay exists at all), one provider JWT per
  process refreshed on its own clock (so `ApnsTokenDO` goes), APNs backoff
  by response code, `410 Unregistered` reported back to the Worker to drop
  the token. The `UserDO` push queue stays the durable source; the relay
  acknowledges on intake, not on Apple's answer, so the alarm never waits
  on APNs and the `sleep` in `sendPush` goes with it. C6 is subsumed.

## Defects

D1–D8 above; also listed in `docs/qa/defects.md`. None was seen live; each
is a reachable input or a documented platform behaviour read off the code,
and each needs its reproducing test first.
