# A Durable Object per user, and per handle

Written 2026-08-19, after `identity_keys` on the shared stand held 2360 rows of
which 2357 carried an empty signature and every send to those devices produced an
envelope addressed to nobody.

## What is wrong with the shape we have

Identity keys, one-time prekeys, devices and push tokens all live in one D1
database, and D1 is one SQLite file with one writer. That puts three things on the
hot path of every message:

- a prekey bundle is read out of a table shared by every user in the system;
- a one-time prekey is *deleted* there, so a first message to a new device is a
  write against the same single writer as everyone else's;
- a device list is read the same way (`GET /api/devices` on every send, still
  uncached).

None of that is per-user work by nature, and none of it needs a global index.
D1 also has a hard ceiling per database, so growth ends in sharding a schema that
never had a reason to be global.

## The target

**A DO per user**, addressed by `env.USER_DO.idFromName(userId)`, owning
everything that belongs to that person: the identity key with its signature, the
signed prekey, the one-time prekeys, the device list with tokens, the profile,
the blocked list. Reads and writes are serialized inside it by construction,
which is what a prekey handout and a device change actually need. A message to a
person touches that person's object and nothing else.

**A DO per handle**, addressed by `idFromName(username)`, owning the answer to
"who is this". Claiming a handle is a write inside the object for that exact
name, so uniqueness comes from the addressing and needs no unique index; the
quarantine after a rename is a timestamp in the same object. Taking a handle is
then a two-step commit between the handle object and the user object, and the
handle object is the authority.

`ConversationDO` stays what it is: the journal of one chat.

## The device set is pushed, not polled

Once a user's object owns their devices, nobody has to ask for them. The object
keeps a version on the set and a list of the objects that hold a replica of it.
Adding or revoking a device bumps the version and sends an RPC to each of them;
they store the new set and push a frame to whatever sockets they have open. A send
then reads a local replica: no HTTP call before a message, and no cache to drop on
a reconnect. The client compares one number after reconnecting, so a change missed
while the socket was down is picked up by that comparison instead of by throwing
every list away — which is what `SyncEngine` does today on every `connected`.

Who holds the replica follows from the chats, not from anyone's contact list.
Keys of another device are needed exactly when there is a chat with it, and
`ConversationDO` already knows its members. Deriving the subscription from
contacts would mean a person's object holding "these people added me", a
disclosure the product does not make anywhere else and does not need: without a
chat there is nothing to encrypt.

The replica is a cache of signed material, never the authority. The set travels
with the signature over each identity, trust stays on TOFU on the device, and a
message from a device the replica does not know refreshes that one user rather
than being refused.

The cost to keep in view: a person in a very large number of chats turns one
device change into a wide fan of RPCs. Device changes are rare, but that fan needs
the batching and the retries the message fanout already has, not a single call.

## What this costs, honestly

Prefix search over handles has no answer in this shape: `idFromName` finds an
exact name and nothing near it. People search needs its own index — sharded
objects keyed by a short prefix, or one search object per letter, or an index
outside the request path. This is the one thing to design before the move, not
after.

The same goes for discovery by a phone number's hash: it is a lookup by an exact
value, so it is another `idFromName` namespace, but the OPRF design it depends on
is not written down yet.

D1 keeps nothing on the hot path after the move. What might still want a
relational shape — invites, media rows — is small, cold, and can be decided
separately.

## How the move happens

There is no backward compatibility to keep: the database is wiped and users
register again, which is the same cost as today's schema change. The order that
keeps the product working at each step:

1. `UserDO` with the identity, the prekeys and the device list; registration
   writes there; `/api/users/:id/prekeys` and `/api/devices` read there. D1
   copies stay, unread.
2. `HandleDO` for the claim and the quarantine; registration and rename go
   through it. The people-search index is built at the same time, because
   dropping the `users` table takes the query with it.
3. Push tokens and the profile follow.
4. The D1 tables that are left over are dropped in one commit, with the schema
   version bumped.

Until step 1 lands, the fix for a device with no signature is
`POST /api/identity`: the device publishes the binding itself on start, so an
account that predates the signature heals without the person doing anything.
