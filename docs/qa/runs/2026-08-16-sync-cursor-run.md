# Catch-up after a long offline, pulled in portions

The sync handler used to walk every chat to the end of its journal inside one
call: the object's single thread was busy for the whole backlog, and a pass cut
short began again. Catch-up is now pulled by the client — one portion per frame,
128 journal records at a time, with the cursor confirmed as each portion lands.

Screenshots — `2026-08-16-sync-cursor/`. Run date: 2026-08-15.

## Stand

Own simulator `msngr-sync` (8B23F859), iPhone 17, iOS 26.5, deleted after the
run. Own `wrangler dev` on :8831 with `--persist-to .wrangler-sync` (D1
migrations applied into the same directory). The app was launched with
`MSNGR_SERVER=http://localhost:8831`, build from the working tree. Users:
`83001` in the app, `syncbeta2` as a headless peer on the same core that seeded
the chat. The client database was read straight from the app group container of
the simulator.

The host ran out of IOSurface clients halfway through the run (see the last
section), so the app was launched through `idb_companion` instead of `simctl`.

## Run

| Step | Expectation | Fact |
|------|-------------|------|
| app terminated, peer sends 305 messages | nothing reaches the device | server journal at seq 308, client at 3 |

Client database after the run: 509 messages with seq 1…509, `COUNT(DISTINCT
seq)` also 509 — no duplicate and no hole; `syncedSeq` 509; `historyGap`,
`pendingDecrypt` and `pendingApply` empty, so nothing was unreadable. Every
message body matches its seq (`text = 'офлайн ' || (seq - 3)` for the first
backlog, `'второй офлайн ' || (seq - 309)` for the second): zero mismatches,
so nothing arrived out of order or under a wrong seq.

## Portions in the live run

The catch-up cursor was polled every 100 ms while the second backlog was coming
in (`syncCursor | syncedSeq | messages stored`):

```
308 | 309 | 309      before the catch-up
308 | 412 | 413      messages of the first portion are landing
437 | 437 | 437      first portion confirmed: 309 + 128
437 | 501 | 501      messages of the second portion are landing
509 | 509 | 509      second portion confirmed, short page, catch-up over
```

The cursor moves one page at a time and only after the messages of that page are
in the database, so a connection lost mid-portion costs one portion, not the run.
Between the portions the object is idle for that device — the client asks for the
next one itself.

## What the run did not cover

The catch-up of many chats at once: the run had two chats, one of them idle, so
the per-portion chat budget was never reached. It is covered by the smoke
(`catch-up portion is bounded`) only.

## Side observation: the dev APNs mock does not scale

`server/tools/apns-mock.mjs` spawns one `xcrun simctl push` per push with no
limit on how many run at a time. During the owner's 20k-message seeding run
about 1200 of them piled up (250 of those stuck in uninterruptible wait) and the
host hit the IOSurface client ceiling of 1024. From that point every
CoreSimulator client aborted on start — `simctl` of any kind, `xcodebuild`
included, machine-wide:

```
Assertion failed: (_iosConnectInitalize() unable to open IOSurface kernel
service: e00002c7 … 1020 existing clients: { … simctl = 856 … })
```

A delivery queue with a small concurrency limit in the mock would keep the host
usable during a long seeding run.
