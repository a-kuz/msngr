# Presence by subscription between user objects — live run, 2026-09-02

Branch main at a41770f plus the two fixes below, on the shared stand
(`msngr.a-kuz.online`, code rsynced, D1 migration 0019 applied, the trio
relinked with `POST /api/dev/relink`). Two simulators of mine, `fable-a` and
`fable-b`, on the fixture homes; the client build is main at a8937ed.

## What changed on the server

- `HandleDO`: the handle's owner and the rename quarantine, one object per
  folded username; `DirectoryDO`: the people-search index over four SQLite
  shards. `released_usernames` dropped. All 4773 stand accounts reindexed by
  pages of 200 (`/api/dev/reindex`): no clashes.
- Presence travels between user objects: the chat roster builds `sub:`/`watch:`
  relations in each member's object, the source filters its subscribers in a
  fixed number of D1 statements and pushes; the subscriber keeps `peer:<id>`
  and answers `GET /api/users/:id` and a fresh socket from it.
  `ConversationDO` no longer fans presence out over the chats.

## Server side, by a raw socket

`alfa-ws-probe.log` — a node WebSocket as alfa, while bravo went to the
background and came back (`idb ui button HOME`, a tap on the icon):

```
open
hello
presence bravo   online:true   (the snapshot on connect: the copy the object held)
presence charlie online:false  (the second copy)
presence bravo   online:false  lastSeen=+7s   (HOME)
presence bravo   online:true   lastSeen=+14s  (icon tap)
```

`bravo-ws-probe.log` — the same as bravo watching charlie: offline 3 s after
HOME, online 2 s after the tap. `GET /api/users/<bravo>` as charlie answered
the copy at each step: `online:false` after HOME, `online:true` after the
return.

## Two fixes the run forced

1. **A ping from a backgrounded app made the user online again.** `bg` zeroed
   the socket's `lastPing`, and the client's next regular ping (every 12 s,
   the timer keeps running in the background) read as a fresh one, so the
   user came back online until the TTL. Alfa's header showed bravo «в сети»
   a minute after bravo had left. The socket now remembers `bg` and its pings
   keep it alive without counting as presence until `fg`.
2. **Two flips in one second landed in either order.** `bg` false and the
   ping's true were two pushes to the subscriber's object; the later one to
   arrive won. Every flip carries the source's `presenceStamp`, a counter in
   its storage, and the subscriber drops a push older than the copy it holds.

## Client side

`charlie-sees-bravo-offline.png`, `charlie-sees-bravo-online.png`: charlie's
chat header with bravo, «был(а) только что» seven seconds after bravo's HOME,
«в сети» seven seconds after bravo's return. `bravo-sees-charlie-online.png`
and `alfa-sees-bravo-online.png`: the header at chat open on the other two
homes.

The deltas did not show on alfa's and bravo's own screens, and the reason is
not in the presence path: both clients sit in the incoming-frame drain
replaying the pending envelopes of the broken alfa–bravo pair
(`bravo-stuck-drain-stack.txt`: `drainIncoming → applyIncomingBatch →
retryPending → replay → DoubleRatchetSession.skipRecvKeys`, 285 of 285
samples), so no frame of any kind is applied after the first batch — typing
frames sent to bravo by a raw socket did not show either, and bravo's own
presence dropped to offline in the foreground because its ping timer starved.
The snapshot on connect did land (bravo's database held charlie's presence
from the moment of launch). Logged in `defects.md`.

## Also

- `swift test` and MsngrTests untouched by this change (server only).
- Server smoke on a throwaway stand: 443 ok, ALL PASS, including the new
  checks (a handle in any case, a bot's clash with a person's handle, the
  presence snapshot on a fresh socket).
