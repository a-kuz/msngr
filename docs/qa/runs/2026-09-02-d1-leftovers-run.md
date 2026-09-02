# The last of D1 follows its owner into an object

The closing step of the per-user-DO rework (`docs/research/2026-08-19-per-user-do.md`):
what was still a shared table — the profile, the device list with its bearer
tokens and push tokens, the blocks, the privacy tiers with their named
exceptions, the provisioning and restore sessions, the invite codes, the
reports, the phone-hash discovery index and the media rows — is now held by
whoever it belongs to. Nothing on any path reads D1; the `DB` binding is out of
`Env`, so that is a property of the code rather than a number that happened to
come out zero.

Run date: 2026-09-02, branch `run-d1-leftovers`.

## The one thing that had no owner: the token

`authenticate` resolved a bearer token by `devices.token_hash`, a global lookup
no per-user object can answer. A token is now shaped `<userId>.<secret>`: the
account part names the object that owns the device list, and that object holds
the SHA-256 of the whole token under `tok:<hash>`. The hash covers the account
id, so a secret lifted from one account proves nothing on another, and a
revoked device loses its session record and its `tok:` entry in the same write
that closes its sockets and drops its keys.

With that, every remaining read had somewhere to go.

## Where the tables went

- **`users`, `devices`** → `UserDO`: `profile` (the card plus the phone hash and
  the created-at the account itself reads), `dev:<deviceId>` (name, token hash,
  created-at, last-seen) and `tok:<hash>`. Registration, the provisioning claim
  and the restore claim write the keys, the card and the first session in the
  same storage put as the prekeys: an account is either whole in the object or
  was never opened.
- **`blocks`** → both objects of the pair: `blk:<peerId>` in the blocker's,
  `blkby:<peerId>` in the blocked one's, written by the blocker. Either side
  answers for the pair in one read, which is what `ConversationDO` asks on the
  send path.
- **`privacy_settings`, `privacy_exceptions`** → `UserDO`: `privacy` and
  `pex:<setting>:<peerId>`. The whole judgement — the tier, the named
  exception, and the address book that «contacts» means — now runs inside the
  owner's object, so `privacyAllows` is one call where it used to be three
  statements plus a call.
- **`provision_sessions`, `restore_sessions`, `invites`** → `LookupDO`, one
  object per key: `prov:<id>`, `pcode:<code>`, `rest:<id>`, `inv:<code>`. These
  are the three things a caller names before it has an account to be asked
  about, so they cannot live in a user's object. `/claim` is what a fresh code
  wins against, and `/patch` with a guard is what one approval and one claim of
  the same session are settled by; an expired record reads as free, so nothing
  has to sweep.
- **the phone-hash index** → `DirectoryDO`, beside the people index, in a
  `phones` table sharded by the hash. A discovery call carries thousands of
  hashes and each shard is asked only for its own.
- **`reports`** → the reporter's object, `rep:<ulid>`. Nothing in the server
  reads reports back; keeping them with the account that filed them is what the
  shape allows, and a moderation view will need its own home when there is one.
- **`media`** → nowhere. The table was written on every upload and read by
  nobody: the blob is in R2 and its size comes back from `MEDIA.head`.
- **the avatar's owner.** `GET /api/avatar/:id` withheld the bytes of a hidden
  photo by `SELECT id FROM users WHERE avatar_id = ?` — an index from a blob
  back to an account, which no object can hold. A user avatar now names its
  owner in its id (`avatar-<userId>-<ulid>`), so the rule is asked of the right
  object; a chat avatar has no owner part and stays open to any authenticated
  caller.

## Two reads that had to stop costing a fan

Dropping `users` takes with it two queries that answered for many people at
once, and replacing each with a call per person would have been worse than what
was there.

- **The roster's names.** `ConversationDO` holds a copy of each member's public
  card under `card:<userId>`, fetched once when they join and rewritten by the
  `/profile` frame their own object already fans out. A member list costs no
  call at all now, and `anyBot` reads the same copies instead of asking D1
  whether any of the roster is a bot.
- **The chat list's photos.** The photo and the bio are per-viewer, so a public
  copy cannot answer them. The presence subscription that already exists between
  every pair sharing a chat now carries the card too: `pcard:<T>` in the
  subscriber's object is T's card as T's own avatar rule lets that one
  subscriber see it. `GET /api/chats` reads the names off the chat states it
  already fetches and the photos off its own copies, and calls nobody. A member
  with no copy — a roster too large for presence relations to be built over — is
  asked directly, so the answer stays right where the cheap path does not reach.

## The last-seen rule, moved to where it is free

«Hiding your own last seen blinds you to everyone else's» used to be a query
over the viewer list at the source. With the tiers inside each object that would
have become a fan of calls on every presence flip. It is enforced at the
subscriber instead: `/peer-presence` refuses a copy while its own tier is
«nobody», and setting the tier drops the copies it holds. Same behaviour, one
storage read.

The «contacts» tier still needs the viewer's current phone hash, which is read
from the viewer's own object at the moment the question is asked — the property
the smoke pins as "a number that registers later needs no propagation into
anyone's book". That is the one cross-object call left in a privacy check, and
only when a tier is not the default.

## D1 statements per path, before and after

Measured on the own stand (`PERF_LOG=1`, port 8811) by running
`node test/smoke.mjs` against the code before the move; the counter was the
`d1` field of the worker's HTTP line and of each object's PERF line.

| path                                  | before  | after |
|---------------------------------------|---------|-------|
| `POST /api/register`                  | 3       | 0     |
| socket connect, worker                | 2       | 0     |
| socket connect, `UserDO./ws`          | up to 4 | 0     |
| a message in a direct chat, `/send`   | up to 2 | 0     |
| its fanout, `/events`                 | 1       | 0     |

The "up to" numbers are the maxima over the run: the socket's four are the
presence broadcast the first socket makes (the tier, the exceptions, the blocks,
the viewers' own tiers), and the send's two are the block check of a direct
chat — a group send never had one. The after column is not a measurement: the
counter is gone along with `wrapDB`, because `Env` has no `DB` for anything to
count.

## Verified

- `node test/smoke.mjs` against the own stand (`wrangler dev --port 8811`,
  `--persist-to .wrangler-d1lo`): **ALL PASS**, 460 checks, including the
  provisioning and restore sessions, bots and their token rotation, the
  contacts tier of discovery and of the profile card, allow and deny
  exceptions, blocks, the avatar bytes of a hidden photo, invite links and the
  whole stories block. One check is new — «the chat list carries a peer's
  avatar» — because the path that answers it was rewritten and the smoke only
  pinned the blanked case.
- `npm run typecheck`: clean.
- `grep -rn 'env.DB\|D1Database' server/src`: nothing.
- Live run on two simulators (`d1lo-a`, `d1lo-b`, iPhone 17) against the own
  stand, with the trio seeded onto it from scratch
  (`scripts/fixture.py seed --base http://localhost:8811 --reset`: three
  accounts, three direct chats, three groups, all through the real core, so
  registration, prekey handouts and first messages all ran through the object
  paths). Pushes went to Apple's sandbox through the relay on `adad` over an
  ssh tunnel, so the extension was launched by a real push.
  - alfa's chat list opened on names, avatars, unread counts and bravo's
    presence dot; the direct chat showed decrypted history with read ticks.
  - bravo's app killed, alfa sent a message. The extension came up one second
    later (`launchd_sim`: «Successfully spawned NotificationService»), and its
    journal reads `received … envelope` → `stored` → `answered … show`. The
    icon carried the badge 2 with the app not running; on launch the message
    was in the feed and readable.
  - bravo blocked alfa from the profile screen. `/api/blocked` came back with
    alfa in it (the profile now offers «Разблокировать»), and the message alfa
    sent after the block is not in bravo's feed — the chat shows «Вы
    заблокировали этого пользователя».
  - a fresh account registered through the registration screen on bravo's
    simulator and opened on its chat list.
  - Zero unreadable messages. 98 requests answered 200 and 7 sockets upgraded
    over the whole run, no 4xx and no 5xx.

## Not done, and one thing to know before the merge

- **The shared stand needs the migration and a reseed.** `0022` drops every
  table, and there is nothing to migrate the rows into — the objects are the
  new home and they are empty for accounts that predate this. After the merge:
  rsync `server/` to `adad`, `./node_modules/.bin/wrangler d1 migrations apply
  msngr --local`, wipe `/root/msngr/server/.wrangler/`, restart
  `msngr-wrangler`, then `scripts/fixture.py seed --reset`. Every account on the
  stand registers again, which is the same cost as any schema change here
  (`docs/PROCESS.md`).
- `POST /api/dev/reindex` is gone: it existed to walk the `users` table into the
  handle and directory objects, and there is no table to walk.
- Reports are kept with the reporter and nothing reads them. If moderation ever
  wants a list across accounts, that is an index of its own, not a table.
