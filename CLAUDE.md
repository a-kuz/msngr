# Working in this repository

An E2EE messenger: Swift clients (iOS, macOS) + a Cloudflare Worker.
There is no production and there are no users.

A session that is told nothing more than «продолжай» (or «continue») knows
what to do: read `docs/PROCESS.md` and `docs/BACKLOG.md`, move into a
worktree of its own, claim the topmost free line of the backlog (its name in
`who`, committed to `main` before any other work so two sessions never take
one line), do it to the end — code, the layer's check, the live run, the
merge into `main`, the backlog line closed, the report — and take the next.
It stops for nothing but a product decision, which it leaves in the
backlog's last section and moves on past. The owner reads
`scripts/progress.py` and the reports, and does not orchestrate.

## Layout

```
server/src/index.ts        HTTP API (hono) + the /ws upgrade
server/src/do/             every piece of server state; the map is in docs/protocol.md,
                           «Where the server keeps things»
server/src/push/apns.ts    APNs
server/migrations/         D1 migrations (wrangler d1 migrations apply); the database is empty
ios/MsngrKit/              the core: MsngrCrypto (primitives), MsngrCore (database, WS, SyncEngine, E2EE)
ios/Msngr/                 the iOS app
ios/NotificationService/   the NSE
ios/project.yml            the project description for xcodegen
```

Documentation: `docs/PROCESS.md` (how work runs: a worktree per session, the
one backlog, the gate job), `docs/BACKLOG.md` (the only list of open work),
`ROADMAP.md` (product status), `docs/protocol.md` (frames and API),
`docs/crypto-flows.md`, `docs/ui-spec.md`, `docs/localization-catalog.md`,
`docs/audits/` (the reasoning behind backlog lines), `docs/qa/runs/` (the
evidence), `docs/research/`.

## Building and testing

```bash
cd ios && xcodegen                                  # required after editing project.yml
scripts/build-slot.py xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr \
  -destination 'id=<UDID>' build
scripts/build-slot.py xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr \
  -destination 'id=<UDID>' test -only-testing:MsngrTests
cd ios/MsngrKit && ../../scripts/build-slot.py swift test    # the core
cd server && node test/smoke.mjs                    # API/DO/pushes, needs wrangler dev
```

Every build and every test run goes through `scripts/build-slot.py`: several
agents share this host, and six xcodebuilds at once took the load average past
600 and started failing tests on timing instead of on code. The wrapper holds one
of two slots for the duration of the command and releases it with the process.

`ios/Msngr.xcodeproj` is in `.gitignore` and is generated from `ios/project.yml`.
Do not edit `.pbxproj` by hand — the next `xcodegen` will overwrite the edits. The
entitlements of the app and the extension are built from `project.yml` too
(`entitlements.properties`), so editing `.entitlements` is pointless.

The signing team is machine-local and stays out of git: the project includes
`ios/Config/Local.xcconfig`, which optionally includes the gitignored
`ios/Config/Signing.xcconfig` with a single `DEVELOPMENT_TEAM` line. Without
that file the project still generates and builds for the simulator.

`swift test` in MsngrKit: `CoreIntegrationTests` skip themselves if nothing
answers on :8787; the rest of the tests need no server.

## The checks around delivery

Delivery is closed by the check of the layer the change touched, and that one
is waited for: `swift test` for MsngrKit, `node test/smoke.mjs` for the server,
MsngrTests for the app — plus the live run of the scenario.

The full gate — `make check`: `xcodegen` → build → `swift test` → MsngrTests →
the server smoke test on a throwaway stand → collecting fresh simulator
crashes — is run by a launchd job, not by hand: `scripts/gate-watch.py` sees a
new commit on `main`, checks it out into `.claude/gate-wt` and runs the gate
there on gate-runner, appending one line to `.claude/gates/status.tsv` (sha,
time, green or red, the log). Nobody waits for it before merging (the owner's
call, 2026-08-19: its reds had been the host, not the code, every time); a red
line is a defect report against that commit, fixed forward. Do not run `make
check` in a checkout somebody is editing — it measures nothing; `scripts/
gate-watch.py --once` gates main's head now if you want it sooner.

The UI smoke — `make uicheck DEV_UDID=<yours>` — is not part of the process:
no change requires it (the owner's call, 2026-08-31: in its whole history every
red was the test or the host, never the product). Run it only when explicitly
asked, on your own simulator.

The Makefile builds on the owner's simulator by default; the gate job passes
`DEV_UDID=14C70E21-A23A-4492-8E6A-113AE0BC6B6D` (gate-runner), and a layer
check you run yourself takes your own simulator's id the same way.

Uninstall the app from the simulator before `make uicheck`
(`xcrun simctl uninstall <udid> com.msngr.msngr`). The device keeps the
migrations of whichever build ran on it last, and a branch that does not know the
newest of them leaves the file closed and shows «Приложение устарело» in place of
the chat list: every UI test then fails on a screen with no chats, as a wandering
assertion rather than anything that names the cause. The UI tests register their
own user, and the fixtures they need are on the stand, not on the device.

## The stand

- The shared stand lives on the `adad` server (see `~/.ssh/config`), not on
  this machine: `wrangler dev` on :8787 there, run by systemd
  (`msngr-wrangler.service`, code and state in `/root/msngr/server`), reached
  only through `https://msngr.a-kuz.online` — the app defaults to that URL
  everywhere it runs. Do not restart the service and do not wipe its state
  (`/root/msngr/server/.wrangler/`) without being asked to: it holds the
  conversations and keys of the test users. Logs:
  `ssh adad journalctl -u msngr-wrangler -f`.
- The cloudflared tunnel `msngr.a-kuz.online` → :8787 runs on the same server
  (`msngr-tunnel.service`) and must always be up. Do not start a second
  cloudflared for this tunnel anywhere — two connectors split the traffic.
- CLI tools that default to `http://localhost:8787` (`scripts/fixture.py`,
  `msngrfixture`) need `--base https://msngr.a-kuz.online` (or `MSNGR_SERVER`)
  to talk to the shared stand.
- A change to what an object stores — a table, a column, a key's shape — is
  not migrated: the shared stand is wiped and the trio reseeded (the owner's
  call, 2026-09-03). After the merge: `ssh adad systemctl stop msngr-wrangler`,
  remove `/root/msngr/server/.wrangler/state`, start it again, then
  `scripts/fixture.py seed --reset --base https://msngr.a-kuz.online` and
  reinstall the homes on the simulators that hold them. No `ALTER TABLE` in a
  `try/catch`, no lazy conversion of old records, no schema-version table: a
  stand running the new code over old state is the thing being avoided, and
  the gate never sees it (its smoke runs on a throwaway stand). The code on
  the server is a copy, not a checkout: rsync `server/` there after a
  server-side change; `wrangler dev` there reloads on its own.
- The dev APNs mock `node server/tools/apns-mock.mjs` listens on :9871 and
  delivers pushes to the simulator through `simctl push` — it works only
  against a stand on this machine. The shared stand sends real pushes: its
  `APNS_HOST` points at `server/tools/apns-relay.mjs` (`msngr-apns-relay.service`
  on adad, :9872), which forwards to Apple's sandbox over HTTP/2 and signs the
  provider token itself — APNs is HTTP/2 only and workerd's fetch is HTTP/1.1,
  so a Worker never reaches Apple directly. The topic is `com.msngr.msngr`, the
  one bundle id of every build. A simulator on Apple silicon holds a real
  sandbox token, so the shared stand's pushes reach it, and the extension
  runs there: run the NotificationService scheme from Xcode to sit in it
  with the debugger. The app falls back to registering its UDID (env
  `dev-sim`, what the mock pushes by) only when APNs hands out no token.
  `node test/smoke.mjs` brings up its own receiver on the mock's port,
  so a running mock has to be stopped before the smoke test. On your own stand
  the ports separate:
  `wrangler dev --port 8803 --var APNS_HOST:http://localhost:9873` (this
  overrides `.dev.vars`) and `PUSH_PORT=9873 node test/smoke.mjs`. The smoke
  also wants `CMID_MIN_AGE=0` and `CMID_SWEEP_EVERY=0`, and those two go in
  `.dev.vars`, not on the command line: they are read inside ConversationDO,
  which `--var` does not reach, and «cmid swept behind the sender's ack» is red
  without them.
- `simctl push` does not launch the NSE in any state of the app (the control
  experiment is in `docs/research/nse-simulator-experiment.md`): with it you
  only see what the system does with the raw payload. A real push from the
  shared stand does launch the extension on the simulator, app killed or not,
  and the whole extension family is verified there
  (`docs/qa/runs/2026-09-02-nse-simulator-run.md`). Two things get in the way:
  a push topic SpringBoard keeps «non-waking» waits at Apple until the app is
  foregrounded — that is what a notification grant with the wrong section id
  looked like — and stale PlugInKit registrations of the extension from old
  bundle ids on a long-lived simulator make SpringBoard answer «can be
  modified: 0» and skip the extension (`pluginkit -m -v -p
  com.apple.usernotifications.service` lists them, `pluginkit -r <path>`
  removes one). The extension's journal is `nse-journal.log` in the group
  container; in `log show` its process is found by `processImagePath CONTAINS
  "NotificationService.appex"`. Apple delivers to a backgrounded simulator
  with a delay of seconds to minutes; the order in the journal is the truth,
  not the clock.
- "Offline" in the scenarios means a stopped stand (`systemctl stop
  msngr-wrangler` on the shared one, a killed `wrangler dev` on your own), not
  a disabled network.

## Service accounts

Three accounts live on the shared stand — `alfa`, `bravo`, `charlie` — with the
three direct chats between them and three groups (`Design`, `Standup`,
`Random`), each holding history. A scenario starts inside the product instead of
starting at registration:

```bash
scripts/fixture.py install alfa <udid> --launch   # that simulator is now alfa
scripts/fixture.py grant <udid>                   # permissions only
scripts/fixture.py pull alfa <udid>               # take the moved-on state back
scripts/fixture.py show
```

A home is what the app keeps in its container (`msngr.sqlite`, `.masterkey`,
`session.json`) under `.claude/fixtures/<name>/`, so installing one is a file
copy. `install` also pre-grants everything the first run asks for: the privacy
services `simctl` knows, and the notification authorisation it does not — that
one is a section written into BulletinBoard's store, adopted by killing
`usernotificationsd` and applied by rebooting the device, which is why the
command takes about a minute and why no permission alert appears afterwards.

The keys of a device belong to one device. A home handed to two simulators at
once has each of them stepping the ratchet on its own, and the one that writes
second sends a message the other cannot open — so one simulator at a time, and
`pull` before the next hand-out. `scripts/fixture.py seed` builds the trio
(`--reset` starts a new one); the seeding itself is `msngrfixture` in MsngrKit,
which registers through the real core, so the history is genuinely end-to-end
encrypted and readable on every side.

## Simulators

A simulator is an exclusive resource: at any moment it belongs to one agent.
The host takes four at once; the fifth is what makes the run stutter (the
owner's word, 2026-08-20).

A simulator reads speed in one direction only. It does not emulate a phone: the
same arm64 code runs natively on the host, over the host's memory and its NVMe,
so "iPhone 13" there is a screen size and a system version and nothing else.

Slow on the simulator is a verdict. A screen that stutters on an M4 Pro stutters
on every phone we ship to, and it needs no device to be believed — a 27-second
frame, a 5-second query, a jump that freezes the feed is a defect the moment it
is seen. Fix it and say so.

Fast on the simulator proves nothing, and closes no performance line in the
ROADMAP: the host has memory and a disk the phone does not. Only a device says
what a frame costs.

Counts hold on both: how many queries a screen makes, how many rows it reads,
how many times a cell is rebuilt do not change with the machine, and an
improvement shown in those is an improvement everywhere.

Aiming a tap: `scripts/grid.py <udid>` takes a screenshot and draws a coordinate
grid over it, labelled in the units a tap actually takes. `idb ui tap` counts in
points, a screenshot is in pixels, and passing one for the other sends the touch
to empty space — which reads as "the button does not work" and has already cost
an afternoon of chasing a defect that was not there. Read the coordinate off the
picture, and use `--tap X Y` to tap and re-shoot in one step; `--press X Y`
long-presses the same way (`--duration` changes the hold).

Every `--tap` and `--press` also saves an aim shot — the screen right before
the touch with a red crosshair at the touched point, as a small JPEG whose
path is printed. When a touch reads as "the button does not work", look at the
aim shot first: it says whether the touch landed on the control or beside it,
which is the points-vs-pixels mistake showing itself. Touching through raw
`idb ui tap` skips the aim shot, so prefer grid.py for anything that might
need a post-mortem.

The aim shot is not for every touch — it is for the second failure. A touch
that did not do what you expected twice in a row is never answered with a
third identical attempt: open the aim shot, see where the touch actually
landed and what screen it landed on, and only then retry. Blind series of
taps are how an afternoon disappears; the owner has watched agents do it
while the aim shot with the answer sat unread.

- Do not touch the owner's simulators: `44CE2242-EBB9-48EA-A605-5988A00E4C31`
  (iPhone 17 dev) and `0E0CF155-B4B7-4794-A963-AD7C76EFDCEA` (iPhone 17 Pro Max).
  They are handed out only on an explicit exclusive reservation.
- `14C70E21-A23A-4492-8E6A-113AE0BC6B6D` (gate-runner) — for running the gate.
- For your own scenarios, create your own simulator
  (`xcrun simctl create <name> "iPhone 17"` → `boot` → `install` → register a
  fresh user) and delete it after yourself (`shutdown` + `delete`).
- Name it after yourself: `<agent>` or `<agent>-<role>`, the way `perfdb` owns
  `perfdb-a` and `perfdb-b`. That name is how the housekeeping below tells your
  simulator from litter.
- Slow Animations in Simulator.app is a global toggle: if you turned it on, turn
  it off at the end.

## Housekeeping

Two commands, both at the root of the repository:

```bash
scripts/disk.py            # what our footprint is made of, from the last snapshot
scripts/tidy.py            # what would be taken back; --apply to take it
scripts/tokens.py --write  # tokens spent by the sessions, per day and model → docs/stats/tokens.md
```

`scripts/disk.py` prints in a moment because it prints a stored snapshot and
says how old it is; only free space is read live. `--scan` takes a new one, and
`--wide` also walks the home directory to say how much of the disk is not this
project at all.

The sweep runs from launchd every five minutes and refreshes the snapshot as it
goes; its output is in `.claude/tidy.log`. The job is installed with

```bash
cp scripts/launchd/com.msngr.msngr.tidy.plist ~/Library/LaunchAgents/
launchctl unload ~/Library/LaunchAgents/com.msngr.msngr.tidy.plist 2>/dev/null
launchctl load ~/Library/LaunchAgents/com.msngr.msngr.tidy.plist
```

The sweep only takes what nothing alive is holding: a simulator whose agent has
finished, a stand no wrangler points at, a wrangler still running for a worktree
that was deleted, a worktree whose branch is in main with nothing uncommitted
and no line of its agent's in `.claude/tasks.tsv`, derived data of a workspace
that is gone, logs older than three days. An agent
counts as alive while its process is in `ps` or its transcript is still being
written; a name that is in no registry at all is given the benefit of the doubt
for as long as its app keeps writing.

Below a floor of free space the sweep stops being enough and the decision goes
to a human: `.claude/disk-report.md` says where the space went and what would be
next to give up, with the cost of losing each, and a notification points at it.
Nothing in that report is ever taken automatically.

The owner's two devices, the gate runner, and the shared stand in
`server/.wrangler` are outside all of this and are never touched.

## What is easy to break

- **Order and cursors.** `syncedSeq` moves only along a contiguous prefix;
  `unreadCount` is derived (`lastSeq − myReadUpTo`), not incremented by hand.
- **The service flag.** `edit`, `reaction`, `disappearing` and the sender key
  handout go out with `service: true`: they take a `seq`, but they do not grow
  unread and they raise no push. A new kind of service content is added to
  `SyncEngine.serviceKinds`.
- **Idempotency.** A send is deduplicated by the server by `clientMsgId`; sending
  the same thing again is normal, not an error. The `clientMsgId` of a sender key
  handout is deterministic on purpose.
- **Deferred application.** A message that arrives before its key goes into
  `pendingDecrypt`; an edit or a reaction with no original goes into
  `pendingApply`. A new path for applying content has to handle both.
- **Storage paths.** Only through `StorageLocation`/`AppContainer`: the app and
  the NSE work with the same files in the app group container.
- **The feed.** `reloadData()` on a live chat cuts off animations; an update goes
  through a pointwise diff and reconfiguring the cell in place.
- **The feed window.** The window has a capacity (`FeedWindow`): while the reader
  is at the bottom the lower bound is recomputed and the window slides, and while
  they read history it stays put. Without a ceiling the window grew for as long
  as the chat was open, and every insert re-read and rebuilt it whole.
- **The inverted list.** The feed is inverted through `transform`, so a new
  message is inserted at `item 0` and shifts the content above it under an
  unchanged `contentOffset`. An update remembers the topmost visible item and
  puts it back; any new update path has to do the same.
- **The status bar tap.** UIKit delivers it as `scrollViewShouldScrollToTop` and
  only while exactly one visible scroll view claims it, which is why the input
  text view has `scrollsToTop = false`. The touch itself is SpringBoard's:
  XCUITest cannot produce it on the simulator, through the SpringBoard element or
  through a coordinate in the app's own window alike, so this path is checked in
  `MsngrTests/StatusBarTapTests` and not in the UI smoke.
- **Text size.** Every size lives in `Theme.Text`
  (`ios/Msngr/App/Theme.swift`) as a named role; there should be no numbers in
  the screen code. A role is scaled through `UIFontMetrics` with a ceiling: the
  feed's ceiling is high, the header's and the chat list's are low, because their
  heights are fixed. Feed measurement happens outside the view hierarchy, so the
  size category is held by the `TypeScale.category` snapshot rather than
  `UITraitCollection.current`. A size change drops the plan cache and re-measures
  the feed, putting the reader back where they were; cell fonts are assigned in
  `configure`, not in `init` — no trait callback arrives in the reuse pool.
- **The badge.** The number is counted by the server and stamped with a counter
  (`badgeStamp`); on the device it lives as a single row (`BadgeStore`), the app
  and the extension write through a transaction, and an overtaken value is
  discarded. Do not count the badge on the device: the system applies the number
  from the payload whether the extension ran or not.
- **Clearing and deleting a chat.** Clearing is a local act: the rows go, the
  cursors (`lastSeq`, `syncedSeq`, `syncCursor`) stay where they are, and the
  messages above the stuck prefix are closed off by a `cleared` record in
  `historyGap` — otherwise pagination asks the server again for a range whose
  keys are already gone. Deleting takes the chat away whole and leaves a
  `chatTombstone` mark: a chat that comes back starts its cursors from it. The
  peer keeps the conversation: a group chat is left on the server, a direct chat
  is only taken out of your own list and comes back on the next content message.
- **Folders.** A tab is a rule plus the chats put in and taken out by hand
  (`chatFolder`, `chatFolderChat`, `chatFolderPeer`); a chat lives in any number
  of folders, and deleting a folder removes only its rows. Membership is computed
  by the chat list observation once per emission, and switching a tab does not go
  to the database. Folders are local: they do not go to the server and there is
  no sync between devices. The archive and the requests live only in the «Все»
  tab. A long horizontal swipe over the list switches the tab while a short one
  stays with the row's swipe actions, which is why a row has no full swipe.
- **APNs.** A push goes out for every content message, even with a live socket;
  the duplicate is suppressed by the client in `willPresent`. Do not "fix" this
  with a condition on presence.
- **A notification is a database write.** The push carries the envelope itself
  (`env`, cut down to the device); the extension decrypts it and writes the
  message in the same transaction that claims the banner (`PushMessageWriter`),
  and the banner text is then read from that row. Do not pull anything from the
  server at the moment the app opens. APNs does not accept more than 4 KB — the
  envelope is dropped and the message arrives on the next connection.
- **The ratchet and two processes.** `ratchetSession`, `senderKeyIn`, the prekey
  blob and `trustedIdentity` change through a "read — step — write" cycle, while
  the app and the extension live in different processes over one file. Every such
  cycle runs under `CryptoGate` (flock + a local lock): the gate is taken before
  the transaction, never inside it, and is not held across an `await`. A lost
  write here is a position of the sending chain used twice, which is a message
  the peer will never open.
- **One banner per message.** The right to show a message is taken by the
  `notificationShown` row (`NotificationBurstStore.claim`): whoever inserted it
  shows it. The app takes it before its own banner, the extension before its own.
  The display order of an avalanche is set by `NotificationBurstGate`: pushes
  wait for the coalescing window and answer by seq in a single chain, and nothing
  already shown is posted again.

## Compatibility

There is no backward compatibility and we write no compat layers: the database
schema can change with no migration (wipe the database, register the user
again), frames and REST change freely, keys and sessions can be lost. The
versioning mechanism is still put in place — `v` in the E2E envelope, the schema
version, `migrations` in `wrangler.jsonc`. The details are in `docs/PROCESS.md`.

## How work is delivered

- Work in a worktree of your own (`EnterWorktree`); nobody edits the `main`
  checkout directly and no two sessions share a tree. You take the topmost
  free line of `docs/BACKLOG.md`, write your name in its `who`, and add your
  line to `.claude/tasks.tsv` (name, start, one sentence, tab-separated);
  both go when you deliver. `scripts/progress.py` shows the owner these.
- Micro-scope: one behaviour per change, commits incremental. A live run of the
  affected scenario on the simulator, the check of the layer you touched, then
  merge into `main` yourself; the gate job gates the merge on its own
  (`scripts/gate-watch.py`, status in `.claude/gates/status.tsv`).
- A red check on a product number or behaviour is a defect report until proven
  otherwise. It is never answered from the test's side — moving a cursor,
  widening an expectation, adding a sleep — before the product is shown right,
  in writing. Noticing that a number "counts one too many" and absorbing it
  into the fixture buries a live defect: that exact move hid the inflated
  group unread until the owner reported it from the outside. A symptom found
  in passing goes into `docs/BACKLOG.md` and into the report, even when the
  test is already green.
- A defect reported by the owner is never answered with "that was out of
  scope" or "nobody logged it". Scope divides the work, not the
  responsibility: the end goal of every run is the quality of the product as a
  whole, and the only right first response to a report is to investigate it —
  who should have caught it is settled after, in process, not in the reply.
- Commits and PRs without `Co-Authored-By`.
- Everything in the repository is in English: comments, commit messages,
  documentation, run reports. Comments describe only the current behaviour;
  change history lives in git. Existing Russian content is translated by separate
  continuous passes — do not translate it along the way in your own diff.
- User-facing interface strings live in a localization catalog with English as
  the base language; there should be no text hardcoded in the code.
- The product fixes its own failures itself: a retry in the background, with no
  human involved. The user hears only about what needs their decision. An action
  button appears only if the action really changes something.
- A lost or unreadable message is a defect, not an interface state. First remove
  the cause and fix it automatically (a retry, a request to the sender), and only
  as a last resort show something. Zero unreadable messages in a live run —
  otherwise the run is red.
- The interface reports the state, not the cause and not who is to blame. We do
  not push it onto the user («попросите отправителя») and we do not blame third
  parties or circumstances («сервер недоступен», «плохая сеть», «у собеседника
  старая версия»). «Подключение…», «Сообщение ещё не загружено», «Не отправлено»
  is enough.
- A regression found after delivery gets a reproducing test first, then the fix.
- A report at the end: what was done, what was verified (with which command or
  run), what was not done and why.
