# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

One slot is open by the owner's word and taken: `msgid` on **run-msgid** — the
tail of rework step 2: the message's identity becomes `(chatId, seq)` and the
ULID goes away. The dispatcher runs a bug conveyor on main between ticks (the
owner's standing ask of 2026-08-21: fast wins, one after another) and finished
the localization pass — every product string is an English key with ru in the
catalog; the test-file tail is converted and being re-run before its commit.
`.claude/agents.tsv` holds only live work, so `scripts/agents.py` is the
picture of the site.

## On main, 2026-08-21 late evening — the solo roadmap run

A single agent working the easiest open ROADMAP items straight on main, one
commit each, live-run evidence in `docs/qa/runs/`: clipboard paste closed as
already-done (34000af); the chat list reorder animated and the stale
`.animation`-on-ForEach removed (ebb76d4); the row height held steady across
preview line counts — an owner report fixed the same hour (19e6bc6); the
unread capsule rolls and pops on an increment — an owner ask (6e8b32c); bulk
copy closed with units and a pasteboard read-back (e21a843); the passcode
block verified end to end (6f19bc8); blocking, the blocked list and the
resume of delivery verified, with a missing ru string for the blocked strip
added (23022c8); delete-for-me verified against a relaunch and the peer's
copy (ae2f165); the viewer's album paging and swipe-close verified and the
cache row's stale size fixed (48b2efa); swipe-to-reply and the text and album
quotes (638b3ae); header presence and group author names (521a59e); the
typing indicator in the header and the list (939a5eb). `msngrfixture` grew
`send` and `typing` subcommands along the way (db7b052, 939a5eb). Gates ran
green after each batch.

run-userdo (`b94698c`): identity keys, one-time prekeys and the E2EE device
list moved from D1 into the user's own Durable Object (`UserSessionDO` renamed
`UserDO`, wrangler migration v3 `renamed_classes`, storage preserved). The
prekey handout consumes inside the object, so two senders never draw the same
key; link/revoke bump `devicesVersion` and fan the `devices` frame from the
object. A first message costs 2 D1 statements instead of 7, both auth
(`docs/qa/runs/2026-08-21-userdo-run.md`). The "one object per user, not two"
decision is argued in `docs/research/2026-08-19-per-user-do.md`. The shared
stand's trio was re-seeded after the merge (old accounts had keys only in D1).
`msngrfixture answer` came along: a headless peer that receives and answers
through the real core, so a one-simulator scenario gets a live counterpart.

Dispatcher fixes on main the same day: twelve fixed defect entries moved from
the open list to closed where their fixes had been recorded all along, and
progress.py now shows defect counts and grows its bar against today's item
total (`4534593`); folder tabs, forward-picker rows and pin-pad keys got full
hit areas (`152e106`); a message deleted for everyone is a bare tombstone —
no forward line, no reply strip (`cc00390`); the request screen's block button
paints its own destructive red instead of the accent (`48592cb`). The feed's
strings moved to English keys (`fdb9c47`), and the unread-marker and
participants counters that had been hardcoded in English on that path went
through the catalog's plural forms.

## Merged on 2026-08-21, night

run-msgid (`229389b`): a message is identified by `(chatId, seq)` and the minted
msgId ULID is gone — from the client's schema, from the frames and from the
REST. `delete` carries seqs, and the pin, the reply preview, the reaction, the
edit target, the search hit and the jump request all name a message the same
way; "not acknowledged yet" is now the absence of a seq rather than a temporary
id. The branch had to be finished by hand: the agent reported the work done
with nothing committed, so the dispatcher committed it, merged main into it
twice (main moved by fifteen commits under it), resolved sixteen conflicts, and
found one red — `UnreadRecountTests` inserted into `pendingDecrypt` a `msgId`
column the new schema does not have (`0c3f084`, the recount logic untouched).
Checked before landing: `swift test` 382 with 0 failures, MsngrTests 205 with
0, and the server smoke on a stand of its own through `scripts/smoke-stand.sh`
— ALL PASS, 265 checks. The 22 failures an earlier smoke run showed were
another session's APNs mock holding the shared push port, not the branch.
The client schema changed in place, so the fixture trio was reseeded
(`alfa3`, `bravo3`, `charlie3`).

## Merged on 2026-08-21

run-reactions (`1482c31`): a tap on a group reaction capsule opens who reacted,
grouped by emoji; a forward carries the quote preview and the original author
(reactions deliberately do not travel — Telegram's choice, written into
docs/protocol.md); an edited message keeps every text it has shown and the
context menu opens the history. The run watched the block's five unwatched
claims live over two fixture simulators and found and fixed two defects of its
own — a forwarded album arriving with no «Переслано от…» line, and that line
unreadable on own dark bubbles
(`docs/qa/runs/2026-08-21-reactions-forward-run.md`).

run-feedextras (`9d233b2`): group feeds show sender avatars — the column is
reserved in the layout plan, the picture rides the last message of a run — and
the current day floats as a sticky capsule under the header while the reader
scrolls, yielding to the real separator at the boundary. The run's pixel diff
holds the anchor rule: an incoming message while reading history moved nothing
but the unread badge (`docs/qa/runs/2026-08-21-feedextras-run.md`). A defect
the run found — a doubled «Сегодня» capsule during the 0.3 s handoff fade —
was fixed in the branch.

run-devices (`34fbf01`): the set of a user's devices carries
`users.devices_version`, the `devices` frame names it, the sync answer confirms
it, and a reconnect marks cache entries suspect instead of dropping them — 9
device reads over 8 reconnects became 1, delivery 9/9
(`docs/qa/runs/2026-08-21-devices-version-run.md`). The migration is applied on
the shared stand. In passing it fixed `SyncEngine.start()` after `stop()`
leaving the outbox dead (one-shot wakeup streams), which only tests reach.

run-media (`0ebee18`): a photo, an album or a video is in the feed before its
preparation finishes — the row is written first and filled in as the work
completes, and the outbox only picks the message up once the file is on disk.
Nothing on that path rolls back; preparation retries in the background. The run
found and fixed a defect of its own — a sender's own bubble stayed on the blur
forever, because `MessageCell`'s reconfigure-in-place path repositioned an image
view without reloading it — and the numbers are in
`docs/qa/runs/2026-08-21-media-appears-on-send-run.md`: the bubble is up by
about 2 s for a five-photo album and for a video, with the tiles resolving
independently a second and a half later.

## Merged on 2026-08-20

run-pin (`1a3f008`, the pinned bar reaches a message a thousand behind the newest
and a pin applies to both members within a second — numbers in
`docs/qa/runs/2026-08-20-pin-depth-run.md`), run-longpress (`48dadad`, the
context menu clears the keyboard and one bubble is
lifted), and a run of the owner's device defects straight on main: the composer
caret that put «123» in as «231» (`33f30f8`), the empty-screen glyph that turned
to mud in the dark appearance (`5f95956`), list rows that answered only on their
letters (`324c4d2`), the chat search that fired a request per keystroke
(`3cdfbb9`), and the chat list's navigation bar coming back from a chat washed
out — its cause was the custom back button. Sends to accounts registered before
the identity binding no longer hang the whole outbox (`123a23d`), and the in-app
banner is laid out inside its own window band with tests holding that shape.
A run no longer starts at registration (`e005621`): `alfa`, `bravo` and
`charlie` live on the stand with the three direct chats between them and three
groups, all with history, and `scripts/fixture.py install <name> <udid>` hands
one of them to a simulator as a file copy with every permission already granted,
notifications included. `CLAUDE.md` holds the rules that come with it — one
simulator per home, `pull` before the next hand-out.

The socket now watches itself by the clock (`21f73fb`): `WSFreshness` holds the
rule — 8 s for a handshake, 4 s for a pong, 12 s of quiet — and `WSClient` asks
it once a second from the upgrade, so a stalled stream is caught by a tick
rather than by a callback that never comes. Death is noticed within 16 s at
worst instead of 24; the core suite is green at 363 tests and a 100-message
burst still lands in 410 ms.

Every fix has its story in `docs/qa/defects.md`; the gate ran green after each.

## In main since 2026-08-19

`run-delivery` — the fanout as an outbox (a delivery record per recipient that
lives until acknowledged, independent chains, retries with no attempt cap), the
push moved out of the delivery path into its own persisted queue, and the live
run in `docs/qa/runs/2026-08-19-delivery-run.md`: a 100-burst lands in 255 ms,
ticks follow within ~100 ms, and chats keep working with APNs fully down.
run-ticks' measuring pair (`BurstTicksTests`, `server/test/tick-burst.mjs`) came
along; both branches are deleted.

Also `run-crypto-identity` (identity binding, replay rule, sender key messages
signed whole) and `run-identityui` (username quarantine on migration 0005, the
folders screen in Russian with its own Edit/Done). All merged with a green gate.

The gate itself changed: `scripts/collect-crashes.sh` now fails on our own
crashes and only reports a launch failure of the XCTest harness, which had been
failing the gate off a stale runner bundle on a simulator that was not ours.

Two defects the owner reported were closed in `b73cc80`: a send nobody could read
now fails and stays in the outbox instead of showing a tick, and a deleted direct
chat can be opened again without waiting for the peer to write.

`docs/research/2026-08-19-per-user-do.md` holds the target backend: a DO per user
and per handle, subscriptions between objects instead of asking, and outbox to
inbox as the delivery guarantee.

## Not started, specified

- Reaction animations — waiting for a model that can debug animation frame by
  frame; the owner asked not to hand this to a general-purpose agent.
- `docs/protocol.md` and `docs/crypto-flows.md` are still in Russian and get their
  own pass.
- Splitting into three private repositories, and rewriting the commit history in
  English. The history also carries deleted screenshots and build artefacts, so
  `.git` is around 460 MB against 368 KB of docs.

## How agents are run

`.claude/ORCHESTRATION.md` holds it: two slots, a session per agent resumed with
`claude --resume`, and course corrections sent with `SendMessage` instead of a kill.
