# Working in this repository

An E2EE messenger: Swift clients (iOS, macOS) + a Cloudflare Worker.
There is no production and there are no users.

## Layout

```
server/src/index.ts        HTTP API (hono) + the /ws upgrade
server/src/do/             UserSessionDO (sockets, presence, pushes), ConversationDO (the chat journal),
                           ApnsTokenDO (the singleton owner of the APNs JWT)
server/src/push/apns.ts    APNs
server/migrations/         D1 migrations (wrangler d1 migrations apply)
ios/MsngrKit/              the core: MsngrCrypto (primitives), MsngrCore (database, WS, SyncEngine, E2EE)
ios/Msngr/                 the iOS app
ios/NotificationService/   the NSE
ios/project.yml            the project description for xcodegen
```

Documentation: `docs/protocol.md` (frames and API), `docs/crypto-flows.md`,
`docs/ui-spec.md`, `docs/PROCESS.md` (the process and the gate),
`docs/localization-catalog.md`, `docs/audits/`, `docs/qa/`, `docs/research/`.

## Building and testing

```bash
cd ios && xcodegen                                  # required after editing project.yml
xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr -destination 'id=<UDID>' build
xcodebuild -project ios/Msngr.xcodeproj -scheme Msngr -destination 'id=<UDID>' \
  test -only-testing:MsngrTests
cd ios/MsngrKit && swift test                       # the core
cd server && node test/smoke.mjs                    # API/DO/pushes, needs wrangler dev
```

`ios/Msngr.xcodeproj` is in `.gitignore` and is generated from `ios/project.yml`.
Do not edit `.pbxproj` by hand — the next `xcodegen` will overwrite the edits. The
entitlements of the app and the extension are built from `project.yml` too
(`entitlements.properties`), so editing `.entitlements` is pointless.

`swift test` in MsngrKit: `CoreIntegrationTests` skip themselves if nothing
answers on :8787; the rest of the tests need no server.

## The gate before delivery

`make check` at the root: `xcodegen` → build → `swift test` → MsngrTests →
MsngrUITests → the server smoke test → collecting fresh simulator crashes (a
fresh crash fails the gate). The UI tests and the smoke test need `wrangler dev`
running.

The Makefile builds on the owner's simulator by default, so an agent runs the
gate with its own:

```bash
make check DEV_UDID=74B78AFC-E8D7-4317-B16F-E51A65504B2D   # gate-runner
```

## The stand

- `wrangler dev` on :8787 — shared and live. Do not restart it and do not wipe
  its state (`server/.wrangler/`) without being asked to: it holds the
  conversations and keys of the test users.
- The dev APNs mock `node server/tools/apns-mock.mjs` listens on :9871 and
  delivers pushes to the simulator through `simctl push`. `node test/smoke.mjs`
  brings up its own receiver on the same port, so the mock has to be stopped
  before the smoke test. On your own stand the ports separate:
  `wrangler dev --port 8803 --var APNS_HOST:http://localhost:9873` (this
  overrides `.dev.vars`) and `PUSH_PORT=9873 node test/smoke.mjs`.
- `simctl push` does not launch the NSE in any state of the app (the control
  experiment is in `docs/research/nse-simulator-experiment.md`). On the simulator
  you only see what the system does with the raw payload: the badge arrives, the
  text stays unprocessed, the avatar is not filled in. Everything that goes
  through the extension is verified on a device.
- "Offline" in the scenarios means a killed `wrangler dev`, not a disabled
  network.

## Simulators

A simulator is an exclusive resource: at any moment it belongs to one agent.

- Do not touch the owner's simulators: `44CE2242-EBB9-48EA-A605-5988A00E4C31`
  (iPhone 17 dev) and `0E0CF155-B4B7-4794-A963-AD7C76EFDCEA` (iPhone 17 Pro Max).
  They are handed out only on an explicit exclusive reservation.
- `74B78AFC-E8D7-4317-B16F-E51A65504B2D` (gate-runner) — for running the gate.
- For your own scenarios, create your own simulator
  (`xcrun simctl create <name> "iPhone 17"` → `boot` → `install` → register a
  fresh user) and delete it after yourself (`shutdown` + `delete`).
- Slow Animations in Simulator.app is a global toggle: if you turned it on, turn
  it off at the end.

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

- Micro-scope: one behaviour per change, commits incremental. A live run of the
  affected scenario on the simulator, then `make check`.
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
