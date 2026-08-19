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

A user is not a chat. Someone can be in the contacts with a name and an avatar of
this device's own choosing and never have a conversation, so the two objects own
different things: the chat object owns the correspondence, the user object owns
the person. The id of a direct chat stays derived from the two user ids, sorted,
which is what `directChatName` already does.

## Subscription instead of asking

The client's only counterpart is the API in front of its own object; nothing else
is addressable from outside, and no request of a client reaches another person's
object. Freshness comes from a subscription between objects.

Starting a conversation with someone, or putting them in the contacts, makes the
user's own object subscribe: an RPC to that person's object, which answers with
the current snapshot — name, avatar, presence, identity keys and the signed
prekey, the privacy settings, the stories — and remembers the subscriber. Every
later change fans out over that list, so the object always holds a fresh copy and
one call to the API answers for every peer at once.

The source decides what to put in the snapshot and in the delta for a given
subscriber, which is what makes a privacy setting real rather than a checkbox: a
hidden last seen is not in the payload, and a block drops the subscriber at the
source. Unsubscribing on a removed contact or a deleted chat is part of the
mechanism, otherwise the lists grow forever and changes are broadcast to nobody.

Copies of another object's data are normal here, not a compromise: DO storage is
ours, unreachable from a client, and what a client is allowed to see is decided by
the API, not by where the bytes sit. Trust in keys is a separate matter and stays
on the device: the copy carries the signature over each identity, TOFU decides.

One-time prekeys are not pre-distributed. The first message to a device the sender
has no session with is one RPC from the sender's object to the recipient's, since
the address is derived from the user id; the client is not involved and is holding
its first tick by then.

## Delivery is outbox to inbox

The sender's object writes the message and an outbox record in one transaction. A
persisted task carries it to the recipient's object, which writes an inbox key
(`from:<userId>/<msgId>`) and the message in one transaction of its own, and
answers "already have it" to a repeat. Only that answer clears the outbox record;
until then the task is retried with a growing pause and is never given up on.

What we have today is the first half without the second. The fanout queue in
`ConversationDO` is an outbox — a persisted job, a cursor, a backoff — but it drops
the frame after three attempts (`FANOUT_MAX_ATTEMPTS`, pauses of 200 ms and 1 s),
and `UserSessionDO./event` applies whatever arrives with no idempotency key at
all. Nothing is lost only because the journal sits in the chat object and the
client's catch-up asks for what its cursors are missing: the safety net is the
journal, not the delivery. A repeat after a delivery that had in fact succeeded is
sorted out by the client, by `msgId` and by the `notificationShown` claim.

With the journal in a user's object that net is gone, so the inbox side is not
optional. Versions stay where they belong — reconciling a snapshot on subscribe —
and have nothing to do with the delivery guarantee.

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
