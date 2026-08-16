# Crypto flows

Code: `ios/MsngrKit/Sources/MsngrCrypto/*` (primitives), `MsngrCore/E2EE.swift`
(the pipeline), `MsngrCore/KeyStore.swift` (storage and TOFU).

## Registering a device

`POST /api/register` carries only the public parts: identity DH (X25519),
identity signing (Ed25519), the Ed25519 signature over the X25519 key, a signed
prekey with its signature and 100 one-time prekeys. The private parts sit in the
database, encrypted with the master key (`StateCrypto`, ChaChaPoly).

## The two halves of an identity

CryptoKit does not convert between the curves, so an identity is two keys rather
than Signal's one. They are held together by a signature: the Ed25519 key signs
the X25519 key (`IdentityBinding`), and that signature travels with the pair
everywhere the pair goes — registration, a linked device's claim, `/devices`,
`/prekeys` and the `pk` envelope. Every use of a peer's identity verifies it.

Both keys go into the safety number, and trust is pinned on the signing key. The
binding is what makes those the same statement: it is the X25519 key that
messages are encrypted under, and without a signature over it, a pinned signing
key and a verified safety number would both be silent about the key actually in
use.

## Whose identity: the account's, not the device's

The identity pair (X25519 + Ed25519) is created at registration and belongs to
the **account**: devices the owner authorizes later get a copy of it. The signed
prekey, the one-time prekeys, the ratchet states, the sender key and the master
key are each device's own.

It is built this way because trust in `trustedIdentity` is keyed by `userId`, and
a sender checks that key on **every** device of the recipient. A device with its
own pair would drop sending into `identityChanged` for every peer. The other side
of it matters more: a device the server made up cannot present the account's key,
so the peer's TOFU fires on it. The safety number does not change when a device
is added.

The price is stated plainly: any authorized device holds the account's private
identity. One stolen together with readable storage can impersonate the account;
revocation takes away access to the server, but not knowledge of the key. There
is no identity rotation for an account.

## Signing in on a new device

There is no password and no phone number: a new device is let into the account by
one that is already in it.

1. The new device generates an ephemeral X25519 pair and opens a provisioning
   session (`POST /api/provision/start`), receiving an eight-character code and a
   `provisionToken` — the session secret that only it knows.
2. The owner types the code on the old device. `POST /api/provision/lookup`
   returns the ephemeral public key and the device name, and the screen names
   exactly what is asking for access.
3. The old device seals the account bundle (`userId`, username, display name, the
   private identity DH and signing keys) to that ephemeral key:
   X25519 → HKDF-SHA256 → ChaChaPoly, with `provisionId` as the salt and both
   public keys in `info`. The server carries the result and cannot open it.
4. The new device decrypts the bundle, shows the `@username` and asks for
   confirmation: a stranger's account could have approved the session if the code
   was guessed.
5. `POST /api/provision/:id/claim` under the `provisionToken` registers the
   device: fresh prekeys of its own, identity from the bundle. The server checks
   that the identity keys presented match the account's keys, otherwise
   `identity_mismatch`. An answer with a different `userId` is treated by the
   device as a refusal, and it wipes itself.

The conversation history does not move over: the ratchet destroyed the keys of
what was read, and what sits on the server is envelopes addressed to other
devices. The new device gets the chat list and starts each chat at its current
end (`DeviceLink.primeChats`); anything older does not exist for it.

While at least one device is in hand, access is not lost. Once none are left, the
account cannot be recovered: there is no recovery phrase and no password.

## The first message to a peer

1. `GET /api/devices?ids=…` — the recipient's device list (and your own other
   devices) with identity keys. This request spends nothing.
2. For every device that already has a session, we encrypt with the existing
   Double Ratchet — no bundle is requested.
3. The full bundle `GET /api/users/:id/prekeys` is fetched only when a device
   without a session turns up, and only once per user per send. The server then
   hands out and deletes one one-time prekey per device.
4. The signed prekey's signature is verified before X3DH; on failure the session
   is not established.
5. The first message goes out as `pk`: inside is the ratchet message, outside are
   our identity DH and signing pub, the ephemeral and the ids of the prekeys used.
6. The other side builds a responder session from its private prekeys, marks the
   one-time prekey spent, and from there both sides are on `dr`.

Your own other devices are always in the list of addressees — the echo of your
own messages is end-to-end too.

## Topping up one-time prekeys

Once per session `SyncEngine` asks `GET /api/prekeys/count`; if fewer than 20 are
left on the server, it generates up to 100 and uploads them with
`POST /api/prekeys`. A network error clears the "already checked" flag, so the
attempt repeats on the next `start()`.

## Sessions out of step

An incoming message is tried against the active session first, then the archived
ones (up to 5 per device). If a `pk` matched none of them, the active session is
archived and a new one is built from the bundle — that is how simultaneous
initiation (glare) and the mismatch after a reinstall are resolved. Two
candidates are tried in the process: with a one-time prekey and without one (the
key may have been spent already by a repeated bundle handout).

A `dr` that no session matched, and a group message with no sender key, are not
lost: the envelope goes into `pendingDecrypt` and is replayed when the key
arrives.

## TOFU and a key change

The first identity signing key seen for a peer is stored in `trustedIdentity`. On
sending, the keys of **all** the recipient's devices are checked, not just the
first. A mismatch is written into `changedPending` and drops the send with
`identityChanged`:

- the outbox row moves to the `blocked` state and the message is shown as unsent;
- a system message is inserted into the chat, which the UI draws as «Код
  безопасности собеседника изменился»;
- a banner appears in the chat: messages are not sent until the key is accepted;
- `acceptKeyChange` moves `changedPending` into the trusted key, clears
  `verified`, returns the blocked messages to `ready` and wakes the outbox.

In an incoming `pk` a key change does not block decryption: the content is
applied, but the same system warning is inserted next to it. A `pk` whose
identity keys are not signed as a pair is not opened at all — there is nothing
to warn about when the sender is whoever wrote the envelope.

A `pk` that repeats a handshake this device has already run is refused as well.
A responder session keeps the initiator's ephemeral key, and a second envelope
carrying it changes nothing: the session it would build is the one already in
place. A peer that really started over brings an ephemeral of its own and gets a
new session, with the previous one moved to the archive once a candidate has
opened the message.

## Which chat a message belongs to

A pairwise message names its chat inside the sealed box, and the recipient
compares that with the chat the envelope was delivered in. They differ only if
the server moved the message, and then it is not shown: the chat it belongs to is
the one the sender named. A group message needs no such check — the sender key
chain is stored per chat, so a message moved elsewhere finds no chain at all.

Verification out of band is the 60-digit safety number in the chat info (5200
iterations of SHA-512 over each fingerprint, with the two sides sorted, so the
number is the same for both). A fingerprint covers both identity keys.

## Groups

The first message to a group hands out the sender key: `skd` travels as a
separate pairwise message to the devices that have not received it yet, and is
marked as a service frame. The handout's `clientMsgId` is deterministic over
`(chatId, keyId, the set of addressees)`, so a retry of the same handout is
swallowed by the server's dedup while a handout to a new device goes through.

The message itself is encrypted with the chain (`skm`) and signed with the
chain's Ed25519 key. A member leaving the group rotates our chain: the old one is
deleted, and the next send hands the new one out to those who remain.

## Media

A file is encrypted with a random 256-bit key (ChaChaPoly); only the ciphertext
goes to R2. The key and the SHA-256 of the ciphertext travel inside the E2E
message. On download the hash is checked before decryption. A video's preview
frame is a blob in its own right, with its own key.

## Contact discovery

The phone number is optional. Only the SHA-256 of the number in E.164 goes to the
server: `POST /api/phone` for your own number, `POST /api/contacts/discover` to
find people you know. The privacy is weaker than Signal's with SGX — a known
limitation; numbers are not stored in the clear.

On the client: access to the address book is requested only on an explicit
action, numbers are normalized to E.164 (the Russian `8XXXXXXXXXX` is rewritten
as `+7…`) and hashed in a batch; a name from the address book takes precedence
over the server's one in the list.

## Where the keys live

- The master key is the `.masterkey` file in the app group container, Data
  Protection `completeUntilFirstUserAuthentication` (available to the NSE after
  the first unlock). There is also a Keychain implementation of
  `MasterKeyProvider`; the app uses the file-based one.
- Identity, private prekeys, ratchet states and sender keys are in SQLite, each
  value sealed with the master key.
- The PIN is stored as SHA-256(salt + pin) in `UserDefaults`; it has nothing to
  do with encrypting the conversation.

## Who steps the ratchet

Decryption lives in `IncomingDecryptor`: it needs the device's keys and does not
need the network, so both the app and the Notification Service Extension hold it
— the push brings the envelope and the extension opens it.

Two processes over one file mean the "read the state — step — write" cycle has to
be kept apart. `CryptoGate` keeps it apart: `flock` on the `.cryptogate` file in
the group container plus a lock inside the process. The rules — the gate is taken
before the database transaction and is not held across an `await`; the extension
additionally does the step and the message write in a single transaction
(`IdentityStore.joining`), so an extension killed by the system leaves neither a
step without a message nor a message without a step.

The heart of the problem is not a lost incoming message (the symmetric chain is
derived again), it is the sending side: someone else's write on top rolls `sendN`
back, the number goes on the air twice, and the second message is one the
recipient will never open.
