# Event-driven architecture and Cloudflare limits — an audit

Written 2026-09-03, after the owner found the stories tray polling
`GET /api/stories` once a minute and set the rule out loud: a messenger is
event-driven end to end. Nothing is polled. State changes reach the affected
party as a frame over the live socket, or as a push when there is no socket.
Fan-out and side effects go through durable queues with retries. A read is
served from data already prepared in one Durable Object and returns at once;
a request never assembles its answer by asking many objects. And every one of
those choices is made inside Cloudflare's hard limits, whether or not anybody
has said the word "limits" in the task.

Three sweeps were run in parallel — the Worker, MsngrCore, the app — and a
fourth over the Worker against the platform limits. Each finding below was
read back in the code before it was written down; the four most serious ones
were checked line by line. `file:line` points at the code as of the commit
this audit lands in.

What is already fixed in the same change: stories are delivered, not read.
The author's `StoriesDO` fans the story out from a storage-backed queue into
each recipient's `UserDO`, which keeps an inbox and tells its sockets with a
`story` frame (`new`, `removed`, `stats`, `mark`); `GET /api/stories` reads
that inbox alone; the client reads it once per connection and follows the
frames; the minute poll, the foreground reload and the reload-after-seen are
gone; the audience `everyone` is gone with them (there is no "send to
everyone" in a messenger with a billion users). The details are in
`docs/protocol.md`, the checks in the stories block of `server/test/smoke.mjs`.

## The rule, spelled out

1. A list a screen shows is prepared in advance in the reader's own object
   and read in one request. `/peer-card` copies, `card:<userId>` in a chat,
   the stories inbox are the shape. Asking N objects at request time is the
   breach, whatever N is today.
2. Every write that changes what somebody else sees produces a frame to them,
   and to the writer's other devices. A REST write with no matching
   `ServerFrame` leaves a client that can only find out by refetching, which
   is a poll waiting to be written.
3. A side effect that must happen — a roster copy, a device-set bump, an
   index update — is a row in storage before the request answers, pumped by
   an alarm with a growing pause, never given up. `Promise.allSettled` with
   `console.warn` is a lost write with a log line.
4. Work that has a deadline is armed on that deadline (one alarm per object,
   nearest first). A periodic sweep that looks for something to do is the
   breach.
5. The client learns from frames and resyncs once on connect. A `Task.sleep`
   loop that re-reads while idle, a reload on appear or on foreground, a
   reload after the client's own action, are breaches. A backoff between
   retries of one failed action is not.
6. Every fan is bounded per invocation (1000 subrequests, 30 s CPU, six
   concurrent outbound connections), every `put`/`delete` is chunked at 128
   keys, every `list` has a limit, every client-supplied array has a cap, and
   an object is never held for long: a hot object is a serial queue for
   everyone behind it.
7. A right is a copy in the object of whoever exercises it (the owner's
   word, 2026-09-03). Whether I may watch a contact's story, see their
   avatar, their last-seen, their phone, call them, is answered from my own
   `UserDO` without a request into theirs; when a contact changes a
   permission, a profile or an avatar, the change is fanned out through a
   queue into every interested object — every peer's, every chat's — and
   the copies there are what reads and checks use. The `UserDO` is the
   backend's book, not the client's: none of this is exposed as an API the
   client walks; the client sees frames and its own prepared lists.

## Server: reads that fan over many objects (rule 1)

- `index.ts` `GET /api/chats` (`Promise.all` over every chat's `/state`, then
  `cardsFor` over every unknown member). 1000 chats or 1000 unknown members
  breaks the subrequest cap in one Worker invocation. Shape: the `UserDO`
  keeps a denormalised state per chat, fed by the same `chat` frame that
  already comes through the fan-out queue; the list is one read, paged.
- `index.ts` `POST /api/contacts/discover` → `discoverableBy`:
  `privacyAllows` per found id (each a fetch into another `UserDO`; inside,
  `mayView` for the `contacts` tier fetches `peerPhoneHash` from a third).
  5000 hashes are allowed in; 5000 matches make ~10 000 subrequests. Shape:
  the phone index stores the discovery tier next to the id and answers
  filtered; cap the matches returned.
- `ConversationDO.ts` `membersWithFlagOff`: `Promise.all(readPrivacy)` over
  every member on every `/read` and `/typing`, plus a separate `readPrivacy`
  for the actor. A typing indicator in a group of 100 is 101 object calls,
  on the hottest path there is. Shape: the chat keeps each member's
  `readReceipts`/`typing` next to their `card:<userId>`, updated by the
  `/profile` event that already brings the card.
- `util.ts` `cardsFor`: one `cardFor` per id, used by `/api/chats`,
  `/api/users`, `/api/stories/:id/viewers`, `/api/privacy/exceptions`,
  `/api/contacts/discover`. Each `cardFor` may itself fetch `peerPhoneHash`.
  Shape: cards are pushed copies (`/peer-card`), read locally; the fan stays
  only for genuinely unknown ids and is budgeted.
- `UserDO.ts` `totalUnread`: on a push job, one `/unread-count` per chat with
  a cold cache, serially, inside the alarm handler. 1000 chats after a cold
  start: 1000 subrequests per job, ten jobs per alarm, the object blocked for
  sockets and deliveries the whole time (chat deliveries fail on their own
  10 s timeout and back off). Shape: the badge is a sum kept in the `UserDO`,
  moved by the increment the `msg` frame carries.
- `index.ts` `GET /api/devices` (`Promise.all` over up to 100 users): guarded
  by the cap, and the `deviceVersions` frame exists to avoid it; the client
  still calls it.
- `index.ts` `GET /api/bots`: `Promise.all(ownProfile)` per bot. Small n,
  same shape.
- `UserDO.ts` `sync` handler: one `/state` per chat the client does not know,
  serially, inside `webSocketMessage`. A fresh install with 1000 chats holds
  the user's object for 1000 subrequests; no delivery to them lands while it
  runs. `serveCatchup` next to it is bounded (`SYNC_CHATS`, `SYNC_BUDGET`)
  and is the shape.

## Server: writes with no frame to anyone (rule 2)

- `POST /api/chats/:id/flags` → `UserDO /flags`: pin, mute, archive, sound are
  written and not broadcast to the user's other sockets. Muted on the phone,
  unmuted on the iPad until a manual `GET /api/chats/:id/flags`.
  `this.broadcast` is in the same object.
- `/api/notify-sounds`, `/api/notify-sounds/person/:id`: same.
- `POST /api/privacy`, `POST /api/privacy/exceptions`: the peers hear
  (`broadcastProfile`, `presence-policy-changed`), the user's own other
  devices do not; the privacy screen on a second device shows stale values
  until it refetches.
- `POST /api/block`: no frame to the blocker's other devices; `GET /api/blocked`
  is the only way to learn.
- `POST /api/chats/:id/delete` (direct) → `UserDO /chat-removed`: the key is
  deleted, nothing broadcast; the chat stays on the other device.
- `POST /api/phone`: the index moves, nobody is told; a contact who holds the
  number never learns the person became findable.
- `UserDO.ts` `clearExpiredMute`: a mute's end is noticed lazily on a read, so
  the muted icon stays in the list until a refetch. The object has an alarm;
  `mutedUntil` is a deadline for it (rule 4).
- `StoriesDO.ts`: a story's expiry is a filter on reads; expired rows, views
  and likes are never deleted and no `removed` leaves for them. The author's
  object grows monotonically. Shape: an alarm on `expires_at` that deletes
  and sends `removed` to the recipients. (The inbox on the viewer's side
  drops expired rows as a read meets them; the frame is still missing.)

## Server: side effects with no durable retry (rule 3)

- `ConversationDO.ts` `notifyUserDOsChatList`: `Promise.allSettled` +
  `console.warn`. If `/chat-added` fails, the added member never appears in
  their `GET /api/chats`, while the `chat` frame (which goes through the
  queue and will land) shows the chat on their screen. Two sources of one
  fact, one of them lossy, and nothing heals it. Shape: the same
  `DeliveryRecord` queue as `enqueueFanout`.
- `ConversationDO.ts` the "added to a group" push: `Promise.allSettled`
  unawaited; a failure loses the push. Shape: `enqueueFanout` of a service
  frame that the `UserDO` already turns into `enqueuePush`.
- `UserDO.ts` `/profile-changed`: `Promise.allSettled` over every chat. A
  failed chat keeps the old card in `card:<userId>` for good, and that copy
  is what `memberCards` and the chat list answer from: a rename is lost
  without trace.
- `UserDO.ts` `broadcastDevicesChanged`: the same, and worse: the `devices`
  frame invalidates senders' device caches. A lost bump means a peer keeps
  encrypting to a revoked device. A security degradation left on
  `console.warn`.
- `UserDO.ts` `tell` / `pushCards`: fire-and-forget, justified for presence
  ("the next flip overwrites it"). The same path carries `/peer-card` and
  `/peer-gone`: a lost card stays wrong for the subscriber forever (the chat
  list answers from `PCARD_PREFIX`), a lost `peer-gone` leaves litter from a
  deleted account. Shape: presence stays fire-and-forget; cards and
  `peer-gone` go through a queue.
- `index.ts` `/block-changed` after `POST /api/block`: the fetch result is
  not even logged. If it fails, the `ConversationDO` keeps its cached
  `blockers` and messages keep flowing to the blocker.
- `ConversationDO.ts` `/chat-accepted`: response ignored; a failure means
  the accepter's presence never starts flowing to the requester.
- `ConversationDO.ts` `leaveRooms`: `Promise.allSettled(jobs)`, "the ticket
  expires anyway" — a removed member stays in the SFU room until then.
- `index.ts` `indexUser` (four call sites): the search-index copy is written
  inline, no retry; a failure leaves the index and the profile apart with
  nothing noticing.
- `index.ts` `POST /api/phone`: two `phoneIndexPut` in a row; if the second
  fails the old number keeps answering for the account.
- `index.ts` `POST /api/account/delete`: a serial loop of `/leave` per group,
  then `/account-wipe`, then the stories `/wipe`; no retry, a break midway
  leaves a half-deleted account. Shape: one durable "account teardown" job
  on an alarm.
- `index.ts` `POST /api/username`: `claimHandle` → `profile-write` →
  `releaseHandle` with no compensation; a death between the steps leaves a
  claimed unused handle or two handles on one person.

## Server: wall-clock work where an event exists (rule 4)

- `ConversationDO.ts` `sweepCmids`: the idempotency records are swept from
  `/send`, at most hourly, 512 at a time, and `list`ed without a limit
  first. A silent chat is never swept; an active one pays for the sweep in
  its send path. Shape: an alarm at `ts + CMID_MIN_AGE`, or deletion when the
  delivery mark passes the seq.
- `ConversationDO.ts` `rememberRoomTicket`: lists every `roomTicket:` and
  deletes the expired ones on every ticket issue (and the delete is not
  chunked).
- `UserDO.ts` presence TTL: the alarm re-checks ping freshness. Deliberate —
  a socket dying without a close frame has no event — and stays.
- `push/apns.ts`: `sleep(500/1500)` inside `sendPush`, inside the `UserDO`
  alarm. The outer retry is already durable (`drainPushes`); the pauses hold
  the object and eat the alarm's budget. Shape: report "retryable" outward
  and let the queue set `nextAt`.
- `GET /api/provision/:id`: "Polled by the device being linked until its
  owner approves." The device has no account and no socket yet; the shape is
  still a held request or a socket on the provisioning session, released by
  `/approve`.

## MsngrCore (rule 5)

- `SyncEngine.swift:128–142` the 30-second maintenance loop: `while
  !Task.isCancelled` for the whole session, calling `sweepExpiredMutes`,
  `sweepExpiredMessages`, `sweepUnreadable`, `wakeOutbox` every 30 s. Four
  unrelated concerns on a wall clock; an idle connected device with an empty
  queue wakes twice a minute, runs three to six queries, and can go to the
  network. Shape: a nearest-deadline alarm for mutes (the pattern
  `scheduleNextExpiry` already uses for TTL), a wake on `pendingDecrypt`
  insert / sender key / repair arrival for the unreadable queue, outbox
  wakes only from connect, ack and new row (which exist: 224, 342, 2333,
  2790).
- `SyncEngine.swift:1218–1263` `sweepUnreadable`: a 200-row window plus the
  newest-per-chat set plus three aggregate queries, round-robin, to discover
  whether any pending envelope became decryptable; retries keyed on
  `MessageRepair.retryInterval` (20 s) and `backoff` (30…7200 s) are only
  ever consulted by the timer. Shape: replay a chat's pending envelopes when
  the event that could unblock them lands (sender key, repair answer,
  session rebuild, connect — the connect case exists at 346) and arm one
  alarm at the earliest `lastTriedAt + backoff`.
- `SyncEngine.swift:1075–1085` `republishPrekeysIfDue`, called from every
  sweep: the event trigger at 1055 (`recordUnreadable`) already exists; the
  sweep call is the polling copy.
- `SyncEngine.swift:2543–2549` `announce(waitForSend:)`: a 5-second
  `while Date() < deadline` loop re-querying the outbox every 100 ms to
  learn whether the frame left. Shape: a per-`clientMsgId` continuation
  resolved by `finalizeSent`/`applySentAck`.
- `WSClient.swift:227–239` the 1 Hz watchdog: defensible (a stalled stream
  signals nothing), but a timer armed to the next threshold and re-armed on
  each frame does the same work at three ticks instead of one per second.
- `SyncEngine.swift:718–740` presence over REST: `refreshPresence(of:)` →
  `GET /users/{id}` on chat open, and `ChatViewModel.swift:176` again on
  foreground. Shape: a presence snapshot for the chat's members in the sync
  answer, then transitions over the socket only.
- `SyncEngine.swift:705–713` one `GET /users/{id}` per unknown user in
  unbounded parallel tasks after a catch-up; there is no batched users
  endpoint (there is a batched `devices(userIds:)`). Shape: the frames that
  reference a user carry their card, as `chatsSnapshot` already returns
  `snap.users`.
- `SyncEngine.swift:412–421` `refreshSnapshot` can run two
  `GET /chats/snapshot` in a row (snapshot → create saved chat → snapshot),
  and is called as a repair for an unknown chat (794) and from four app
  sites. Shape: the first snapshot includes the saved chat; a `chat` frame
  announces a chat this account created.
- `SyncEngine.swift:2142–2147` `fillHistoryGap` over `GET /history` next to
  the socket catch-up for the same data: two mechanisms for one job.
- `CryptoGate.swift:119–125`: a `Thread.sleep(0.01)` spin on `flock`. Low
  blast radius, still a spin.

Correctly excluded: `WSClient.swift:213` reconnect backoff; `SyncEngine.swift:255`
and `2696` nearest-deadline alarms; `2992–2999` the 15 s no-ack revert;
`CallManager.swift:1000/1046/1062` one-shot call timeouts; `MediaStream.swift:239`
a retry delay; `NotificationBurstGate`'s coalescing window; `PerfTrace`
(dev-only).

## The app (rule 5)

- `Stories/StoriesTray.swift`, `Stories/StoriesModel.swift`: the minute
  poll, the foreground reload, `markSeen` → `load()`, `postStory` →
  `load()`, the viewer's `load()` on the author's own frame. Fixed in this
  change; kept here as the record of the shape that was wrong.
- `Chat/ChatScreen.swift:1418–1422` `openStory`: when the story is not in
  memory the tap blocks on a full `GET /stories`. Acceptable as a one-off
  point read on a cold list; a point `GET /stories/:id` would be the shape.
- `Screens/SessionsView.swift:54,57,106,133`: `api.sessions()` on appear,
  on pull-to-refresh, and again after a failed revoke; the empty-state text
  says "pull to refresh" because the data goes stale. Shape: `device.added` /
  `device.revoked` frames and a local table; delete the row locally.
- `Screens/SettingsView.swift:352`: `api.sessions().count` for one number in
  a settings row; with 269–270 the screen makes two loads per open. Shape:
  the count lives in `kv`, moved by the same frames.
- `Screens/SettingsView.swift:623–627` `BlockedListView`: `api.blockedUsers()`
  on every appear. The unblock next to it (614–616) is pointwise and shows
  the mismatch.
- `Screens/ChatInfoView.swift:369`: `refreshBlocked()` on every appear
  (`GET /blocked`, the whole account's list, rewriting every user's flag),
  duplicating the call at start (`SyncEngine.swift:126`); 370–377 adds
  `chatFlags` and `personSound`; 778 `prekeys`; 357/746 gallery counts. Four
  or five round trips to draw one profile. Shape: the chat's sound and the
  person's sound come in the chat snapshot and live in `chat`/`user`.
- `Screens/NotificationsView.swift:122,134–140`: `notifySounds()` then
  `soundExceptions()` on each open.
- `Screens/PrivacyView.swift:180,232–241`: `api.privacy()` on `.task`, the
  screen disabled until it answers, for the user's own settings. The writes
  (181–228) are optimistic with rollback and are the shape.
- `Screens/PrivacyExceptionsView.swift:24,31,54,71–73`: add and swipe-delete
  both call `setPrivacyException` then `await load()`, the whole list again.
- `Screens/BotsView.swift:73,76,79–80`: `api.bots()` on `.task` and again
  after `createBot`, which already returns the created record.
- `Screens/ReportView.swift:114–115`: `refreshBlocked()` after one
  `setBlocked`.
- `Onboarding/LinkDeviceView.swift:151–169`: `provisionStatus` polled every
  1.5 s for the session's life (the server side is the provision poll above).
  Separately, line 145 subtracts 2 s per 1.5 s sleep, so the countdown runs
  about a third fast and declares the code expired early — a defect, D9.
- `Chat/ChatViewModel.swift:454–462` `refreshPeerCanCall`: `api.user(peerId)`
  on every chat `start()` for one flag the `user` row could hold. 464–471
  `waitForPeerId` spins 20×100 ms on the database.
- Busy-waits on local state: `ChatViewModel.swift:1601–1607` (`feedContains`,
  20×50 ms), `1559`/`1572` (`ensureLoaded`, up to 12 pages),
  `ChatScreen.swift:1679–1684` (160×50 ms on `isAtDeviceStart`),
  `App/NotificationCoordinator.swift:393–396` (40×250 ms on `engine`).
  Shape: an `AsyncStream` from the feed observation / bootstrap, awaited.
- Local lists without observation: `Screens/ChatGalleryView.swift:115–118`
  reloads on appear and does not observe, so an attachment arriving over the
  socket while the gallery is open never shows; `ChatInfoView.swift:357,746–753`
  the attachments count. `Screens/AddDeviceView.swift:164` `api.me()` for a
  username and display name that are in the session and the `user` table.

Clean: `ChatList/*` (database observation + `typingStream`), `Call/*`,
`Chat/ReadBySheet`, `Chat/ChatCalendarView`, `Shader/ShaderSurfaces` (once,
under `guard !loaded`), `ChatSearchModel` (a debounce, not a poll), the
extensions.

## Cloudflare limits (rule 6)

All seven object classes are SQLite-backed (`wrangler.jsonc:17–22`): a KV
value may reach ~2 MB, and the 128-keys-per-`put`/`delete` cap applies.
`setInterval` and `waitUntil` are not used anywhere.

Critical — a reachable input breaks it today:

- `UserDO.ts:640–645`: `/event` on a `chat` frame writes one `name:<id>` per
  roster member in a single `storage.put(names)`. A roster of 129 throws;
  `/event` answers 500; `fanoutRetryable("chat")` is true, so the delivery
  record retries every 10 s forever for every recipient, and the roster
  never lands for anyone. Fix: chunk at 128 as `putBatched` (1615–1622)
  does. — D1.
- `UserDO.ts:542–562` `unrelate`: 64 peers per pass but up to four keys per
  peer in `del`, deleted in one call at 561. From 32 peers losing their last
  link (a removal from a group, `/chat-removed`, `/peers-changed`) the delete
  throws. Fix: chunk `del` at 128 independently of the peer slice. — D2.
- `ConversationDO.ts:1262–1285` `/delete`: `b.seqs` is client-supplied with
  no cap on length (`index.ts:993` filters values only); one `storage.get`
  per seq, then `put(updates)` and `put(marks)` whole. 129+ messages deleted
  for all throws and deletes nothing; 10k seqs is 10k serial reads. Also
  `1161–1162` spreads the client array into `Math.max` (a RangeError near
  100k). Fix: cap `seqs` in the Worker, chunk the puts. — D3.
- `ConversationDO.ts:414–422` `kickPumps`: each recipient's pump gets its own
  `{ left: FANOUT_BUDGET }` (800); the alarm path (667–674) shares one
  budget correctly. A group of ~1000 makes one `/send` issue ≥1000
  `stub.fetch` in one invocation — "Too many subrequests" — and delivery
  falls back to the watchdog. Fix: one budget per invocation as in the
  alarm. — D4.
- `UserDO.ts:1638–1663` `totalUnread` (above): 1000 chats × 10 jobs per alarm
  breaks the subrequest cap and the 30 s alarm CPU, with the object blocked.
- `UserDO.ts:480–513, 371–395` presence fan-out: `PRESENCE_FAN = 20` bounds
  concurrency only; `visibleSubscribers` does a serial `storage.get` per id
  and, for the `contacts` tier, `blockPair` + `mayView` → a fetch into
  another object per candidate. N≈500 subscribers hits 1000 on every flip
  (`ping` transitions, `bg`, `fg`, `webSocketClose`). Fix: a per-invocation
  budget and a local cache of peers' phone hashes.
- `UserDO.ts:1567–1576, 1597–1606` `/profile-changed`,
  `broadcastDevicesChanged`: `Promise.allSettled` over `chatIds()` plus
  `pushCards(subscribers())`. 1000 chats hits the cap; the devices bump runs
  on link, `/keys-update`, `/keys-republish`, `/revoke-device`. Fix: a
  budgeted queue like the push queue.
- `index.ts:874–880, 897` `/api/chats` and `index.ts:1382–1408`
  `/api/contacts/discover` (above): the Worker invocation cap.
- `ConversationDO.ts:841–882` `notifyUserDOsChatList`: `staying` is capped by
  `PRESENCE_GROUP_MAX = 100`, the added/removed list is not; `/create` calls
  it with the whole roster and `index.ts:836–837` does not cap `memberIds`
  (`addableToGroup` at 817–831 also runs `privacyAllows` serially per id).
  Fix: cap `memberIds`/`add` in the Worker, chunk the fan.
- `ConversationDO.ts:801–834` `cards()`: reads chunked at 128, but
  `Promise.all(missing)` is one stub per missing card; the first `/state` of
  a big channel is 1000+ subrequests. Fix: budget, finish on the next call.
- `ConversationDO.ts:1445–1471` `/search`: pages of 128 backwards through the
  whole journal until `limit` hits; a query with no hits in a 1M channel is
  8000 listings in one invocation, 30 s CPU, the object blocked for every
  post. Fix: cap scanned pages, return a cursor.
- `ConversationDO.ts:758–780, 391–408` the `chat` frame carries the whole
  roster and both mark maps, stored as a `DeliveryRecord` per recipient. At
  ~3500 members the frame passes 1 MiB and `ws.send` throws — swallowed by
  `UserDO.send:281`'s empty `catch`, so the roster silently never arrives; at
  ~7000 the record passes 2 MB and the `put` fails; and the write is O(N²)
  bytes per roster change. Channels are open to this (invite join,
  `index.ts:1270–1281`, uncapped). Fix: the roster by pages on its own
  endpoint, the frame carrying a delta.

Medium:

- `ConversationDO.ts:295–301` `sweepCmids` lists `cmid:` with no limit (the
  512 applies to `doomed` only): memory and a stall inside `/send`.
- `ConversationDO.ts:612–639` `drainDeferred`: no limit, no budget; N deferred
  messages maturing together run N journal writes with two fan-outs each
  in one alarm.
- `ConversationDO.ts:1051–1054` `/events` lists every `tomb:` (and `markMap`
  ×2 at 254–261) with no limit; `UserDO.sendChatTail:1915` then sends one
  frame per tombstone.
- `ConversationDO.ts:905–908, 914–928` `roomTicket:` list without limit,
  `delete(expired)` and `delete(done)` unchunked, `Promise.allSettled(jobs)`
  of `removeParticipant` unbounded.
- `UserDO.ts:2112–2127` `sync` (above).
- `UserDO.ts:908–935` `/account-wipe`: three unlimited lists, then `tell
  ("/peer-gone")` to every related account, concurrency 20, total unbounded.
- `index.ts:517–534` `/api/account/delete` and `946–966` `/api/dev/relink`
  (two fetches per chat, open to any authenticated user).
- `UserDO.ts` `/stories-inbox`: the list is now capped at 2000 and the
  seen/like right is one `get` (`/story-has`); `StoriesDO.enqueue` still
  inserts one row per recipient with no cap on recipients (the Worker hands
  over every direct peer). 10k peers is 10k inserts in one invocation.
- `UserDO.ts:828–838` `/chats`: lists everything and, for every chat with an
  expired mute, reads and writes in the loop.
- `push/apns.ts:35–41`: one global `ApnsTokenDO("apns-jwt")` on the path of
  every push of the whole installation — a serial ceiling on push
  throughput and +1 subrequest per push. Fix: cache the JWT in the `UserDO`
  with a TTL, or shard the issuer.
- `push/apns.ts:161, 225–247`: `sleep` up to 1.5 s inside the alarm (above).
- `do/DirectoryDO.ts:10, 191–202`: four fixed shards hold every card and
  phone hash, `/api/users` hits all four per search, `LIKE '%q%'` scans the
  shard. A QPS ceiling for search across the installation. Fix: more shards
  and an FTS index.
- `ConversationDO.ts:1327, 1353–1357` `/members`: one `put` per added member
  in a loop, `Promise.allSettled` of `notify-plain` per invitee, no cap.
- `index.ts:1284–1293` `/api/media`: streams to R2 with no size check; the
  platform refuses at 100 MB with an opaque error.

Guards that already exist and are the pattern to copy: chunking at 128
(`UserDO.putBatched:1615–1622`; `UserDO.ts:1006–1008, 1185–1187, 1210–1217,
797–800`; `ConversationDO.ts:399–404, 302–303, 844–845, 805–813, 274–279`);
a budget per invocation (`FANOUT_BUDGET` in `drainAlarm:667–674`,
`PUSH_DRAIN = 10` with re-arm, `StoriesDO` `DRAIN = 50`); `limit` on `list`
(`ConversationDO.ts:477–480, 668–671, 711–714, 1020`; `UserDO.ts:1691–1694`);
caps on input (`index.ts:659, 1399, 1069, 1469, 1597`; `UserDO.ts:1055, 1075,
1189, 2091, 66`); the catch-up with three ceilings at once
(`SYNC_PAGE/SYNC_BUDGET/SYNC_CHATS`, `serveCatchup:1831–1896`); one alarm per
object done right (`shouldArmAlarm` + `alarmRunning`/`rearmDelay` in all
three objects); the APNs 4096-byte degradation (`apns.ts:83, 143–145`);
`PRESENCE_GROUP_MAX = 100` as the one explicit n² ceiling; phone lookups in
`IN (...)` batches of 200 (`DirectoryDO.ts:99–105`).

## What already does it right

`ConversationDO.enqueueFanout` + `pumpUser` + `drainAlarm` (a storage row
before the answer, a pump off the critical path, backoff, a watchdog alarm,
`fanoutRetryable`, order per recipient kept); `UserDO.enqueuePush` +
`drainPushes` (`pushed[]` so a retry reaches only the devices still owed, a
dead token cleaned on 410); `ConversationDO.cards` and `UserDO /peer-card`
(pushed copies read locally); `broadcastProfile` and the `profile` frame
carrying the whole row; `/revoke-device` as one act; `HandleDO`/`LookupDO`
(uniqueness by object address); `drainDeferred` on its own deadline. On the
client: the outbox and action queues woken by continuations
(`SyncEngine.swift:110–121`), the catch-up on connect (325–346, 455–516),
frame coalescing (393–410, 760), `scheduleNextExpiry`/`scheduleNextSend`,
`E2EE.deviceMap` (one `/devices` call for all misses, invalidated by the
connect event), `MediaManager.fetch` with its inflight map, and every list
served from SQLite by observation.

## Tasks

Architectural work, each one behaviour, in the order the owner's rule
suggests: first stop losing writes, then stop asking, then stop polling.

- T1. Server: a durable queue for every cross-object side effect that today
  is `Promise.allSettled` + `console.warn` or unawaited: `notifyUserDOsChatList`,
  the "added to a group" push, `/profile-changed`, `broadcastDevicesChanged`,
  `tell` for `/peer-card` and `/peer-gone`, `/block-changed`, `/chat-accepted`,
  `leaveRooms`, `indexUser`, the second `phoneIndexPut`. One shared shape
  (`DeliveryRecord` rows, a pump, one alarm, a budget), reused.
- T2. Server: durable jobs for `POST /api/account/delete` and
  `POST /api/username` (with compensation).
- T3. Server: frames to the user's own other devices for `/flags`,
  notify-sounds, privacy, privacy exceptions, block, direct chat delete; and
  a frame to contacts on `POST /api/phone`.
- T4. Server: mute expiry and story expiry on alarms, with the frame that
  says so (`chat` flags / story `removed`); delete expired stories, views
  and likes in the author's object.
- T5. Server: `GET /api/chats` from a per-chat state kept in the `UserDO`,
  paged; `cardsFor` replaced by pushed copies; a card in every frame that
  introduces an unknown user.
- T6. Server: the badge as an increment carried by the `msg` frame and
  summed in the `UserDO`; `totalUnread` gone from the push path.
- T7. Server: per-member `readReceipts`/`typing` copied into the chat next to
  the card; `membersWithFlagOff` reads locally.
- T8. Server: the discovery tier stored in the phone index; `discover`
  answers filtered and capped.
- T9. Server: a held request (or a socket) on the provisioning session
  released by `/approve`; `GET /api/provision/:id` stops being a poll.
- T10. Server, limits: one fan-out budget per invocation in `kickPumps`;
  chunk every remaining `put`/`delete` (`/event` names, `unrelate`,
  `/delete`, room tickets, `/members`); caps on `seqs`, `memberIds`/`add`,
  discover matches, story recipients; `limit` on every `list` (`cmid:`,
  `defer:`, `tomb:`, `roomTicket:`, `story:` done); budgets for
  `visibleSubscribers`, `cards()`, `/search` (with a cursor), `sync`'s
  per-chat `/state`, `/account-wipe`, `/dev/relink`.
- T11. Server, limits: the roster out of the `chat` frame — a paged roster
  endpoint, the frame carries a delta; a cap on channel size until then.
- T12. Server, limits: the APNs JWT cached per `UserDO` with a TTL (or the
  issuer sharded); no `sleep` inside `sendPush`, the queue sets `nextAt`.
- T13. Server, limits: `DirectoryDO` with more shards and an FTS index; a
  size check on `/api/media` before the stream.
- T14. Core: the 30-second maintenance loop replaced by deadlines and
  events — mutes on an alarm, the unreadable queue replayed on the arrival
  that could unblock it plus one alarm at the earliest backoff,
  `republishPrekeysIfDue` only from `recordUnreadable`, `announce` awaiting
  the ack.
- T15. Core: presence and cards in the sync answer; `refreshPresence`,
  `refreshPeerCanCall`, the per-user `GET /users/{id}` fan and
  `refreshSnapshot`-after-write gone; a batched users read for what is left.
- T16. Core: the socket watchdog armed to the next threshold instead of 1 Hz;
  `CryptoGate` waiting on the lock rather than spinning.
- T17. App: account state (sessions, blocked, notification sounds, privacy,
  exceptions, bots, chat flags) in local tables fed by the connect snapshot
  and frames; every settings screen reads the database, no `load()` after
  an action, no pull-to-refresh.
- T18. App: `ChatInfoView` from one prepared read; `ChatGalleryView` and the
  attachments count observed; the busy-waits replaced by awaited streams
  (`waitForPeerId`, `feedContains`, `ensureLoaded`, `isAtDeviceStart`, the
  `engine` wait in `NotificationCoordinator`); `LinkDeviceView` on the
  provisioning event from T9.
- T19. Smoke and MsngrTests for each of the above: a frame asserted for every
  write, a 129-member roster, a 129-seq delete, a 32-peer unrelate, a
  1000-recipient fan-out on one budget.
- T20. Server: every right a peer grants me — avatar and last-seen
  visibility, phone discovery, calls, read receipts, typing, blocks — as a
  copy in my `UserDO` (and in the chat's object where the chat needs it),
  written by a queued fan-out from the owner on every change; `privacyAllows`,
  `mayView`, `peerPhoneHash`, `blockedPair` against a peer's object leave the
  read and check paths. The second line stays at the write destination: the
  owner's object refuses by its own copy what a stale peer copy let through.
- T21. Server: profiles and avatars the same way — the card and the avatar id
  as copies pushed to every peer and chat by queue (`/peer-card` made
  durable, `cardsFor` gone), so a list, a viewer or a push names a person
  from the reader's own object.
- T22. Server: a new direct chat after a story was published — decide whether
  the author's object hands the new peer its live stories (the recipients
  are named at publishing today, as Instagram does it). A product call for
  the owner, recorded here so it is not made by accident.

Costs accepted with rule 7, written down so nobody rediscovers them: a
permission change is eventually consistent (a copy lags by the queue's
latency, longer under backoff), which is why the write destination keeps
its own check; and a change by someone with many peers is that many
deliveries, which is why every fan is a budgeted queue and never a
`Promise.all`.

## Defects

Broken today for an input a user can produce. Also listed in
`docs/qa/defects.md`.

- D1. A group or channel of 129+ members: the roster's names never reach any
  member and the fan-out queue retries forever (`UserDO.ts:640–645`).
- D2. Losing the last shared chat with 32+ peers at once throws in
  `unrelate`; the peer links are left half-cleaned (`UserDO.ts:542–562`).
- D3. Deleting 129+ messages for all fails whole and deletes nothing
  (`ConversationDO.ts:1262–1285`).
- D4. A send in a group of ~1000 exceeds the subrequest cap in one
  invocation; delivery degrades to the watchdog (`ConversationDO.ts:414–422`).
- D5. A lost `devices` bump keeps peers encrypting to a revoked device; the
  failure is a log line (`UserDO.ts:1597–1606`).
- D6. A member added to a chat can be missing from their `GET /api/chats`
  for good while the chat shows on their screen (`notifyUserDOsChatList`).
- D7. Pin/mute/archive/sound, privacy, block, and a direct chat's deletion do
  not reach the user's other devices.
- D8. A roster frame over 1 MiB is dropped by `ws.send` inside an empty
  `catch` (`UserDO.send:281`): the member never sees the roster and nothing
  says so.
- D9. `LinkDeviceView.swift:145` counts down 2 s per 1.5 s of waiting: the
  linking code is declared expired about a third early.
- D10. The chat gallery does not observe: an attachment arriving while it is
  open never appears until it is reopened (`ChatGalleryView.swift:115–118`).
- D11. A story taken down before this change stayed on every viewer's screen
  until the next minute's poll; a like or a watch never reached the author's
  screen without a reload. Fixed in this change; recorded for the run
  report.
