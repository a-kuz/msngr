# Signing in on a second device

Status: design, 2026-08-16. Written before the code, against `main` at
`2429451`.

Today the only way into an account is `POST /api/register`, which mints a new
user. There is no login, so a reinstall is a new identity and a second device is
a second person. Everything below is about closing that: a device the user
already holds authorises a new one, and both then live on the same account.

The pieces that already exist and that this design leans on: devices are
per-user rows with their own keys (`identity_keys`, `one_time_prekeys`), the
pairwise envelope is addressed per device (`"<userId>/<deviceId>"`), a sender
enumerates the recipient's devices on every send (`GET /api/devices`, nothing
cached), one's own other devices are always in the recipient set
(`E2EE.encryptPairwise` adds `ownUserId` to the targets and skips only its own
`deviceId`), and a token can be revoked with the socket torn down
(`POST /api/sessions/:deviceId/revoke`, close code 4401).

## 1. What carries the trust

There is no phone number, no password and no server-side account secret. The
only thing that can vouch for a new device is a device that is already on the
account. So: the new device asks, the old device approves, and the answer is
carried by a channel the user themself closes — a short code read off one screen
and typed into the other.

Direction: **the new device shows the code, the old device types it.** Two
reasons. The new device is the one that has to contribute a public key to the
exchange, so it is the natural initiator; and the consequential act — "let this
thing onto my account" — belongs on the device that is already trusted, in front
of a screen that names what is being let in.

```
new device                       server                        old device
  |  POST /api/provision/start                                     |
  |  {ephemeralKey, device:{name, platform}}                       |
  |----------------------------------->                            |
  |  <- {provisionId, code, provisionToken, expiresAt}              |
  |                                                                |
  | shows code  "K7QP-3MTX"      ................. user reads it .>|
  |                                                                |
  |                              <---- POST /api/provision/lookup   |
  |                                    {code}   (device auth)       |
  |                              ----> {provisionId, ephemeralKey,  |
  |                                     device:{name, platform}}    |
  |                                                                |
  |                                    user confirms on old device  |
  |                              <---- POST /api/provision/:id/approve
  |                                    {envelope}   (device auth)   |
  |                                                                |
  |  GET /api/provision/:id  (provisionToken), polled               |
  |  <- {status:"approved", envelope}                               |
  |                                                                |
  | opens envelope -> account identity keys, userId, username       |
  | user confirms the account name                                  |
  |                                                                |
  |  POST /api/provision/:id/claim  (provisionToken)                |
  |  {identityKey, identitySignKey, signedPrekey, oneTimePrekeys}   |
  |  <- {userId, deviceId, token}                                   |
```

The envelope is sealed to the ephemeral key the new device generated and never
sent anywhere except inside its own provisioning session, so the server carries
it without being able to read it. `provisionToken` is a bearer secret the server
hands to the new device at `start` and stores hashed; it is what stops anyone
who learns the code from claiming the slot before the real device does.

### What this does not defend against

A user who types an **attacker's** code into their own device approves the
attacker onto their account. No cryptography prevents that — the same hole
exists in every QR-linking flow, and it is why the approval screen names the
device asking and says plainly what approving means. It is a phishing surface,
and it is stated here rather than papered over.

The reverse — an attacker guessing a pending code and approving the victim's new
device onto the **attacker's** account — is why the new device shows the account
it is about to join (`@username`) and asks for one more confirmation before it
finishes. Codes are 8 characters from a 30-symbol unambiguous alphabet (~39
bits), single use, and expire after two minutes; the confirmation is what makes
a lucky guess visible rather than silent. Per-code lookup rate limiting is not
implemented in the first slice.

A malicious server cannot produce the account identity private key, so it cannot
put a device of its own onto an account in a way peers accept — see §3.

### Losing the old device

While one device is left, everything works: it revokes the lost one and
authorises new ones. When the **last** device is gone, the account is gone.
There is no key escrow, no recovery phrase and no password, and adding one is
not in this design. That is the honest state and the interface must say it in
those terms before a user relies on a single device.

## 2. What the new device gets

**Nothing that was said before it was linked.** The ratchet destroys the keys of
every message it opens and the local database is the only copy; the server holds
envelopes addressed to devices that did not include this one. Replaying that
history onto a fresh device produces a chat full of undecryptable rows and a
storm of repair requests, which is worse than an empty chat.

So a freshly linked device starts with:

- the full chat list, titles, avatars, members, pinned message, read marks —
  everything in the `/api/chats` snapshot;
- zero messages, and the "history starts here" line at the top of every chat;
- unread counts at zero;
- every message sent from the moment it linked.

Mechanically this needs no server change. `ChatCleanup` already has the concept:
a chat that this device deleted and got back starts its cursors at the position
its `chatTombstone` kept, and `SyncEngine.upsertChatState` reads that position
as `syncedSeq`/`syncCursor`/`myReadUpTo`. A device that has just linked is in
exactly that state for every chat at once. The link flow therefore fetches
`/api/chats` and writes a `chatTombstone` at each chat's current `lastSeq`
before the first chat row is created. Consequences fall out for free:
`catchupCursors` asks the server only for seqs above `lastSeq`,
`HistoryWindow.openGaps` returns nothing below it, and upward pagination never
goes to the server for a range whose keys do not exist.

Messages sent in the gap between the claim and the peer's next `/api/devices`
read are addressed to the old devices only. They land as `not_addressed`, which
is already a silent gap reason: no placeholder, no repair request.

**History transfer is a later slice.** Moving the old device's database to the
new one is a separate problem with its own transport (the pairwise channel
between two devices of the same account is already there, but tens of thousands
of messages over `send` frames is not a design one can hand-wave), its own
progress UI and its own failure modes. It is not half-done here: the first slice
ships with the interface saying the chat starts now.

## 3. The account identity key is shared; per-device prekeys are not

This is the load-bearing decision.

`trustedIdentity` is keyed by **userId** — one trusted Ed25519 signing key per
peer — and a sender checks that key against *every* device of the recipient
(`E2EE.encryptPairwise`, the loop over `byUser[uid]`). With per-device identity
keys, the moment a peer has a second device the check finds two different keys
for one user, throws `identityChanged`, and blocks the outbox. Accepting the
change just flips the trusted key to the other device's, and the next send
blocks again. The safety number, computed over the peer's signing key, has the
same problem: it is a per-user number over a per-device key. This is already
recorded as open item 33 in `docs/audits/2026-08-12-code-audit.md`.

Two ways out. Make trust per device — every new device of a known contact is a
new trust event the peer has to accept — or make the identity belong to the
account and let devices share it. The second is what Signal does and it is the
right one here, for a reason beyond convenience: if the identity belongs to the
account and only the account's own devices ever hold its private key, then a
device the **server** invents cannot present that key, and every peer's existing
TOFU check trips on it. Per-device trust with auto-accept would give the server
a free hand to add a listening device; per-device trust without auto-accept
turns every genuine link into a "security code changed" scare for every contact.

So:

- the X25519 identity DH key and the Ed25519 identity signing key are the
  **account's**, generated at registration and copied into each linked device
  inside the provisioning envelope;
- the signed prekey and the one-time prekeys are the **device's**, generated
  locally; the linked device signs its own signed prekey with the account
  signing key, so `PreKeyBundle.verifySignature()` passes unchanged;
- the ratchet session, the sender-key chains and the local master key are the
  device's and are never copied;
- the server enforces the invariant: `claim` is rejected with
  `identity_mismatch` unless the identity keys presented equal those already
  recorded for the account.

Nothing in the crypto breaks under a shared identity key. X3DH between two
devices of the same account performs a DH of the identity key with itself, which
is a well-defined X25519 result and contributes no less than it does between
strangers — the freshness lives in the ephemeral and the prekeys, which differ
per device. `senderKeyIn` is keyed `(chatId, senderUserId, keyId)` with `keyId` a
UUID per chain, so two sending devices of one user hold two rows, not one.
Safety numbers become stable across linking, which is what a user expects.

The cost, stated plainly: **every linked device holds the account identity
private key.** A device that is stolen with its storage readable can impersonate
the account and link further devices for as long as the key stands. Revoking it
takes away its server access but cannot take away what it knows. Rotating the
account identity key would fix that at the price of showing "security code
changed" to every contact — which is the correct signal, but rotation is not in
this design.

## 4. What the server must know

One new table, one migration (`server/migrations/0003_provisioning.sql`).

```sql
CREATE TABLE provision_sessions (
  id            TEXT PRIMARY KEY,
  code          TEXT NOT NULL UNIQUE,
  token_hash    TEXT NOT NULL,       -- SHA-256 of the new device's provisionToken
  ephemeral_key TEXT NOT NULL,       -- b64url X25519 pub of the new device
  device_name   TEXT,
  platform      TEXT,
  created_at    INTEGER NOT NULL,
  expires_at    INTEGER NOT NULL,
  approved_by   TEXT,                -- userId of the approving device's owner
  approved_at   INTEGER,
  envelope      TEXT,                -- sealed account bundle
  claimed_at    INTEGER
);
```

Endpoints. `start`, `GET :id`, `claim` and `cancel` authenticate with
`provisionToken` and are registered before the `/api/*` device-auth middleware,
the way `/api/register` is; `lookup` and `approve` are ordinary
device-authenticated routes.

```
POST /api/provision/start          {ephemeralKey, device:{name, platform}}
                                   → {provisionId, code, provisionToken, expiresAt}
GET  /api/provision/:id            → {status:"pending"|"approved"|"expired", envelope?, userId?}
POST /api/provision/lookup   auth  {code}
                                   → {provisionId, ephemeralKey, device:{name, platform}, expiresAt}
POST /api/provision/:id/approve auth {envelope}
POST /api/provision/:id/claim      {identityKey, identitySignKey, signedPrekey,
                                    oneTimePrekeys, device:{name}}
                                   → {userId, deviceId, token}
POST /api/provision/:id/cancel
```

`claim` is the only one that writes account state: it inserts the `devices` row,
the `identity_keys` row and the one-time prekeys in one batch, marks the session
claimed, and returns the device token. A session is single use — an expired or
already-claimed session answers `provision_expired` / `provision_claimed`.

**Revocation grows teeth.** `revokeDevice` currently sets `revoked_at`, clears
the APNs token and closes the sockets. It must also delete the device's
`identity_keys` and `one_time_prekeys` rows. Without that, `/api/devices` keeps
listing a dead device, every peer keeps building envelopes for it, and
`/api/users/:id/prekeys` keeps burning one-time prekeys on it forever. With it,
the peer's very next send stops addressing the revoked device, because the
device list is read fresh on every send.

Two more revocation effects, on the client side:

- the revoking device drops its own `senderKeyOut` chains, so the next group
  message runs on a chain the revoked device never held. Without this, a revoked
  device that kept its storage can still read group traffic it is no longer sent
  — it cannot receive it over the wire, but it should not be able to open a copy
  either;
- the revoked device itself already learns: close code 4401 →
  `SyncEngine.sessionRevokedStream` → `SessionEndedView` → local wipe.

Group membership is per user, so a second device changes nothing about who is in
a chat. Sender-key distribution needs no new mechanism either: `encryptGroup`
expands the member list into devices through `/api/devices`, and an address that
is not in `distributedTo` is sent the chain on the next message. A new device
starts reading a group from the first message after the sender next writes, and
`repairRequest` with `reason: "no_sender_key"` pulls the chain sooner if a
message beats the distribution.

Two costs worth naming. The pairwise envelope grows one box per device, which
eats into the 4 KB APNs payload limit sooner — an envelope that no longer fits
is dropped from the push and the message arrives on the next connection, as
today. And a message the user sends themself is suppressed as own-echo before
the push fanout, so a second device that is asleep learns of it on reconnect
rather than by notification.

## 5. Slices

1. **This one.** Provisioning session, code in / code out, sealed bundle, claim,
   shared account identity, empty-but-listed chats on the new device,
   revocation that removes the device's keys and rotates own sender chains.
   Verified by both devices receiving new messages in a live run.
2. QR as an encoding of the same handle, once there is a device with a camera to
   test it on. The simulator has none, so the typed code is what a live run can
   exercise; the QR carries `provisionId` and `ephemeralKey` directly and skips
   `lookup`.
3. History transfer from the old device.
4. Account recovery when no device is left, if it is wanted at all.

## 6. Documentation this changes

`docs/protocol.md` gains the provisioning endpoints and the revocation
behaviour; `docs/crypto-flows.md` replaces "there is no login as a separate
operation" with the linking flow and states that the identity key belongs to the
account; `ROADMAP.md` closes the "log in on a new device" and multi-device lines.
