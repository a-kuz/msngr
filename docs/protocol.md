# Protocol

The source of truth is the code: `server/src/index.ts` (the router),
`server/src/types.ts` (frames), `server/src/do/*.ts` (DO logic),
`ios/MsngrKit/Sources/MsngrCore/Protocol.swift` (the client mirror).

## Transport

- HTTP `/api/*` — registration, keys, profiles, chats, media, contacts, blocks.
- WS `/ws?token=…&v=…` — one socket per device, JSON frames `{t, ...}`.
  The upgrade is authorized in the Worker, the socket itself is held by
  `UserDO`.
  `v` is the client's protocol version, read before auth: below the server's
  floor the upgrade answers `426 client_too_old` with both numbers, and the
  client stops reconnecting instead of retrying into silence.
- Auth: a device token (`Authorization: Bearer <token>` or `?token=`), stored in
  D1 as the SHA-256 of the token. Signing in on a new device is not a password
  but the consent of a device that is already in the account:
  `/api/provision/*` (the "Signing in on a new device" section). Provisioning
  session keys travel in the `x-provision-token` header — a new device has no
  device token yet.
- Token revocation: `devices.revoked_at`. It is checked in the authorization
  middleware, so a revoked token gives 401 both on `/api/*` and on the `/ws`
  upgrade. Revocation cuts that device's live sockets (close code 4401), erases
  its APNs token, deletes its identity record and one-time prekeys from the
  user's `UserDO` and broadcasts a `devices` frame: peers drop their cached
  device list, so the next send no longer addresses the revoked device. A token has no lifetime: it works
  until it is revoked.
- Every client-visible timestamp is in seconds (`nowSec()` on the server,
  `timeIntervalSince1970` on the client).

## Identifiers

- `userId`, `deviceId`, `msgId` — ULID (own implementation in `server/src/util.ts`).
- `chatId`: a group is a ULID; a direct chat is the deterministic name
  `direct:<userIdA>:<userIdB>` with sorted ids, which is how a direct chat
  deduplicates without an index.
- `seq` — the monotonic number of a message inside a chat (1..N), assigned by
  `ConversationDO`.
- `clientMsgId` — the client's UUID, the idempotency key of a send. The dedup key
  on the server is `cmid:<from>/<clientMsgId>`; a repeat returns the original
  `msgId`/`seq`.

## HTTP API

Responses: `{ok:true, ...}` or `{ok:false, error}` with a non-2xx HTTP status.

```
POST /api/register    {username, displayName, device:{name}, identityKey, identitySignKey,
                       identityKeySig, signedPrekey:{id,key,sig},
                       oneTimePrekeys:[{id,key}], phoneHash?}
                      → {userId, deviceId, token}    (no auth; username [a-zA-Z0-9_]{3,32})
GET  /api/me                      → {user, deviceId}
GET  /api/sessions                → {sessions:[{deviceId,name,createdAt,lastSeen,hasPushToken,current}]}
POST /api/logout                  revoke the token of the current device
POST /api/sessions/:deviceId/revoke   revoke the token of another device of yours

POST /api/provision/start         {ephemeralKey, device:{name,platform}}   (no auth)
                                  → {provisionId, code, provisionToken, expiresIn}
GET  /api/provision/:id           (x-provision-token) → {status:"pending"|"approved", envelope?}
POST /api/provision/lookup        {code} → {provisionId, ephemeralKey, device, expiresIn}
POST /api/provision/:id/approve   {envelope} — consent from a device already in the account
POST /api/provision/:id/claim     (x-provision-token) {identityKey, identitySignKey,
                                  identityKeySig, signedPrekey, oneTimePrekeys, device:{name}}
                                  → {userId, deviceId, token}
POST /api/provision/:id/cancel    (x-provision-token)
GET  /api/users?q=                search by username/displayName (LOWER LIKE, limit 20)
GET  /api/users/:id               → {user, presence:{online,lastSeen}}
GET  /api/devices?ids=a,b,c       devices and identity keys, plus versions:{userId:
                                  version}; each user's list and version are one
                                  snapshot from that user's object; spends nothing
GET  /api/users/:id/prekeys       X3DH bundles of every device; a one-time prekey is handed out and deleted
GET  /api/prekeys/count           how many of your own one-time prekeys are left
POST /api/prekeys                 {oneTimePrekeys:[{id,key}]} — a top-up (up to 200 at a time)
POST /api/profile                 {displayName?, bio?, avatarId?}
POST /api/avatar                  raw body (image/jpeg) → {avatarId};  GET /api/avatar/:id
                                  ?chatId=<id> — the chat's avatar instead of your own profile
POST /api/chats                   {kind:"direct"|"group"|"self", memberIds[], title?} → {chatId}
                                  "self" is the chat with yourself: memberIds is empty, the
                                  id is `self:<userId>`, so the call is idempotent and every
                                  user has exactly one; its messages raise no push
GET  /api/chats                   snapshot: [{flags, state}] + the profiles of all members
GET  /api/chats/:id/history       ?fromSeq=&toSeq=&limit=&dir=back
                                  → {msgs:[StoredMsg], scanned, lastScannedSeq}
POST /api/chats/:id/recv          {seqs:[...]} — the delivery receipt without a socket,
                                  for the notification extension; same rules as `recv`
POST /api/chats/:id/accept        accept a message request
POST /api/chats/:id/members       {add[], remove[]}
POST /api/chats/:id/delete        delete the chat for yourself: a group is left, a direct
                                  chat is only taken out of your own list (the journal and
                                  the membership stay, the peer learns nothing); your own
                                  read mark moves to the end of the journal in the process
POST /api/chats/:id/settings      {title?, avatarId?, description?,
                                  sendPolicy?, invitePolicy?} — a policy is "all" or
                                  "admins" and is a group's alone
POST /api/chats/:id/admins        {userId, admin:bool}
POST /api/chats/:id/pin-message   {msgId|null}
POST /api/chats/:id/flags         {pinned?, muted?, mutedUntil?, archived?} — local to
                                  the user; mutedUntil is in seconds, null = indefinitely
GET  /api/chats/:id/fanout        fanout queue of the chat →
                                  {pending, cursor, targets, attempt, oldestMs, armed};
                                  oldestMs is the head job's wait, armed says a drain
                                  is coming — a queue standing still is oldestMs growing
POST /api/chats/:id/invite        → {code, link:"msngr://join/<code>"}
POST /api/join/:code              → {chatId}
POST /api/media                   raw body (ciphertext) → {mediaId, size}
GET  /api/media/:id               streams the blob, supports Range (206)
POST /api/push-token              {apnsToken, env}
POST /api/phone                   {phoneHash|null}
POST /api/contacts/discover       {hashes[]} → {matches[]}  (up to 5000 hashes, in chunks of 100)
POST /api/block                   {userId, blocked}
GET  /api/blocked                 → {blocked:[userId]}
POST /api/dev/fault               {failEvents} — dev hook: the caller's own session
                                  object rejects that many frame deliveries
```

Rights: only an admin can remove members and change group settings; an admin can
add anyone, a non-admin only themselves; joining by an invite link is allowed to
a non-member (`viaInvite`). Blocks are covered in the section below.

A group carries two policies, each `"all"` or `"admins"`, and both travel in the
chat state. `sendPolicy: "admins"` refuses a non-admin's content send with
`not_allowed`; frames marked `service: true` are never held back, so key
handouts, receipts, repairs, edits and reactions keep working for everyone,
otherwise the member could not read the chat. `invitePolicy: "admins"` refuses a
non-admin both `POST /api/chats/:id/members` for anyone but themselves and
`POST /api/chats/:id/invite`, with the same code. A chat with no stored value for
a policy reads as `"all"`.

## Signing in on a new device

There is no password and no phone number: a new device is let into the account by
one that is already in it. The new device opens a provisioning session and shows
an eight-character code (Crockford base32), the owner types the code on the old
device, and the old device seals the account bundle to the session's ephemeral
key and puts it on the server. The server does not look inside the `envelope`.

- `provisionToken` is issued once, to the device that opened the session, and is
  stored as a hash: the code names the session, the token makes the right to it
  personal.
- A session is single-use and lives 120 seconds. An approved one cannot be
  approved again, and `lookup` no longer finds it.
- `claim` registers the device under the account whose device approved the
  session, and requires the same `identityKey`/`identitySignKey` that are already
  recorded for the account: the identity belongs to the account, not to the
  device (`docs/crypto-flows.md`). A mismatch is `identity_mismatch`.

The reasoning behind the design, and what this mechanism does not protect
against, are in `docs/research/2026-08-16-second-device.md`.

## Blocks

A block symmetrically kills delivery inside an already existing direct chat: the
author's message is accepted, takes a `seq` and sits in the journal, but
`ConversationDO` does not send it to the blocked side, neither as a `msg` frame
nor as a push. `typing` and `presence` are cut the same way. The author gets an
ordinary `sent` and sees a single tick: `delivered` never arrives.

So that the blocker's unread count does not grow on invisible messages, their
read mark moves up to the `seq` of the held message right inside `/send` (with no
`receipt` frame to the author). Once unblocked, the held messages arrive through
an ordinary `sync`: the journal keeps them, and there is no separate filtering in
history.

## WS: client → server

```
{t:"sync",  cursors:{chatId: lastSeq, ...},    // the whole world as the client knows it
            deviceVersions?:{userId: v, ...}}  // the device cache held across the reconnect
{t:"catchup", cursors:{chatId: cursor, ...}}   // the next catch-up portion
{t:"send",  chatId, clientMsgId, sentAt, body, service?}   // body is the E2E envelope
{t:"recv",  chatId, seqs:[...]}                            // → delivered receipts to the author
{t:"read",  chatId, upToSeq}
{t:"typing",chatId, kind}                                  // kind: a string or null (stop)
{t:"delete",chatId, msgIds:[...], forAll}
{t:"ping"}
{t:"bg"}    // the app went to background: presence goes offline at once
{t:"fg"}    // it came back: presence goes online
```

`service: true` marks a service frame (a sender key handout, a reaction, an edit,
a TTL switch, a group event). It takes a `seq` and is kept in the journal, but it
does not grow unread and raises no push. The client marks `edit`, `reaction`,
`disappearing` and `groupEvent` this way (`SyncEngine.serviceKinds`), along with
every skd envelope. Of those only `groupEvent` leaves a row in the feed, a system
line; the rest are listed in `SyncEngine.rowlessKinds`.

## WS: server → client

```
{t:"hello",   serverTime, protocol, minProtocol}
{t:"sent",    chatId, clientMsgId, msgId, seq, ts}
{t:"msg",     chatId, seq, msgId, from, fromDevice, sentAt, ts, body, service?}
{t:"receipt", chatId, kind:"delivered"|"read", upToSeq, by}
{t:"typing",  chatId, from, kind}
{t:"presence",userId, online, lastSeen}
{t:"profile", user}
{t:"devices", userId, version}
{t:"deviceVersions", versions:{userId: v, ...}}
{t:"chat",    chatId, event:"created"|"members"|"settings"|"pinned"|"sync", state}
{t:"deleted", chatId, msgIds, forAll, by}
{t:"syncState", chatId, cursor, more}
{t:"syncDone", more}
{t:"error",   error, chatId?, clientMsgId?}
{t:"pong"}
```

`error` is a rejection of a client frame; `error` carries a machine-readable code
(`blocked`, `not_member`, `not_allowed`, `send_failed`). For a `send` it arrives
instead of `sent`, with the same `clientMsgId`.

`devices` says the user's device set changed — a device was linked or revoked.
It goes to the user's own other devices and to everyone they share a chat with.
`version` is the user's device-set version after the change: every link and
revocation bumps it inside the user's `UserDO`, which owns the identity keys,
the one-time prekeys and the device list. A sender caches device lists between
sends, stamped with the version `GET /api/devices` read them under; a frame
naming a version the cache already holds confirms the entry, anything newer
drops it, and the next envelope re-reads the list.

A frame sent while the socket was down is gone, so a reconnect leaves every
cached entry suspect: the client sends its versions in the sync's
`deviceVersions` map, and the server answers with a `deviceVersions` frame
naming the current version of every asked user. Entries the answer confirms are
trusted again; the changed and the unknown are dropped. A send that races the
answer treats a suspect entry as absent and re-reads the list — a device linked
while the client was offline is never sent past.

`state` in a `chat` frame is the chat's full snapshot: `members` (userId, role,
joinedAt, accepted), `title`, `avatarId`, `description`, `sendPolicy`,
`invitePolicy`, `pinnedMsgId`, `lastSeq`, `readMarks`, `deliveredMarks`. The frame does not carry member
profiles: the client pulls the ones it is missing through `GET /api/users/:id`.

## Delivery order

`sent` leaves as soon as the message owns a `seq` and is written, before any
recipient sees the frame and before APNs is called. Frames of one chat reach a
recipient in the order the chat produced them; a `msg` frame can be delivered
twice (a retried fanout pass), so the client dedupes by `msgId`.

## Presence

`UserDO` counts a user as online while at least one socket has sent a
`ping` no more than 35 seconds ago (`PRESENCE_TTL_MS`); the client pings every
12 s. An open but silent socket does not count as online — iOS holds the
connection for minutes after the app is backgrounded. A status change is
broadcast by the DO's alarm; `bg`/`fg` switch it at once.

## Catch-up after a reconnect

Catch-up is pulled by the client one portion at a time. The cursors live on the
client, the object serves a portion and goes back to its event loop, so live
traffic waits for one portion instead of the whole backlog and a connection cut
short resumes from the last confirmed cursor.

1. The client sends `sync` with a cursor per chat it knows. Chats missing from
   the map are new to it: the object replays their state in a `chat` frame with
   `event: "sync"` and puts them into the portion at cursor 0.
2. The object reads one `/history` page per chat (at most 128 records, the
   Durable Objects batch read limit), sends the `msg` frames and answers
   `{t:"syncState", chatId, cursor, more}`. The cursor moves along scanned
   records rather than delivered ones, so a page filtered out by a block does
   not stall the catch-up.
3. A chat whose page came back short is caught up: its tombstones (`deleted`)
   and current `readMarks`/`deliveredMarks` (`receipt`) follow — what happened
   to already delivered messages while the client was offline.
4. `{t:"syncDone", more}` closes the portion. `more` is true when some chat is
   still behind, or when the portion ran out of budget before reaching every
   chat it was asked about: one portion reads at most 128 records over at most
   32 chats. The client then sends `catchup` with the chats that are still
   behind — those whose `syncState` said `more`, plus those it got no
   `syncState` for — and repeats until `more` is false.

The client stores the confirmed cursor per chat, so a catch-up interrupted
halfway resumes where it stopped instead of starting over. The cursor of the
next `sync` is the larger of that cursor and `syncedSeq` (the contiguously
applied prefix): a seq that never reaches this device — a message held back by
a block, for instance — stalls `syncedSeq` forever, and the catch-up cursor is
what moves past it.

Tombstones are skipped as `msg` frames in a page and arrive as `deleted`.

## Blocks in detail

The block list is the `blocks` table in D1, directed: a row `(user_id,
blocked_id)` means "user_id has blocked blocked_id". The `ConversationDO` of a
direct chat reads the pair lazily and holds it in memory; `POST /api/block`
drops that cache with a `/block-changed` frame (the chat may not exist yet at
that point). Blocks are not checked in groups.

The behaviour inside an existing direct chat is the one messengers have settled
on: from the server's answers, a blocked user cannot tell a block from a peer who
has gone quiet.

- A blocked user sends `send`: the server answers with an ordinary `sent` (the
  message gets a `seq` and stays in their own history), but does not send it to
  the recipient, sends no push and marks the record `blockedFor: <userId of the
  blocker>`. Such a message reaches neither the blocker's `/history` nor their
  `sync` — including after the block is lifted.
- A blocker sends `send` to the one they blocked: an explicit refusal, the frame
  `{t:"error", error:"blocked"}` (the HTTP equivalent is 403 `blocked`). They
  know about their own block, there is nothing to hide.
- With a block in either direction, `receipt`, `typing` and `presence` are not
  passed between the pair, and the blocked user's `delivered`/`read` marks are
  not even written: they are visible in the `state` of a `chat` frame.
- Creating a direct chat with someone who blocked you (or whom you blocked) is
  not possible: 403 `blocked`.

`/history` returns two counters next to `msgs`: `scanned` — how many records were
read before filtering, and `lastScannedSeq` — the `seq` of the last one read.
They are what moves the cursor in `sync`; otherwise a page that dropped out of
the result entirely because of a block would stop the catch-up.

## Message requests

In a direct chat the recipient is marked `accepted: false` until they call
`/accept`. Until then the author of the request receives neither `receipt` nor
`typing` nor the recipient's `presence`; `GET /api/users/:id` also returns
`presence: null` to the author while the recipient has not accepted. Unread
counts of such a chat do not enter the push badge (`/unread-count` returns 0). In
groups every member counts as having accepted.

## E2E envelope (`body`)

The server does not look inside. Two modes:

```
{v:1, mode:"pw",  msgs:{ "<userId>/<deviceId>": PairwiseBox, ... }}
{v:1, mode:"skm", c, keyId, iteration, sig}
```

`PairwiseBox`:

```
{type:"pk"|"dr", c,        // base64 JSON RatchetMessage {header:{dhPub,pn,n}, ciphertext}
 ik?, isk?, iksig?, ek?, spkId?, otpId?}   // pk only: our identity DH/Ed25519 pub,
                                           // the Ed25519 signature over the DH pub,
                                           // the ephemeral and the ids of the prekeys used
```

A `pk` box is opened only when `ik`, `isk` and `iksig` are all there and the
signature holds: the recipient trusts the identity by `isk` and runs X3DH on
`ik`, so a box that does not sign the two together says nothing about who sent
it (`docs/crypto-flows.md`).

A sender key handout (`skd`) is not a separate envelope mode: it is an ordinary
pairwise message carrying an `InnerMessage` with `type:"skd"` inside.

Inside the pairwise ciphertext:

```
{type:"content", content: ContentPayload, chatId}
{type:"skd", skd:{keyId, iteration, chainKey, signingPub}, chatId}
```

`chatId` inside the ciphertext is the chat the sender wrote in. The chat the
envelope arrives in comes from the server, so the recipient checks the two
against each other and refuses a message put into another conversation
(`wrong_chat`): it belongs to that other chat, not this one, and no repair is
asked for it.

`ContentPayload` (also the plaintext in `skm`):

```
{kind, text?, media?, album?, replyTo?, fwd?, shader?, targetMsgId?, emoji?,
 ttlSeconds?, to?, repairSeq?, reason?, attempt?, repairOf?, origSentAt?, orig?,
 keyId?}
```

- `kind`: `text` | `photo` | `video` | `file` | `voice` | `album` | `contact` |
  `shader` | `edit` | `reaction` | `disappearing` | `groupEvent` |
  `repairRequest` | `repair` | `skdAck`;
- `shader` — `ShaderDocument`: `{name?, passes: [{id, kind, code, inputs}]}`,
  a Shadertoy project as user code. `id` is `image`, `A`–`D` or `common`;
  `kind` is `image` | `buffer` | `common`; `code` is GLSL in the Shadertoy
  dialect (`mainImage`, `iTime`, `iResolution`, `iChannelN`); an input is
  `{channel, source, wrap, filter, vflip}` with `source` one of `noise`,
  `graynoise`, `noise64`, `none` or `buffer:<id>` (a pass reading its own
  buffer gets its previous frame). The receiver transpiles each pass to MSL
  and renders it on its GPU; the server never sees the code. The whole
  document stays under 64 KB of code: a message is one value of the
  conversation's Durable Object storage, whose ceiling is 128 KiB;
- `media` / `album` — `MediaInfo`: `type, mediaId, key, hash, size, mime, name?,
  w?, h?, dur?, waveform?, blurhash?, thumbMediaId?, thumbKey?, thumbHash?`;
- `replyTo` — `{msgId, authorId, text, kind}`, `fwd` — `{fromUserId, fromName}`;
- a forward is an ordinary content frame in the target chat: the sender copies
  the content and the `replyTo` preview of the original into a new payload and
  sets `fwd` to the original author (forwarding a forward keeps the `fwd` it
  already has, so the chain always names whoever wrote the message). The
  preview travels because the quoted message may not exist in the target chat;
  a tap on it there finds nothing and does nothing. Reactions do not travel:
  they belong to the conversation they were made in — the same choice Telegram
  makes — and the forwarded copy starts clean;
- `edit` and `reaction` address a `targetMsgId`, `emoji: null` removes the
  reaction;
- `disappearing` carries `ttlSeconds` — the chat's new TTL;
- `groupEvent` carries the event in `text`, as `group:` followed by JSON
  (`GroupEvent`): the verb, the display name of whoever acted, and the name and
  id of the member it concerns. The names travel with the event so a line about
  someone who has already left still reads;
- `to` — an addressed frame: the envelope is encrypted pairwise to a single
  member, even in a group. The whole repair protocol travels this way.

### Repairing an unreadable message

It runs on its own, with no user involved, over service frames (`service: true`).

- `repairRequest` — "could not read a message": `targetMsgId`, `repairSeq`,
  `reason` (why decryption failed), `attempt` (the attempt number), `to` — the
  author of the message. `clientMsgId` is deterministic (`rq:<msgId>:<attempt>`):
  a repeat of the same attempt is swallowed by the server's dedup, the next
  attempt goes through.
- `repair` — the author's answer: `repairOf` (the original msgId), `repairSeq`,
  `origSentAt` and `orig` — the original `ContentPayload` as a JSON string. The
  recipient stores it under the original `msgId`, so in the feed the copy takes
  the place of the lost message instead of appearing next to it. `clientMsgId` is
  `rp:<msgId>:<attempt>`.
- `skdAck` — an acknowledgement of a sender key handout: the `keyId` of the
  chain. While the acknowledgement is missing, the sender hands the chain out
  again; a `repairRequest` with `reason: "no_sender_key"` makes it hand the chain
  to that member once more.

The `localPath`/`thumbLocalPath` fields in `MediaInfo` exist locally only (the
attachment's source, not yet uploaded to the server) and never reach the
envelope.

## Delivery and order

At-least-once. Order is by `seq` inside a chat. The client dedupes incoming
messages by `msgId` and its own sends by `clientMsgId`. An envelope that could
not be decrypted is stored in `pendingDecrypt` whole, whatever the reason: it is
the only local copy. It is replayed when a key appears in the chat, and by passes
at engine start, on a reconnect and round the clock in the background; the
attempt counter and the lifetime sit on the same row. `edit`/`reaction`/`deleted`
whose target is not in the database yet go into `pendingApply` and are applied
once the original shows up.

What replaying does not recover is repaired through the sender (`repairRequest` →
`repair`). The seq itself is written into `historyGap` with a reason and a
counter: pagination upwards does not go to the server for it again, and a neutral
placeholder appears in the feed only once the repair attempts are spent.

## Receipts and ticks

`deliveredMarks` and `readMarks` hold one seq per member; both only move
forward, and repeating a mark changes nothing. A recipient answers `recv` as soon
as the message is on the device — over the socket while the app runs, and over
`POST /api/chats/:id/recv` when the notification extension wrote the message from
a push with no app running. The receipt is written down before it is sent, so an
extension the system kills leaves it queued and the app sends it on its next
connection.

Every chat state carries where the server thinks each member stands, including
the reader itself, so a mark that never arrived is queued again on the next
snapshot: a frame handed to a socket that is already dying goes nowhere and
reports no error, and without the comparison the author would keep a tick that
never moves.

The tick the author sees speaks for the whole chat: it turns delivered when the
member furthest behind has the message, and read when the last of them has read
it. In a direct chat that is the peer; in a group of three both members have to
answer before the second tick appears. A member who joins later holds the ticks
of new messages where they are, and neither the marks nor the status of a message
ever move back.

## Pushes

APNs is called immediately for every content `msg` — regardless of presence and
live sockets. The exceptions: `service:true`, the author's own echo, a muted
chat, a block. A mute with an expiry (`mutedUntil`) runs out on its own:
`UserDO` clears the flag at the first check after the deadline — on a push
and in the `/api/chats` snapshot. Dedup on the client: `willPresent` suppresses
the banner if the message has already been shown over WS (matched by
chatId/msgId, see `NotificationDecision`).

```
POST {APNS_HOST}/3/device/{apnsToken}
headers: apns-topic, apns-push-type: alert, apns-priority: 10,
         apns-collapse-id: <msgId>     // a repeated delivery does not multiply banners
{
  "aps": {
    "alert": {"title": "Msngr", "body": "Новое сообщение"},
    "badge": <the user's total unread>,
    "sound": "default",
    "mutable-content": 1,
    "thread-id": "<chatId>"
  },
  "chatId": "...", "msgId": "...", "seq": <position in the chat>,
  "sentAt": <ms>, "badgeStamp": <counter number>,
  "from": "<author's userId>", "fromDevice": "<author's deviceId>",
  "ts": <server seconds>,
  "env": "<this device's E2E envelope, as compact JSON>"
}
```

`env` is the message itself, not a reference to it: the extension decrypts it and
writes it into the database, so what was read in the banner stays in the chat
even with no network (`PushMessageWriter`). The envelope is cut down to the
addressee: for `pw` a single `userId/deviceId` box is left, `skm` travels whole.
`from`/`fromDevice` name the sender — they pick the session to open it with.

APNs does not accept a payload larger than 4 KB and refuses it entirely, so `env`
is dropped first: the rest gets through, and the message arrives on the next
connection. That is how attachments go — a picture with a caption fits over the
edge, large media does not.

The badge is counted by the server: `aps.badge` is the user's total unread across
chats, and a request that has not been accepted is not part of it. The client
does not recount the number, it only reports its own when it has moved its read
mark itself.

`badgeStamp` is the sequence number of the counter that `UserDO` issues
for every push it sends. APNs delivers an avalanche in arbitrary order, and
`badgeStamp` is how a device tells a fresh counter from an older one that
overtook it: a smaller number does not reach the icon (`BadgeStore`).

The APNs answer is parsed:

- `410` — the device token is dead: the record is deleted both from
  `UserDO` storage and from `devices.apns_token` in D1;
- `429` and `5xx` — up to two retries, after 500 ms and 1500 ms;
- `403 ExpiredProviderToken` — a forced JWT re-issue and one more attempt;
- `400` and everything else — the code and `reason` go to the log, no retry.

Devices are handled independently: a failure on one token does not cancel the
send to the rest.

The provider JWT (ES256, p8) belongs to the singleton object `ApnsTokenDO` (named
`apns-jwt`): the cache sits in its storage and lives 3000 seconds. There is a
single owner because Apple limits how often the token may be generated, while
there can be many isolates holding `UserDO`s. A forced re-issue happens at
most once a minute.

Badge: `UserDO` keeps a per-chat unread cache in storage (`unreadCache`),
invalidates it on an incoming `msg` and on its own `read`, and at the moment of
sending a push lazily recounts the invalidated chats with a `GET
/unread-count?userId=` request to `ConversationDO` (`lastSeq` minus the read
mark). An approximation: muted chats enter the badge until they are read.

Dev without an Apple account: `APNS_HOST` (in `server/.dev.vars` —
`http://localhost:9871`) diverts pushes into the mock
`server/tools/apns-mock.mjs`, which delivers them to the simulator through
`xcrun simctl push` (apnsToken = the simulator's UDID). On a non-Apple host the
request goes out without a JWT signature, no p8 key is needed, and `apns-topic`
defaults to `msngr.msngr`. A limit of that channel: `simctl push` does not
launch the Notification Service Extension — see
`docs/research/nse-simulator-experiment.md`.

## D1 schema and migrations

The schema lives in `server/migrations/` as numbered files (`0001_init.sql`,
`0002_…`), applied by wrangler's own runner; the directory and the journal table
are set in `wrangler.jsonc` (`migrations_dir`, `migrations_table: d1_migrations`).

```
npm run migrate:local     # the local wrangler dev database
npm run migrate           # the remote database
npm run deploy            # migrations on the remote database, then wrangler deploy
```

A new migration is a new file with the next number; files already applied are not
edited, the runner checks against `d1_migrations`.

## Versions

There is no backward compatibility (see `docs/PROCESS.md`), but every mismatch
has a place to be named instead of a silence or a crash.

- Protocol. `server/src/version.ts` holds `PROTOCOL_VERSION` and
  `MIN_CLIENT_PROTOCOL`; `MsngrProtocol.version` is the client's side of the
  same number. It travels in the upgrade (`/ws?v=`), and the server states both
  numbers back in `hello` and in `GET /api/version` (no auth). A client below
  the floor is refused with `426 client_too_old`, the reconnect loop stops and
  the app shows that it is out of date.
- Envelope. `v` in the E2E envelope. An envelope above
  `MsngrProtocol.envelopeVersion` is kept as it arrived and marked unreadable;
  no repair is asked for, because a fresh copy would come back in the same
  format, and the message opens once a build that knows the format runs.
- Database schema. The GRDB migrator: a file carrying migrations this binary
  does not register is not opened and not wiped
  (`AppDatabaseError.schemaFromNewerVersion`, `StorageOwnership.startOver`).
  Starting over on clean storage is the user's call.
- Server storage: D1 migrations in `server/migrations/`, DO tags `migrations`
  in `wrangler.jsonc`.
