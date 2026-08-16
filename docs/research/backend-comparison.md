# The msngr backend compared with the reference

The reference is proprietary BIG code, rights held by k2fintech; only principles
are described here, copying code is forbidden.

The reference: one core worker on Cloudflare Workers (401 TS files, ~75k lines,
1145 commits, the last one September 2025) plus four external workers. Our
`server/src` is 1606 lines and two Durable Objects.

What follows goes topic by topic: how it is solved there, how it is with us,
what follows from that. A prioritised list closes the document.

---

## 1. Splitting into services

**How it is there.** Core holds the state: per-user DOs, D1, WebSocket
connections. Moved outside are calls (`CALLS`), channels (`CHANNELS`), money
(`MONEY`, `MONEY_SERVICE`), video transcoding and the receiving of delivery
receipts. They talk over service bindings and `WorkerEntrypoint` classes in the
core root (`CallsEntrypoint`, `ChannelsEntrypoint`, `MoneyEntrypoint`,
`VideoEntrypoint`, `DeliveringEnterypoint`). Those classes carry no logic; they
are adapters from an RPC call to the right DO stub, so that an external worker
needs to know neither the chatId scheme nor the names of the DO bindings.

The boundary follows a single rule: anything that is not conversation state
lives outside. A call is signalling with a short life cycle, and core has no use
for its state. A channel with tens of thousands of subscribers is a different
distribution model (a batch of recipients instead of per-object fan-out), and it
would force ordinary chats to share limits with it.

The most interesting device: the chat resolution function returns either a local
DO stub (dialog, group, AI) or an RPC stub of an external worker (channel),
because their method nomenclature is compatible. The calling code does not know
where the chat physically lives. Chat type is derived from the length of the id,
so routing needs no database lookup.

`back-delivering-listener` stands apart: a tiny worker on its own domain with no
authorization. The push payload carries an encrypted URL of the form
`userId.chatId.messageId`; the Notification Service Extension on the device
calls it before showing the notification, the worker decrypts it and marks the
message delivered over RPC. That way the receipt appears even when the app is
not running and there is no socket.

**How it is with us.** One worker, everything inside. No split, no RPC outward.

**Conclusion.** There is no reason to split now: the feature volume is smaller by
a wide margin, and a cross-worker call is extra latency and one more way to
break. Two consequences do apply already.

First: `ARCHITECTURE.md` describes channels as chats without E2EE, with
server-side history and search, which is exactly the entity the reference had to
move outside. Worth keeping chat resolution behind a single function returning a
stub from the start, so that moving channels into a separate worker is an edit
to one function rather than a rewrite.

Second: the NSE receipt trick solves a concrete problem of ours. Right now
`delivered` is set only by the `recv` WS frame, that is, only while the app is
open. We already have a push with `mutable-content: 1` and an NSE; what is
missing is an endpoint for the NSE to call.

---

## 2. Durable Objects

**How it is there.** Fourteen DO bindings. The split is not by hot versus cold
but by identity versus state.

D1 holds only what has to be globally queryable: users, phone numbers, contacts,
the registry of public groups, the sticker catalogue, reserved usernames. Seven
tables, nineteen migrations. There is no message table in D1 at all.

Everything else is in DOs, and the key is chosen so that a DO is the lock and
the transaction boundary for its entity: writing a message touches exactly one
chat and has to be serialised against concurrent writes to that same chat, while
a username uniqueness check touches a global index. The first is a DO, the
second is D1.

The second principle: per-user projections are duplicated rather than joined.
Dialog messages are stored once in `DialogsDO`, but each participant has their
own denormalised chat-list row in their `MessagingDO`. Nothing is joined on
read, everything is spread out on write. Hence the amount of code devoted to
propagating events between DOs.

Boundaries worth holding on to:

- **Push retries are moved into a separate `MessageStatusTrackerDO` per user**,
  because the retry ladder has to run on alarms while the socket DO is
  hibernated, and it must not compete with live traffic for the object's single
  thread.
- **Privacy is moved into `PrivacyDO`**, because it is read by *other* objects
  deciding what to show; waking the owner's socket DO for that is a bad trade.
- **X3DH keys live in `KeysDO` on SQLite**, because handing out a one-time
  prekey has to be atomic: two parallel session setups must not get the same
  key.
- **The APNs JWT is in a singleton DO**, because Apple rate-limits token
  generation and minting must have exactly one owner.
- **`PhoneNumberDO` keyed by phone number** as the meeting point for contact
  matching: A uploaded B's number, B uploaded A's number, and the match is
  recorded in the number's object.

A weak spot of the reference that is worth not repeating: a DO has one alarm
slot. Both chat DOs inherit a shared task scheduler but override `alarm()` with
their own implementation, so tasks scheduled inside them will never run. On top
of that, the table schema inside SQLite DOs is migrated by introspection
(`PRAGMA table_list`, then create-or-alter) with no version counter, on every
cold start of the object.

**How it is with us.** Two DOs. `UserSessionDO` combines sockets, presence, the
chat list, APNs tokens, the unread cache and push sending. `ConversationDO`
handles membership, the log, marks, settings and the pin. Storage is the
key-value API, even though the classes are declared as `new_sqlite_classes`; SQL
is not used. The single alarm of `UserSessionDO` is taken by the presence TTL.
The alarm of `ConversationDO` is free, although `ARCHITECTURE.md` describes an
alarm-driven delivery queue as a decided matter; there is no such queue in the
code.

**Conclusion.** A split into fourteen objects matches fourteen product
subsystems, not our two, so their structure should not be copied. But two
specific seams already hurt.

The push lives inside the `/event` handler in `UserSessionDO`. Which means: if
the fan-out subrequest to that DO did not go through, there will be neither a
frame nor a push; sending the push occupies the object's single thread, the one
all the user's sockets go through; and there is no retry at all.

The single alarm is already taken. Any second timer-driven job (delivery
retries, cleanup, deferred fan-out) will need a task dispatcher on top of that
one alarm slot: keys sorted by execution time, and the nearest one picked with a
single `list` using `limit: 1`. It is a cheap and well-tried device, and it is
better introduced before the second timer is needed rather than after.

---

## 3. Delivery and fanout

**How it is there.** Three different modes for three different load profiles.

*Dialog.* A direct RPC to the recipient's DO. The response carries a "delivered"
flag: if the recipient was online and the event went into the socket, the dialog
object marks it immediately and notifies the author. One network call closes
both delivery and the receipt.

*Group.* The fan-out is not synchronous. One record per participant goes into an
outbound queue, an alarm is armed at about 150 ms, one tick handles 3 to 4
events, and the alarm is rearmed until the queue is empty. Before processing,
the queue is collapsed: for every type except a new message, only the last event
per (type, recipient) pair survives. Sent items move into an in-flight set, and
anything sitting there longer than three seconds goes back for a retry. This
protects against the subrequest and CPU limits inside a single invocation:
fanning out to two hundred participants in one loop would hit them for certain.

*E2E dialog.* A genuinely persistent outbox: every event is written to storage
under the key `bufEvent::<chatId>::<messageId>`, and the cursor is a separate key
with status `ack` or `pending`. An online client gets up to 50 events in one
batch frame, after which the server stays silent on that chat until the client
confirms decryption. Only then does the cursor move and the next portion go out.
This protects against more than loss on a disconnect: in a ratchet chain, a
later message overtaking an earlier one breaks decryption.

There is also a continuity check: the client sends the id it believes is the
last, the server compares it with its own counter and on a mismatch returns a
negative code, meaning "your view of the chat has diverged from mine, re-encrypt".

Idempotency is keyed on the client message id, but the lookup runs over an array
held in memory, so the dedup window is bounded.

Resync after being offline, for ordinary chats, is a pull: the client asks for
the list of chats with `lastMessageId` for each, diffs it against its own state
and fetches what is missing page by page. The server replays nothing on its own.

The task scheduler: keys `$$_tasks::<ULID>`, where the ULID is encoded from the
execution time, so lexicographic key order coincides with chronological order.
An optional dedup key collapses repeated scheduling into a single pending task;
without it every incoming event would spawn its own timer. There is no attempt
cap and no dead letter, an acknowledged hole: a deterministically failing task is
retried forever.

Queues are declared as producer only and used as an emergency fallback if the
direct call to the push service threw. Workflows are used only for deferred AI
tasks, where `step.sleep` has to span weeks and survive a redeploy.

**How it is with us.** `ConversationDO.fanout` is a `Promise.all` over all
participants with `.catch(() => {})`, right inside the `/send` handler, before
the sender gets a response. Twice: first everyone except the author, then the
author in a separate call.

What follows from that, per the code:

- A failed subrequest is a silently lost frame. For `msg` the client resync saves
  it (the log in the DO is the source of truth); for `receipt`, `typing`,
  `presence` and `chat` there is no recovery whatsoever.
- The sender waits for the whole fan-out. The bigger the group, the slower the
  ack.
- Group size is hard-capped by the subrequest limit of a single invocation.
- `broadcastPresence` walks every chat of the user, and each `ConversationDO`
  then broadcasts to all its participants. That is O(chats × participants)
  subrequests per status change, and the alarm triggers it every 35 seconds.

The `sync` handler in `UserSessionDO` deserves its own paragraph. It goes
sequentially over all chats, in a loop with no bound, pulling history in batches
of 200 and sending frames, and after each chat it requests `/events`. While that
runs, the single DO thread is busy: events from every other sender to this user
queue up behind it. The client's cursor moves only as frames are applied, so a
sync interrupted halfway starts over from the same point. A client with a large
history can get stuck in a resync loop.

`/delete` in `ConversationDO` walks the entire chat log with the `msg:` prefix to
find the messages it has to tombstone. `/events` used to do the same on every
sync for every chat; it now reads the `tomb:` records instead.

A small thing, but worth reconciling: `ARCHITECTURE.md` fixes the batch ceiling
at 128 keys, while `/history` and the `sync` loop work with 200. Reads currently
go through a ranged `list`, to which that ceiling does not apply, but two
different numbers for the same meaning will diverge sooner or later.

Our idempotency is better: `cmid:<from>/<clientMsgId>` is a durable key in
storage, and the dedup does not depend on what is held in memory.

**Conclusion.** The main structural gap is that history replay is implemented as
a push from the socket handler instead of a pull by cursor. The reference is
simpler and more reliable here: the server hands out the chat list with the last
seq, and the client fetches pages itself over HTTP, which we already have
(`/api/chats/:id/history`). The `sync` frame then shrinks to a digest and stops
blocking the DO.

The second gap is the absence of a persistent event queue. Collapsing by (type,
recipient) and processing in portions on an alarm is exactly what our own
`ARCHITECTURE.md` describes for channels, and what is not written.

---

## 4. Pushes

**How it is there.**

- Device tokens live in a separate DO keyed by device fingerprint, and the same
  object is also addressable by the token value. A second after the write, a
  reconciliation of the token ↔ fingerprint ↔ user chain is scheduled; if the
  token previously belonged to another triple, it is cleaned out of the old one.
  This guards against app reinstall and account switching on the same device,
  where someone else's notifications would keep arriving.
- Alert pushes go to one token per user, an acknowledged asymmetry: sockets are
  multi-device, pushes are not.
- The badge is the total unread across all chats at the moment of sending.
- `apns-collapse-id` is the client message id, otherwise eight retries would give
  eight banners.
- The payload carries a per-chat sequence number, persisted on the server, so the
  client can detect a missed push.
- For E2E dialogs the alert text is replaced with a neutral string.
- The ES256 JWT belongs to a singleton DO: cached in storage, refreshed by a
  recurring task every six minutes, force-invalidated on an error and on the
  second attempt. The reason is direct: Apple's token lives up to an hour, but
  generating it too often yields a 429. Next to it sits the variant with the
  cache in a module variable, which is weaker, because a cold start of the
  isolate regenerates the token.
- Retries are a separate DO per user, on a ladder of 5s → 10s → 20s → 40s → 60s →
  2m → 5m → 10m, after which the record is deleted. It is cancelled by the
  delivery receipt, from any source: the socket, a catch-up pass, or the
  confirmation worker called from the NSE. A read on another device neither
  cancels pushes nor withdraws an already shown notification.
- Mute is not checked on the server: the flag simply travels to the client, so a
  muted chat still produces an APNs request and still lands in the badge.

**How it is with us.** The push goes out immediately for every content message,
regardless of sockets; the client suppresses the duplicate by `chatId`/`msgId`.
Tokens: all of the user's devices. Mute is checked on the server and suppresses
the push. `apns-collapse-id` is `msgId`. The badge is a lazy recount of
invalidated chats via subrequests to `ConversationDO` at send time.

What is not done:

- No retry. `sendPush(...).catch(() => {})`, one attempt, and the result goes
  nowhere.
- The APNs response is not parsed. `410 Unregistered` does not delete the token:
  dead tokens accumulate forever and burn a subrequest every time.
- The JWT sits in a module variable of the worker, the very weak variant the
  reference replaced with a singleton. Regeneration on every cold start of the
  isolate. How often this actually runs into Apple's limit I did not measure;
  that part is a hypothesis, while the single-owner pattern for the token is a
  known solution.
- The badge costs O(invalidated chats) subrequests inside the push path.
- There is no receipt from the NSE (see section 1).

**Conclusion.** Pushes to all devices and server-side mute are better on our
side. Three things are missing, each of them cheap: parsing the APNs response
and deleting dead tokens, a retry cancelled by the receipt, and an owner for the
JWT with the cache in storage instead of an isolate variable.

---

## 5. Data schema

**How it is there.** D1 has seven tables and nineteen migrations with a numeric
prefix, applied by the standard `wrangler d1 migrations apply`; the config sets
`migrations_dir` and `migrations_table`. There is no home-grown runner.

Inside DOs, SQLite is enabled only for keys and stories. The schema of those
tables evolves by introspection in code, without a version, which is the weakest
part of their design. The remaining DOs are key-value with tolerant reads (new
key, fallback to the old one) instead of migrations.

What they have on the server and we do not:

- **Privacy**: nine options (phone, username, online, avatar, forwarding, calls,
  voice messages, messages, invitations) on a five-level scale from "nobody" to
  "everyone". With us, presence and lastSeen are visible to every participant of
  a shared chat, with no setting.
- **Pins**: up to three, with a TTL. We have one `pinnedMsgId`.
- **Mentions**: an event and fields in the chat-list row. We have none.
- **Invite links**: TTL, use limit, approval requirement, counter. We have a code
  with no expiry, no limit, no revocation, creatable by any participant.
- **Auto-deletion in groups**: a setting in days and a mark on the message. Our
  TTL lives on the client only: the server never deletes ciphertext.
- **Roles and admin rights**: separate flags (edit the group, invite, appoint
  admins, payments). We have a boolean admin.
- **Reports**: primitive, but present.
- Plus stories, stickers, subscriptions, paid chats, AI chats, collections, which
  are product features outside our perimeter.

Neither they nor we have drafts or full-text search.

**How it is with us.** One `schema.sql` with seven tables, and no migration
mechanism at all: no directory, no `migrations_dir` in `wrangler.jsonc`. There is
nowhere to put the first `ALTER TABLE` in production.

Reactions, edits and TTL toggling are implemented as service E2E messages with
the `service` flag. Under end-to-end encryption that is the only honest option
and it is the right one, but it has a price: every reaction takes a `seq` and
stays in the chat log forever.

Blocks live in D1 and are checked only when a direct chat is created. Inside an
existing chat a blocked user writes freely and gets receipts: `/send` only looks
at membership.

The device token is a SHA-256 in D1 with no expiry. There is no logout, no
revocation, no device list, no lifetime.

There is no server-side cleanup of any kind: tombstones and dedup keys pile up in
the DOs, orphaned blobs in R2 are never collected, and the `media` registry only
grows.

**Conclusion.** The absence of D1 migrations is not a matter of style but a dead
end at the very first schema change; it is fixed by one config edit and moving
`schema.sql` into a numbered file. Blocks that do not apply inside a chat are a
straight hole in what the feature promises. Presence privacy and admin rights are
product gaps rather than architectural ones, but both are cheaper to do before
the `chat` frame format sets in the clients.

---

## 6. Operations

**How it is there.** Four configs (dev, stage, pp, prod) with different D1, R2,
queues, routes and APNs topics. `logpush` and `[observability]` are on
everywhere, and there is a tail consumer, a separate worker receiving traces of
all requests. `[placement] mode = "off"`, because the state is in DOs anyway, and
stubs are taken with a `locationHint` to Western Europe: the whole messaging
plane is pinned to one region to take cross-region RTT out of the sender → chat →
recipient chain. The price is permanent latency for non-European clients.

The weak spots are worth naming honestly, because they should not be copied.
`deploy.sh` is seven lines: tmux with two panes, `wrangler deploy` for core and
for calls. It applies no migrations, pushes no secrets, checks no types, runs no
tests and does not look at the exit code. DO migration tags have drifted apart
between environments: dev is on v92, stage sits on a ladder of v74 to v86, pp was
recreated from scratch, prod is on v1 to v2, and the same DO class is declared
with a SQLite backend in three environments and a regular one in prod. There is
no single command to reproduce prod on stage.

Tests: 33 spec files, about 25 thousand lines, of which 15 thousand are one load
scenario with a single `it()`. These are not unit tests but E2E scripts against a
live dev backend with real registration on test numbers. They are not idempotent,
they depend on the backend being up, and DO logic is not tested directly.
`vitest-pool-workers` and miniflare are not wired in. The only isolated unit test
covers the ULID generator. There is no CI, neither GitHub Actions nor anything
else. ESLint is noticeably relaxed (`no-console` off, `no-explicit-any` off,
unused variables at warn), and `typecheck` is not called from any script.

**How it is with us.** One `wrangler.jsonc` with
`database_id: "REPLACE_ON_DEPLOY"`, which means environments do not exist as a
concept. No
`[observability]`, no logpush, no tail, so we will see nothing in production. No
`locationHint`. Deployment is `wrangler deploy` from an npm script.

Tests: `server/test/smoke.mjs` is 390 lines with about sixty checks, an
end-to-end run of the protocol against a local `wrangler dev`, covering WS
frames, idempotency, message requests, invites, sync beyond a single batch and
pushes through the APNs mock. It is part of `make check` as the gate before a
commit.

**Conclusion.** Here we are better on discipline and worse on coverage. One
deterministic smoke test in the commit gate is more useful than twenty-five
thousand lines of non-idempotent scripts against a shared backend: running those
changes the backend's state and does not reproduce. What should grow is the smoke
test, not a second, "real" layer of tests.

Worth taking: environments with separate D1 and APNs topics (otherwise the first
real user ends up in the same database as the test runs), `[observability]` and
logpush (otherwise diagnostics in production are impossible), and `locationHint`
for DO stubs. Not worth taking: `deploy.sh` as it stands, and migration tags
drifting apart between environments.

---

## 7. Errors, middleware, validation

**How it is there.** The router is `@cloudflare/itty-router-openapi`. Every
handler is a class with a static Zod schema: path parameters, query and body are
validated before the handler runs, and what arrives inside is already parsed and
typed. The base class overrides the validation error handler, flattening Zod
issues into one string and returning 400 in the same JSON format as application
errors. Responses are not validated against the schema, only described. OpenAPI
is assembled at runtime from those same schemas; the snapshot committed to the
repository is updated by hand.

The order of route registration carries meaning: the line with the authorization
middleware divides the file into a public and a private half. Debug endpoints are
registered bypassing the OpenAPI wrapper and hidden behind long random prefixes,
and some of them live in production too.

Authorization: JWT HS256, an access token lifetime of 300 days, signature
verification with no database lookup at all. The direct consequence: a token
cannot be revoked, and logout does not invalidate it. The refresh token is not a
JWT but a string with the userId baked in, so the right DO can be found without a
database query; rotation lives in a separate DO, one active refresh per user. The
WebSocket upgrade is authorized by the same `Authorization` header, which shuts
out browser clients and clearly assumes native apps. The middleware writes user
data straight into the `env` object, an "env as request context" pattern best
given a wide berth.

Error handling is weaker than one might expect: three exception classes, no
machine-readable codes, no global error boundary, and the HTTP status field
inside the exception is used in three handlers out of more than two hundred. The
practical consequence: a "not found" from deep inside usually reaches the client
as a 500. Logging is `console.log`, there is no Sentry, and observability rests
entirely on platform logpush and tail.

**How it is with us.** Hono, with authorization in a single `app.use("/api/*")`,
so the boundary is explicit and reads better than the position of a line in a
file. The error format `{ok:false, error:"code"}` with string codes is
machine-readable, unlike their human-readable messages.

What is missing: input validation, entirely. Bodies are read as
`c.req.json<T>()`, which is a type assertion, not a check. There are no length
limits anywhere: `displayName`, `bio`, `title`, `description`, the size of an
uploaded blob, all taken as they come. `/api/chats/:id/settings` forwards the
whole body into the DO. `app.onError` is not set, so an uncaught exception hands
the client an opaque 500 that is not in our format. Registration is open:
`/api/register` writes to D1 with no barrier of any kind and no verification.
There is no OpenAPI.

**Conclusion.** Exactly one thing is worth taking from this topic: schema
validation of bodies at the entrance, before the handler, with a single error
format. Our error handling and codes are already better, and OpenAPI does not yet
pay for itself with a single client living in the same repository.

---

## What is worth changing

### Critical

1. **Move `sync` to pull.** Replay currently runs in the socket handler of
   `UserSessionDO`, blocking the object's single thread for all the user's other
   events, and a pass interrupted halfway starts over.
2. **A persistent event queue with retries.** `.catch(() => {})` in `fanout`
   means `receipt`, `typing`, `presence` and `chat` are lost silently and
   recovered by nothing.
3. **Lifetime and revocation for the device token.** The token never expires,
   there is no logout and no device list: a leaked token is valid forever and
   there is nothing to kill it with.
4. **D1 migrations.** `schema.sql` without `migrations_dir` leaves nowhere to put
   the first schema change in production.
5. **Blocking inside an existing chat.** The check exists only when a direct chat
   is created; in an open chat a blocked user writes freely.

### Important

6. **Remove the full log scan in `/delete`.** All `msg:` keys are walked to find
   the messages to tombstone; only `/events` has been taken off that path.
7. **Parse the APNs response.** `410 Unregistered` does not delete the token:
   dead tokens accumulate and burn a subrequest every time.
8. **Push retry cancelled by the delivery receipt.** Right now there is one
   attempt and the result is ignored.
9. **An owner for the APNs JWT instead of a module variable.** The cache in the
   isolate is recreated on every cold start, and Apple limits how often the token
   may be generated.
10. **Body validation and length limits** on all POSTs, plus `app.onError` for a
    single response format when an exception escapes.
11. **Environments and observability.** Separate D1 and APNs topics for dev and
    prod, `[observability]` and logpush: right now nothing is visible in
    production.
12. **A barrier on registration.** `/api/register` is open, so a script can create
    users and prekey bundles without limit.
13. **A delivery receipt from the NSE.** An endpoint the NSE calls before showing
    the banner; then `delivered` stops depending on whether the app is open.
14. **Server-side cleanup.** Tombstones, dedup keys, message TTL and orphaned R2
    blobs are never deleted today, and the promise of disappearing messages lives
    on the client only.
15. **A content reporting mechanism.** An App Review requirement for apps with
    user-generated content; we have blocking but no reports.

### Later

16. **A task dispatcher on top of the single alarm slot**, before a second timer
    is needed rather than after.
17. **A separate DO for push retries and the badge**, so they do not share a
    thread with the sockets.
18. **Presence and lastSeen privacy** as a user setting.
19. **Chat resolution behind a single function returning a stub**, so that moving
    channels into a separate worker is an edit to one function. The same is
    needed for the already accepted decision to move groups into their own
    Durable Object.
20. **`locationHint` for DO stubs**, to take cross-region RTT out of the delivery
    chain.
21. **Invites with TTL, a use limit and revocation**; separate admin rights
    instead of a boolean flag.
22. **Mentions** and a server-side sequence-break signal (`prevId`) as a
    safeguard for the ratchet on top of the client's `pendingDecrypt`.

### Where we are better or good enough, leave alone

- Send idempotency on the durable `cmid:` key is more reliable than a lookup over
  an in-memory array.
- Mute suppresses the push on the server; in the reference it only travels to the
  client and burns APNs anyway.
- The push goes to all of the user's devices, not just the last one.
- String error codes are machine-readable, unlike human-readable messages.
- The authorization boundary is set by path-prefix middleware, not by the
  position of a line in a file.
- Chat flags (pinned/muted/archived) instead of a folder system with reserved
  names is enough at our scale.
- A smoke test in the commit gate is more useful than non-idempotent E2E scripts
  against a shared backend; that is what should grow, rather than a second layer.
- Two DOs instead of fourteen match our feature volume. Splitting should happen
  for a concrete reason (pushes, channels), not for symmetry.

---

Our side was checked by reading all of `server/src` (1606 lines),
`docs/protocol.md` and `ARCHITECTURE.md`. The reference side was assembled by
four parallel passes over its repository; individual claims about its internals
are marked in the text wherever confidence is lower.
