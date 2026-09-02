# Where the work stands

Written 2026-08-19. This file exists because agent work lives on branches that
outlive the conversation that started them; without it a branch with a day of
work in it looks like clutter.

Delete an entry when its branch is merged and gone.

## 2026-09-02 evening — the goal: close every ROADMAP line that needs no device

The owner's standing goal (session `/goal`): close everything in ROADMAP.md
that does not need a phone. Read "needs a device" critically: showing a QR
code, scanning one from a picture, the NSE, real APNs on a simulator all work
without a phone. Truly device-only: the camera as a live input (shooting a
photo/video/story, live QR scanning), PushKit/VoIP and CallKit, Data
Protection on a locked screen, fps measurements, the extension-call ceiling
in an avalanche. There is no separate `calls` session any more: calls and
everything else are run from this session; at most one helper agent runs in
parallel (the owner's word, 2026-09-02 evening: two at once hit the token
limit).

Later the same evening, on main: the NSE family is closed live on the
simulator over real APNs (`docs/qa/runs/2026-09-02-nse-simulator-run.md`) —
468, 831, 842, 851, 853, 854, 858, 864, 773 are ✅; 829 stays 🟡 for the
burst only. Two things were in the way and are fixed: the fixture's
notification grant carried the old bundle id inside the archive (the topic
went non-waking and pushes for a killed app waited at Apple), and gate-runner
held stale PlugInKit registrations of the extension from old bundle ids
(`pluginkit -r`). Product fixes along the way: a mute from the banner goes
through the action queue and survives the snapshot race (`8e26381`), the
banner carries the message's picture (`8e26381`), a request's first push
names its author and the extension writes the request chat (`0872a16`,
deployed to the shared stand). The fixture trio was reseeded (alfa6, bravo6,
charlie6); bravo is on gate-runner, charlie on `fable-charlie`
(28CE558E-6C92-4220-8FC5-A762FCECB666), alfa is free in `.claude/fixtures`.
Helper `d1-leftovers` finished on `run-d1-leftovers` (rework step 6): five
commits, smoke green on its own stand (463 checks), live run in
`docs/qa/runs/2026-09-02-d1-leftovers-run.md`. Merged into main as `b12ef44`
on the owner's word («решение по стиранию стенда апрув»): migration 0022 drops
every remaining D1 table, the bearer token is `<userId>.<secret>`, and the
shared stand was stopped, its `.wrangler/` wiped, the code synced, migrations
applied, the service restarted and the trio reseeded (`alfa`, `bravo`,
`charlie` without the numeric suffix; bravo on gate-runner, charlie on
`fable-charlie`). Every other account on the stand, the owner's `Akuz` on
iPhone 17 dev included, has to register again. The smoke on the merged main
was green before the deploy; the worktree, the branch and the registry rows
are gone.

Later still: a muted chat's push travels silent and flagged and the extension
lets a mention or a reply through (`bcf2e68`, live on the simulator); the
smoke's deferred-send echo check raced the parallel fan-out under a host load
above ten and was made to wait (`2cd268b`, the only red of the evening's
gates, not the product). Helper `streaming` runs on `run-streaming` (ROADMAP
line «streaming over range requests»), session id in `agents.tsv`. What is
left open and needs no device is now gated on the owner: the `run-d1-leftovers`
merge (a stand wipe), iCloud backup and its passwordless key (an Apple ID
signed into a simulator), the GIF picker (a provider key), and history
transfer to a new device (touches the provisioning tables the D1 branch moves,
so it waits for that merge).

Late evening: `run-streaming` merged (media format 2 in blocks, the stream
serving ranges, the viewer playing from it — a 48 MB video started nine
seconds before its download ended on the helper's simulator; the helper seeded
its own `alfa2/bravo2/charlie2` on the shared stand). The iCloud backup is
built but not watched (`cb8fd78`): the key in the iCloud Keychain, the v3
seal, one CloudKit record with an asset, a daily processing task on a charger
with a network, «Восстановить из iCloud» on the registration screen; the
switch on the simulator is off with «iCloud недоступен на этом устройстве»
because no Apple ID is signed in, and the container has to exist on the
portal for the owner's team. ROADMAP 1198 and 1214 are 🟡 with that said.

After the merge: the history moves to a linked device (`38f0922`, ROADMAP 49
✅, `docs/qa/runs/2026-09-02-history-transfer-run.md`): the approving device
packs the backup payload, uploads it encrypted as an attachment and puts the
pointer into the sealed provisioning bundle; a third simulator linked as bravo
came up with every chat and message and sent a fresh-session message charlie's
extension opened. The streaming helper stopped on an account 429 and was
resumed with `claude -r`; its branch holds four commits (media format 2 in
blocks, the stream serving ranges, the viewer playing from it).

Also closed live the same evening: 773 (a request's push names its author and
the extension writes the request chat), 853 (group avatar in the banner), 859
(a reaction reaches the target's author with the app closed, `notifyUser`),
876 (the sound of a mention or a reply, «Sound: mentions and replies»), 50 and
690 (the link code and the safety number as QR codes read from a picture —
`docs/qa/runs/2026-09-02-qr-run.md`). New ⬜ lines record what these found:
a mention in a muted chat with the app closed gets no push at all today; the
camera as the QR reader is device work.

Landed on main today (this session): `ed5757e` one bundle id
`com.msngr.msngr` for every build and the simulator asking APNs for a real
token (the UDID/`dev-sim` path is a fallback only); `6f2a0ef` the extension
answers with a Communication Notification (sender avatar from the shared
`avatars/` cache, group members as recipients); `d155737` `make device` finds
a paired phone, CLAUDE.md corrected: the NSE does run on the simulator — the
owner showed a breakpoint in `didReceive` and a banner with the sender's
avatar on iPhone 17 dev. To find the extension in `log show`, filter by
`processImagePath CONTAINS "NotificationService.appex"`, not by process name.
The shared stand sends real pushes through the relay on adad; simulator
pushes arrive (relay log `→ 200`).

ROADMAP lines to move from what was seen today: 852 (sender avatar and name
through Communication Notifications) is done on the simulator; the NSE family
(829, 831, 842, 851, 854, 858, 468, 773, 853, 859, 864, 876) is now checkable
on a simulator with the extension attached from Xcode or by reading
`nse-journal.log` in the group container.

Open, no device needed, in the order simple-first: the NSE family above
(verify live, then implement 864 photo preview, 859 reaction push with the
app killed, 876 mention sound in the extension, 853 group avatar check);
1330 the last D1 tables into UserDO with the token carrying the userId so auth
is one call into the object; 1198 automatic backup on a charger over Wi-Fi;
49 moving history to a new device; 441 GIF picker and stickers; 272 streaming
media over range requests (block-wise sealing + AVAssetResourceLoaderDelegate);
50 and 690 QR: show the code on one simulator, scan it from a picture on the
other (`simctl addmedia` + the photo picker); 1214 iCloud passwordless backup
(needs a CloudKit container, try on the simulator with a signed-in account).
External blocker, not a device: 932 channel media through CF Stream/Images
has no binding.

Agents are started only the CLI way from `.claude/ORCHESTRATION.md`
(worktree in `.claude/worktrees/<name>`, `task.md` per
`.claude/task-template.md`, `nohup claude -p --session-id $(uuidgen) --model
<id> --permission-mode bypassPermissions "$(cat task.md)"`, a row in
`.claude/agents.tsv`), two slots, never the built-in Agent tool (the owner
stopped that twice; two such agents were killed tonight before doing
anything). Simulators in use: `44CE2242…` (owner's iPhone 17 dev) runs alfa
with the owner's Xcode attached to the NSE, `14C70E21…` (gate-runner) runs
bravo; both hold the current build. Fixtures: alfa on 44CE, bravo on
gate-runner, charlie in `.claude/fixtures`.

Device install (`make device` on iPhone15pm) is blocked on the portal, not on
code: Apple answers "device 00008130-001A00C2216A001C already exists on this
team" while the team profile excludes it (0xe8008012); the owner enables the
device on developer.apple.com, then `make device` goes through.

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
already-done (8e01228); the chat list reorder animated and the stale
`.animation`-on-ForEach removed (1e49b5b); the row height held steady across
preview line counts — an owner report fixed the same hour (08f9489); the
unread capsule rolls and pops on an increment — an owner ask (7f218de); bulk
copy closed with units and a pasteboard read-back (f3320d4); the passcode
block verified end to end (90798f8); blocking, the blocked list and the
resume of delivery verified, with a missing ru string for the blocked strip
added (e86dbf0); delete-for-me verified against a relaunch and the peer's
copy (936443d); the viewer's album paging and swipe-close verified and the
cache row's stale size fixed (f1f675e); swipe-to-reply and the text and album
quotes (c880c9f); header presence and group author names (7f4e086); the
typing indicator in the header and the list (f385ad5). `msngrfixture` grew
`send` and `typing` subcommands along the way (d9efbc2, f385ad5). Gates ran
green after each batch.

run-userdo (`4caf2c6`): identity keys, one-time prekeys and the E2EE device
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
total (`c3379ad`); folder tabs, forward-picker rows and pin-pad keys got full
hit areas (`3b9f942`); a message deleted for everyone is a bare tombstone —
no forward line, no reply strip (`fc55c81`); the request screen's block button
paints its own destructive red instead of the accent (`ab89288`). The feed's
strings moved to English keys (`9a62448`), and the unread-marker and
participants counters that had been hardcoded in English on that path went
through the catalog's plural forms.

## Merged on 2026-08-21, night

run-msgid (`94c0477`): a message is identified by `(chatId, seq)` and the minted
msgId ULID is gone — from the client's schema, from the frames and from the
REST. `delete` carries seqs, and the pin, the reply preview, the reaction, the
edit target, the search hit and the jump request all name a message the same
way; "not acknowledged yet" is now the absence of a seq rather than a temporary
id. The branch had to be finished by hand: the agent reported the work done
with nothing committed, so the dispatcher committed it, merged main into it
twice (main moved by fifteen commits under it), resolved sixteen conflicts, and
found one red — `UnreadRecountTests` inserted into `pendingDecrypt` a `msgId`
column the new schema does not have (`3d6fe71`, the recount logic untouched).
Checked before landing: `swift test` 382 with 0 failures, MsngrTests 205 with
0, and the server smoke on a stand of its own through `scripts/smoke-stand.sh`
— ALL PASS, 265 checks. The 22 failures an earlier smoke run showed were
another session's APNs mock holding the shared push port, not the branch.
The client schema changed in place, so the fixture trio was reseeded
(`alfa3`, `bravo3`, `charlie3`).

## Merged on 2026-08-21

run-reactions (`ac437b2`): a tap on a group reaction capsule opens who reacted,
grouped by emoji; a forward carries the quote preview and the original author
(reactions deliberately do not travel — Telegram's choice, written into
docs/protocol.md); an edited message keeps every text it has shown and the
context menu opens the history. The run watched the block's five unwatched
claims live over two fixture simulators and found and fixed two defects of its
own — a forwarded album arriving with no «Переслано от…» line, and that line
unreadable on own dark bubbles
(`docs/qa/runs/2026-08-21-reactions-forward-run.md`).

run-feedextras (`214d2d1`): group feeds show sender avatars — the column is
reserved in the layout plan, the picture rides the last message of a run — and
the current day floats as a sticky capsule under the header while the reader
scrolls, yielding to the real separator at the boundary. The run's pixel diff
holds the anchor rule: an incoming message while reading history moved nothing
but the unread badge (`docs/qa/runs/2026-08-21-feedextras-run.md`). A defect
the run found — a doubled «Сегодня» capsule during the 0.3 s handoff fade —
was fixed in the branch.

run-devices (`216767b`): the set of a user's devices carries
`users.devices_version`, the `devices` frame names it, the sync answer confirms
it, and a reconnect marks cache entries suspect instead of dropping them — 9
device reads over 8 reconnects became 1, delivery 9/9
(`docs/qa/runs/2026-08-21-devices-version-run.md`). The migration is applied on
the shared stand. In passing it fixed `SyncEngine.start()` after `stop()`
leaving the outbox dead (one-shot wakeup streams), which only tests reach.

run-media (`5a830c2`): a photo, an album or a video is in the feed before its
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

run-pin (`3fccbad`, the pinned bar reaches a message a thousand behind the newest
and a pin applies to both members within a second — numbers in
`docs/qa/runs/2026-08-20-pin-depth-run.md`), run-longpress (`d21c14e`, the
context menu clears the keyboard and one bubble is
lifted), and a run of the owner's device defects straight on main: the composer
caret that put «123» in as «231» (`d54cafd`), the empty-screen glyph that turned
to mud in the dark appearance (`ec1eed7`), list rows that answered only on their
letters (`91d6bb7`), the chat search that fired a request per keystroke
(`f1a839d`), and the chat list's navigation bar coming back from a chat washed
out — its cause was the custom back button. Sends to accounts registered before
the identity binding no longer hang the whole outbox (`38ecdd5`), and the in-app
banner is laid out inside its own window band with tests holding that shape.
A run no longer starts at registration (`9bff7ee`): `alfa`, `bravo` and
`charlie` live on the stand with the three direct chats between them and three
groups, all with history, and `scripts/fixture.py install <name> <udid>` hands
one of them to a simulator as a file copy with every permission already granted,
notifications included. `CLAUDE.md` holds the rules that come with it — one
simulator per home, `pull` before the next hand-out.

The socket now watches itself by the clock (`c847f9d`): `WSFreshness` holds the
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

Two defects the owner reported were closed in `f75ec3b`: a send nobody could read
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
