# Msngr architecture

An end-to-end encrypted messenger: iOS and macOS clients over a Cloudflare
Workers backend.

```
server/           Worker: HTTP API (hono), WS, Durable Objects, D1, R2, APNs
ios/MsngrKit/     the portable core (Swift package): MsngrCrypto + MsngrCore
ios/Msngr/        the iOS app (SwiftUI, with UIKit for the message feed)
ios/MsngrMac/     a macOS client on the same core
ios/NotificationService/  the NSE: a push preview out of the shared database
docs/             protocol, crypto flows, UI, process, audits, QA
```

## Backend

- **Worker (the router)** — the whole HTTP API and the `/ws` upgrade. It
  authorises the socket and hands it to the user's `UserDO`.
- **UserDO** — one per user. It holds the WS of every device they have
  (WebSocket Hibernation API), the chat list with its local flags (pinned,
  muted, archived), presence, APNs tokens, and the unread cache behind the
  badge. Everything addressed to a user passes through their DO, which is the
  single fan-in point.
- **ConversationDO** — one per chat. It stores membership with roles and the
  `accepted` flag for message requests, the message journal (ciphertext plus
  metadata), read and delivered marks, the pinned message and the settings. It
  assigns monotonic `seq`, deduplicates sends by `clientMsgId`, and after
  writing puts the frame into an alarm queue for fan-out over the participants'
  `UserDO`.
- **D1** — users, devices with token hashes, identity keys and prekey bundles,
  blocks, invites, the media registry.
- **R2** — media blobs, encrypted on the client.
- **APNs** — token-based auth (p8, ES256, with the JWT cached). A push goes out
  for every content message immediately, whether or not a socket is alive; the
  client suppresses the duplicate.

A direct chat is addressed by the deterministic name `direct:<id>:<id>`, so it
deduplicates without an index. DO storage is SQLite-backed
(`new_sqlite_classes` in `wrangler.jsonc`).

## Protocol

One WS per device, JSON frames of the shape `{t, ...}`. The client sends `sync`,
`send`, `recv`, `read`, `typing`, `delete`, `ping`, `bg` and `fg`; the server
sends `hello`, `sent`, `msg`, `receipt`, `typing`, `presence`, `chat`, `deleted`
and `pong`. Delivery is at-least-once, order comes from `seq`, idempotency from
`clientMsgId`. `sent` goes out as soon as the message is written, before the
recipient sees it and before APNs is called.

After a reconnect the client sends per-chat cursors, the server returns one
batch of what was missed along with new cursors, and the client asks for the
next batch itself until there is nothing left; the last batch of a chat is
followed by tombstones and the read and delivered marks. Everything else —
registration, keys, profiles, media, contacts — is HTTP.

The full specification is in `docs/protocol.md`.

## E2EE

- A device identity is a pair of keys, X25519 for DH and Ed25519 for signatures.
  CryptoKit has no XEd25519, which is why they are separate.
- One-to-one goes X3DH (identity, signed prekey, one-time prekey) into a Double
  Ratchet. The root and chain KDFs are HKDF-SHA256 and HMAC-SHA256, encryption
  is ChaChaPoly, and the ratchet header travels in the associated data. Gaps and
  reordering are handled with skipped message keys, up to 1000 in a row and 2000
  in storage.
- Groups use sender keys: a chain of our own per chat, handed out over the
  pairwise channel inside an ordinary message, with every group message signed
  with Ed25519. A member leaving rotates our chain.
- Media gets a random key per file (ChaChaPoly); the key and the SHA-256 of the
  ciphertext travel inside the E2E message and the server only ever sees a blob.
- Verification is by safety numbers, 60 digits over 5200 iterations of SHA-512.
- Private keys and session state live in the database encrypted under the master
  key, and the master key itself is a file in the app group container under Data
  Protection.

The flows are in `docs/crypto-flows.md`.

## The client core (MsngrKit)

- **MsngrCrypto** — X3DH, Double Ratchet, sender keys, media encryption, safety
  numbers. No dependencies beyond CryptoKit.
- **MsngrCore** — the GRDB store (SQLite in WAL) as the single source of truth
  for the UI, `WSClient` (reconnect with backoff up to 12 s, immediate reconnect
  on `NWPathMonitor`, ping/pong keepalive), `SyncEngine` (applying frames, the
  outbox, the service action queue, fetching profiles, topping up prekeys),
  `E2EEManager`, `MediaManager`, `APIClient`, BlurHash, album mosaics, the image
  pipeline.

The queues in the database: `outbox` for outgoing messages, in states `ready`,
`inflight` or `blocked`; `pendingAction` for read marks, delete-for-all and
accept, which collapse and drain on connect; `pendingDecrypt` for messages that
arrived before their key; `pendingApply` for edits, reactions and tombstones
with no original yet.

## Storage

Paths are computed in one place, `StorageLocation` and `AppContainer`. The root
is the app group container `group.msngr.msngr` so that the NSE reads the
same files; without a group, on macOS and in tests, it is Application Support.
The contents are `msngr.sqlite`, `.masterkey`, `avatars/` and `media-outgoing/`.

`StorageMigration` moves data from Application Support into the container: a
copy into a temporary directory inside the new root, a move into place, and only
then the removal of the originals. The database file moves last, so until it
lands the new root counts as unoccupied and an interrupted migration finishes on
the next launch. Files get `completeUntilFirstUserAuthentication` so the
extension can read them while the screen is locked.

## The iOS client

- The message feed is a `UICollectionView` with a hand-written diff and a
  precomputed layout plan (measurements cached), inverted scrolling and upward
  pagination that does not jump. The rest of the UI is SwiftUI.
- Offline-first: the UI reads only the database through `ValueObservation` and
  the network is background synchronisation. Sending works with no network at
  all, as the message and its attachment go into the outbox and the upload and
  encryption happen once there is a connection.
- Pushes: APNs plus a Notification Service Extension, which decrypts the
  envelope the push carries and writes the message into the shared database, so
  the banner text is read back out of that row. An in-app banner covers the
  case of an active app, deduplicated against the system push by msgId. The
  badge number is computed by the server and stamped with a counter; the device
  keeps one row for it.
- A PIN with Face ID, a blur in the app switcher, auto-lock.
- Voice messages: `AVAudioRecorder` into m4a/AAC, a waveform from real
  amplitudes, slide-to-cancel and lock.

## Decisions taken

These shape where the project can go. Changing one is its own conversation, not
a side effect of some other task.

**Apple only: iOS and macOS.** Android is neither supported nor planned for. The
owner accepted the narrower audience deliberately: the paying part of the market
sits in the App Store, and being one-sided costs less than compromising for a
second platform.

What follows from that, and can be relied on without a fallback path: the Secure
Enclave is always there, so keys bind to hardware with no branch for software
storage; App Attest is always available, so the cost of making an account is
raised by device attestation rather than by biometrics or a phone number; the
notification extension has one contract and one budget, with no allowances for
vendors that kill background processes; CryptoKit is used directly; the app and
the extension share one container and one SQLite.

The `MsngrKit` core is written in Swift and is not portable, which is the price
of that decision and was paid knowingly. Going back to Android would mean moving
the core into a portable language, so a rewrite rather than a port. The server
and the protocol are platform-independent and this decision does not touch them.

The open cost: there is no fallback of the kind iMessage has when it degrades to
SMS or RCS, so a chain of invitations stops at the first person without an
iPhone. What to do about that is undecided.

**One ConversationDO for now, a separate object for groups later.** A dialogue
and a group differ in nature: a dialogue is an instant path between two people,
a group is a fan-out queue machine. While groups are small the shared object is
cheaper; once there are fan-out queues, rights and membership management, groups
move into their own Durable Object. The general principle is that less
generalisation leaves more room to optimise each path.

**Delivered and read marks are two moving boundaries per participant**, not a
mark on every message: the last delivered and the last read seq are stored, and
asking whether a message has been read is a comparison against the boundary.
Read implies delivered.

**Paged history reading respects the Durable Objects limit of 128 keys per batch
read.** History batches are cut with that limit in mind.

**Clearing history "for myself" is a client feature under end-to-end
encryption.** The messages are in the local database and the server does not
know their contents, so clearing is a local delete plus a watermark that keeps
synchronisation from bringing back what was erased. Only delete-for-everyone
needs the server.

**The local database is the only copy of a conversation.** The ratchet moves
forward and the keys of a decrypted message are destroyed, so a device cannot
re-read its history from the server: the only useful thing there is what this
device has not decrypted yet, meaning whatever it missed while offline. The
consequences are that deleting the local database destroys the conversation
irrecoverably; that upward pagination runs over the local database and the
server is only asked about unclosed gaps; and that switching users must wipe
storage entirely, or the device's new owner inherits someone else's data.

**The push path is not deferred.** `waitUntil` gives no timing guarantee and
sometimes adds noticeable delay, which the owner measured on a previous project,
so the APNs call is made and awaited inside the handler rather than moved into
the background. This does not hold up the sender: the acknowledgement goes out
as soon as seq is assigned, with fan-out and the push behind it. If measurements
against live APNs show that the worker gets no HTTP/2 connection reuse and every
push pays for a handshake, a sidecar with a persistent connection goes in: a
synchronous hop to it is cheaper than a handshake per message.

**A notification is a write to the database, not a display.** A message seen in
the notification centre has to be in the chat when the chat is opened, even if
the network is gone by then, as in airplane mode. So the push carries the E2E
envelope itself, trimmed to the destination device; the extension decrypts it on
delivery and writes the message into the shared database in the same transaction
that claims the right to show a banner, and the banner text is read from that
row. Tapping the notification opens the chat out of the local database and needs
no network.

APNs will not take more than 4 KB. An envelope that does not fit is dropped from
the payload rather than truncated, since the server cannot see the text and has
nothing to truncate; the notification still arrives, and the message itself
arrives over the next connection. Ordering is handled in passing: the extension
sees seq and can mark a gap to fill.

Decryption mutates ratchet state, so it runs under arbitration: the right to
decrypt belongs to whoever holds the lock, the app has priority, and an
extension without the lock shows a banner without text and leaves the message
for the app.

**Message order is held by seq**, and monotonic server timestamps are not
needed: seq is assigned sequentially by the chat object, while the client's
`sentAt` is only used for display.

**The platform is Cloudflare Workers.** Durable Objects give what would
otherwise have to be built by hand: addressable state per chat and per user, a
monotonic `seq` with no external database, and WebSocket Hibernation. Fan-out
runs as an alarm queue in `ConversationDO` rather than as a walk over the
participants on the sender's path: the job and its delivery cursor sit in
storage, and each alarm iteration handles a batch within the subrequest limit
and moves the cursor. The ceiling of 1000 subrequests per request does not cap
the audience, because the next alarm iteration gets a fresh budget; a break
mid-fan-out resumes from the cursor, and re-issuing a frame is safe since the
client deduplicates by `msgId` and the marks are monotonic. Jobs are handled in
order, so a recipient sees a chat's frames in the order the chat produced them.
A failing recipient does not break delivery for the rest: it goes into retry
with backoff and after three attempts is dropped with a log line. `typing` is
never retried, because by the time of a retry it is already wrong.

**Large groups and channels go without E2EE.** With thousands of participants
everyone holds the key, so end-to-end encryption protects nothing there: forward
secrecy stops meaning anything while the price stays high, with no server-side
history for new members, no search, and N envelopes per message instead of one
copy. Those chats stay plaintext on the server even when entry to them is
restricted. Private chats and small groups stay E2EE. That imposes a UI
requirement: the chat type is chosen at creation and shown with an explicit
marker, and there is no quiet conversion between types.

**Media.** In private chats these are encrypted blobs in R2, with all processing
— previews, compression, blurhash — done on the client before encryption, so the
server sees only ciphertext. Public channel content will be able to go through
CF Stream and Images, because there is nothing to encrypt. Calls, in time, would
be CF Calls with end-to-end encryption over insertable streams; the provider has
to sit behind our own protocol from the first file, so that replacing it does
not drag a client rewrite along.

**Notifications.** APNs fires immediately and always for a content message:
delivery over WS is not guaranteed, and a duplicate is cheaper than a missed
notification and is suppressed on the client. Under E2EE the server knows
neither the text nor the avatar, so the NSE fills them in locally and the
payload's fallback stays a neutral «Новое сообщение». For unencrypted channels
the server puts the text in directly.

**Compatibility and versioning** — see `docs/PROCESS.md`.

## Principles

- In private chats and small groups the server never sees message or media
  plaintext.
- The client is never blocked by the network: the UI reads SQLite and the
  network runs in the background.
- One WS per device; everything else is HTTP.
- Backward compatibility is not maintained, but the places to version are
  already there (see `docs/PROCESS.md`).
