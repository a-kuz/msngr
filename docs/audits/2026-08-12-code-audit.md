# Code audit 2026-08-12 (independent auditor agent)

Status of each item: `open` — not checked, `confirmed` — reproduced, `fixed` — fixed with a test, `rejected` — not a bug (with an explanation).

Re-triaged against the code on 2026-08-16; every item carries a `2026-08-16:` line
with what the check found. Fixes made during that sweep are in
`docs/qa/runs/2026-08-16-audit-sweep.md`.

| # | Status | In short |
|---|--------|----------|
| 1 | fixed | /api/join: the DO rejects a non-member, viaInvite is never read, the client gets ok:true |
| 2 | fixed | Coming back from ChatInfo: onDisappear → stop(), start() is guarded by started — the feed is dead |
| 3 | fixed | One-time prekeys are burned by GET /prekeys on every message, nothing tops them up |
| 4 | fixed | Media and voice sent offline are lost: upload before enqueue, try? swallows it |
| 5 | fixed | A break between skd and skm: distributedTo is marked before the send — the group sits in no_sender_key forever |
| 6 | fixed | Killed mid-send: inflight is not reset to ready on restart |
| 7 | fixed | Read receipts / delete-for-all / recv offline: try? ws.send with no queue |
| 8 | fixed | Sync does not replay tombstones or read marks — only msg frames |
| 9 | fixed | Draft: onAppear reads chat.draft while chat is nil; onDisappear wipes it |
| 10 | fixed | expiresAt is never applied — auto-deletion does not work |
| 11 | fixed | identityChanged in a group: the outbox is blocked, but the banner is direct-only |
| 12 | fixed | No push while a suspended socket is still alive (live.length === 0) |
| 13 | fixed | Reactions, edits and skd grow unreadCount — a badge with no message behind it |
| 14 | fixed | Returning from background: no forced reconnect or resync, connected goes stale |
| 15 | fixed | Accepting a request offline: try? swallows it, the snapshot resurrects the request |
| 16 | fixed | Crash: Dictionary(uniqueKeysWithValues:) on duplicate ids (date separators) |
| 17 | fixed | LIMIT 500 in the feed: history is pulled into the database but never shown |
| 18 | fixed | Delete-for-all of someone else's message in a direct chat: deleted locally, still there for the peer |
| 19 | fixed | Voice message without requestRecordPermission — an empty recording |
| 20 | fixed | setInsets is never called: content sits under the navigation bar and the input |
| 21 | fixed | The typing indicator sticks: no timer, no typing stop |
| 22 | fixed | A sync limit of 200 with no continuation until the next reconnect |
| 23 | rejected | A race generating the master key between the app and the NSE |
| 24 | fixed | Two processes on one DatabaseQueue without busy_timeout — a silent SQLITE_BUSY |
| 25 | fixed | Blocking a request is local only, the snapshot brings the chat back |
| 26 | fixed | An edit or reaction on an undecrypted target — a no-op with no retry |
| 27 | fixed | loadOlder loses reactions and edits of historic messages |
| 28 | fixed | An undecryptable placeholder blocks later content through the msgId dedup |
| 29 | fixed | /api/chats/:id/invite does not check membership |
| 30 | fixed | Stale "online": offline presence only from webSocketClose |
| 31 | fixed | A read receipt from a backgrounded app (isViewingBottom defaults to true) |
| 32 | fixed | Edit A → edit B: text A stays in the field (the banner's onAppear) |
| 33 | fixed | TOFU checks bundles.first only — a second device is never detected |
| 34 | fixed | Zero bundles → an empty envelope "sent successfully" |
| 35 | fixed | skd with a new UUID on every retry — duplicates in history, and they move seq |
| 36 | rejected | WSClient.events() is single-use: a second call kills the old stream |
| 37 | fixed | A reaction to your own message before its ack goes out with the clientMsgId — only the author sees it |

Full descriptions with files and lines are in the audit text below.

## Details

1. `server/src/index.ts:303` — `/api/join` calls `/members` with `actor` = the joining user, and `ConversationDO.ts:291` rejects a non-member (`not_member`); the `viaInvite` flag is never read in the DO. The result `r` is ignored (`void r`) and the client gets `ok:true`.
   2026-08-16: fixed earlier. `/api/join` passes `viaInvite: true` and returns the DO's error (`server/src/index.ts:464-470`); the DO builds `selfJoin` and only then skips the rejection (`ConversationDO.ts:672-682`). Covered by `server/test/smoke.mjs:405-417`.
2. `ChatScreen.swift:56-61` — `onDisappear` also fires on a push into `ChatInfoView` and calls `model.stop()`; on the way back `start()` is cut off by `guard !started` (`ChatViewModel.swift:48`), so the ValueObservation is never rebuilt.
   2026-08-16: fixed earlier. `onDisappear` returns before `stop()` when the push into ChatInfo caused it (`ChatScreen.swift:116-124`), and `start()` guards on `cancellable == nil`, which `stop()` clears (`ChatViewModel.swift:97-98, 216-223`).
3. `index.ts:118-124` deletes an OTP on every GET `/prekeys`, while `E2EE.swift:125` asks for bundles on every message sent. `generateMoreOneTime` and `uploadPrekeys` are never called.
   2026-08-16: fixed earlier. Device addresses come from `/api/devices`, which spends nothing (`server/src/index.ts:186-205`); a bundle is fetched only for a device without a session (`E2EE.swift:254-269`). `SyncEngine.start()` tops the pool up below 20 (`SyncEngine.swift:92, 111-124`).
4. `ChatScreen.swift:248,297,332` — the upload runs before `enqueue`; with no network `try? upload` fails and the `guard` returns, so the message never reaches the outbox.
   2026-08-16: fixed earlier. Every attachment path stashes the source into the app-group pending dir and enqueues at once (`ChatScreen.swift:540-654`); the upload moved into the outbox worker, where a network error is an ordinary retry (`SyncEngine.swift:1434-1438, 1501-1557`).
5. `E2EE.swift:85-90` marks devices in `distributedTo` and saves that before sending; if `ws.send(skd)` at `SyncEngine.swift:510` failed, `missing` is empty on the retry.
   2026-08-16: fixed earlier. `distributedTo` is filled only from the recipient's ack (`E2EE.swift:134-145`, `SyncEngine.swift:949-953`); the send attempt is remembered separately in `attemptedAt` and redistributed after 60 s (`E2EE.swift:91-96, 109`). Test `MessageRepairTests.testSenderKeyConfirmationClosesDistribution`.
6. `SyncEngine.swift:519` sets `state='inflight'`, with an in-memory 15 s Task as the safety net. After a kill there is no `inflight→ready` reset on restart.
   2026-08-16: fixed earlier. `start()` resets the stuck rows before anything else (`SyncEngine.swift:64-69`). Test `OfflineReliabilityTests.testStartResetsInflightToReady`.
7. `SyncEngine.swift:555,576,230` — read receipts, delete-for-all and recv all go out through `try? ws.send` with no queue.
   2026-08-16: fixed earlier. Read marks, delete-for-all, accept and chat-delete go through the durable `pendingAction` queue drained on `.connected` (`SyncEngine.swift:1565-1626, 1646-1748`). Tests in `OfflineReliabilityTests`. The recv ack stays fire-and-forget on purpose: delivered marks are monotonic on both sides, so a lost one is absorbed by the next.
8. `UserSessionDO.ts:240-273` — sync replays only `msg` frames by cursor; tombstones, read marks and roster changes arrive only on a full `refreshSnapshot`.
   2026-08-16: tombstones and marks were already replayed by `sendChatTail`; membership was not, and a member who was offline while somebody was removed never rotated the sender key, so he kept encrypting to a chain the removed user holds. Fixed: `/events` carries the roster, catch-up replays it, rotation triggers on any frame whose roster shrank, and a member who was removed is told so. Tests `server/test/smoke.mjs` ("catch-up replays the roster", "catch-up tells the removed member") and `MembershipReplayTests`.
9. `ChatScreen.swift:53` — `text = model.chat?.draft` in `onAppear`, but `chat` loads asynchronously and is nil at that moment; `onDisappear` then overwrites the draft with an empty string.
   2026-08-16: fixed earlier. The draft is filled when the chat arrives, into an empty field only (`ChatScreen.swift:101-115`), and every keystroke persists it (`ChatViewModel.swift:580-601`).
10. `expiresAt` is stamped on incoming messages (`SyncEngine.swift:337`) but read nowhere; outgoing ones have no `expiresAt` at all.
    2026-08-16: confirmed — the field was written and never read, and outgoing copies were never stamped, so the TTL switch in ChatInfo promised and did nothing. Fixed on the device: the outgoing copy is stamped when its ack arrives and the historic one when it is pulled, and a sweep takes what expired along with its attachments, closing the seq with a `historyGap` record the way clearing does. The server journal still keeps the envelope — the expiry is this device's, not the conversation's. Tests in `DisappearingTests`.
11. `SyncEngine.swift:456` sets the outbox to `blocked` for group chats too, but `keyChangePending` is computed for direct chats only (`ChatViewModel.swift:106`).
    2026-08-16: confirmed — in a group the block is reachable (a changed key means a new device, so `missing` is non-empty and the distribution goes pairwise) and the banner was direct-only, leaving the send blocked with no action. Fixed: the pending change is read over every member of the chat and accepting covers all of them. Tests `KeyChangeTests.testAcceptCoversEveryMemberOfTheChat`, `testAcceptLeavesOutsidersPending`.
12. `UserSessionDO.ts:102` — a push goes out only when `live.length === 0`; iOS keeps the WS alive for minutes after the app is backgrounded.
    2026-08-16: fixed earlier. The push goes out for every non-service, non-muted, non-echo `msg` regardless of live sockets (`UserSessionDO.ts:168-187`). Test `server/test/smoke.mjs:750-752`.
13. Every send gets a seq (`ConversationDO.ts:167`), and `applyIncomingMessage` (`SyncEngine.swift:217-227`) grows `lastSeq` and `unreadCount` for any frame.
    2026-08-16: the client half was fixed earlier (`SyncEngine.advanceChat`, test `ServiceFrameTests.testServiceFrameDoesNotGrowUnread`), but the badge is the server's number and `/unread-count` counted `lastSeq − readMark`, service frames included — and the author's own messages with them. The chat now keeps a counting mark of its own, moved by the same rules the client moves its cursor by, while read receipts keep going by `readMarks` alone. Tests `server/test/smoke.mjs` ("service frame does not grow the badge", "own messages do not grow the author's badge").
14. `AppState.scenePhaseChanged:105` only clears the lock; a dead socket is noticed through the ping timeout or a backoff of up to 30 s (`WSClient.swift:139`).
    2026-08-16: fixed earlier. Foreground calls `appBecameActive` → `ws.nudge()`, which cancels the backoff and reconnects at once (`AppState.swift:259-281`, `SyncEngine.swift:143-157`, `WSClient.swift:238-248`); the backoff cap is 12 s.
15. `ChatViewModel.acceptRequest:267` — `try? api.acceptChat` fails silently while `isRequest=0` locally; the next snapshot brings `isRequest` back.
    2026-08-16: confirmed on the chat-list path only — the chat screen queues the accept durably, the list swipe still called the API directly and flipped the flag regardless, leaving the server at `accepted = false` forever. Fixed: the swipe goes through the same queued accept as the chat screen.
16. `MessagesViewController.swift:83-84` — `Dictionary(uniqueKeysWithValues:)` traps on a repeated id; separator ids are built from the label, so a non-monotonic `sentAt` gives one day twice and crashes.
    2026-08-16: fixed earlier. Separator ids derive from the message id (`ChatViewModel.swift:347-353`) and the diff uses `uniquingKeysWith:` (`MessagesViewController.swift:194-195`). Tests `ChatFeedTests.testSeparatorIdsUniqueForNonMonotonicSentAt`, `HistoryFeedTests.testFeedIdsStayUnique`.
17. `ChatViewModel.swift:57` LIMIT 500 — `loadOlder` pulls into the database, the feed does not show it.
    2026-08-16: fixed earlier. The feed reads a window whose floor and capacity are state, and `loadOlder` lowers the floor (`FeedWindow.swift`, `ChatViewModel.swift:154-168, 623-663`). Tests in `FeedWindowTests`.
18. The client tombstones locally right away (`SyncEngine.swift:566`), and the server silently skips a foreign message for a non-admin (`ConversationDO.ts:274`).
    2026-08-16: the server behaviour is deliberate and pinned by `server/test/smoke.mjs:298-308`, and iOS stopped offering the action on a foreign message. The macOS target still offered it on every bubble, so the divergence survived there. Fixed: the rule moved into the core as `MessageDeletion.canDeleteForAll`, and both clients read it from there; macOS offers a delete of its own copy instead. Tests `MessageDeletionTests`.
19. `Voice.swift:15` — `start()` does not call `requestRecordPermission`.
    2026-08-16: confirmed — no permission request anywhere, so the first take records over the system prompt and a denial leaves the mic button silently dead. Fixed: the press asks first and records on the answer, and a denial says so with a way into settings. Tests `MicGateTests` cover the decision; the audio session itself is not under test.
20. `MessagesViewController.swift:50` plus `contentInsetAdjustmentBehavior = .never` — `setInsets` is never called.
    2026-08-16: fixed earlier. Insets are recomputed on every layout pass and keyboard change (`MessagesViewController.swift:110, 118-135`).
21. `ChatListModel.swift:95-106` — the 5 s expiry is checked lazily with no timer, and no typing stop is ever sent.
    2026-08-16: fixed earlier. Both consumers hold a real timer (`ChatViewModel.swift:134-138`, `ChatListModel.swift:117-124`) and a stop frame goes out when the field empties (`ChatViewModel.swift:583-587`).
22. `UserSessionDO.ts:258` — past 200 missed messages the remainder arrives only after the next reconnect.
    2026-08-16: fixed earlier. Catch-up is served in bounded portions that state what is left, and the client asks for the next one inside the same connection (`UserSessionDO.ts:10-18, 437-467`, `SyncEngine.swift:316-341`). Tests `server/test/smoke.mjs:492-532`, `CatchupCursorTests`.
23. `KeyStore.swift:67-75` — the app and the NSE can generate different `.masterkey` files at the same time.
    2026-08-16: rejected — the extension reads the key only when `session.json` is next to it (`NotificationService.swift:59-71`), and registration writes the key before the session (`RegisterView.swift:93, 115`), so the file exists before the first push. It was not true on 12 August either: that revision's extension never built an `IdentityStore`.
24. `Database.swift:7-15` — the NSE and the app on one SQLite; SQLITE_BUSY is swallowed by `try? db.write`.
    2026-08-16: fixed earlier. The file is opened with `busyMode = .timeout(5)`, immediate transactions and WAL, by both processes (`Database.swift:22-35`, `NotificationService.swift:47`), so a cross-process conflict waits instead of failing.
25. `ChatListModel.blockRequest:157-165` deletes the chat locally only.
    2026-08-16: confirmed — the block reached the server but the chat did not, so the next snapshot brought the request back, and without a tombstone it came back at seq 0 and re-requested journal ranges whose keys are gone. Fixed: rejecting runs the same queued chat delete as any other deletion, and the block itself became a queued action too, so neither half is lost offline (migration v17 — `pendingAction.chatId` is now optional). Tests `OfflineReliabilityTests.testRejectingRequestOfflineQueuesBothHalves`, `testServerListKeepsQueuedBlock`.
26. `SyncEngine.applyContent:312-320` — an UPDATE by msgId with no row is a no-op; an edit or reaction on an original stuck in pendingDecrypt is lost.
    2026-08-16: fixed earlier. A zero-row update parks the event in `pendingApply`, applied when the original lands (`SyncEngine.swift:1102-1124, 1868-1901`). Tests `ServiceFrameTests.testReactionAndEditBeforeOriginalApplyAfter`, `testDeletedBeforeOriginalAndReplay`.
27. `ChatViewModel.storeHistoric:329` skips `edit` and `reaction`.
    2026-08-16: fixed earlier. `storeHistoric` handles edit, reaction and disappearing, buffering when the original is missing (`SyncEngine.swift:1155-1197`). Tests in `HistoricReplayTests`.
28. `storeIncoming:296-303` saves an undecryptable placeholder (including the transient `"exception"`) — the msgId dedup then blocks the real content when it arrives later.
    2026-08-16: fixed earlier. No placeholder row is written at all; the envelope goes to `pendingDecrypt` with a reason and an attempt counter, and the transient `"exception"` is retryable (`SyncEngine.swift:673-716, 1084-1087`). Tests in `MessageRepairTests`.
29. `index.ts:287-295` — `/api/chats/:id/invite` does not check membership.
    2026-08-16: fixed earlier. The route answers `not_member` 403 unless the caller is in the roster (`server/src/index.ts:443-450`). Test `server/test/smoke.mjs:396`.
30. `UserSessionDO.ts:277` — offline presence only from `webSocketClose/Error`.
    2026-08-16: fixed earlier. Presence follows ping freshness with a 35 s TTL alarm, plus an explicit `bg` frame (`UserSessionDO.ts:76-82, 518-521, 610-616`). No test asserts the TTL path.
31. `ChatViewModel.markVisibleRead:296` runs on every DB tick while `isViewingBottom=true` (the default) — a read receipt from a backgrounded app.
    2026-08-16: fixed earlier. The mark bails when the scene is not active, and `isViewingBottom` follows whether item 0 is on screen (`ChatViewModel.swift:610-615`, `AppState.swift:259-270`). Test `ViewingBottomTests`.
32. `InputBar.swift:83-85` — `text = e.text` only in the banner's `onAppear`.
    2026-08-16: fixed earlier. The field refills from a change of the edited message's identity (`ChatScreen.swift:128-131`).
33. `E2EE.swift:138-140` — `checkTrust` over `bundles.first`.
    2026-08-16: fixed earlier. Trust is checked over every device of every recipient, and the device list comes from `/devices` rather than from bundles (`E2EE.swift:186-189, 203-211`).
34. `E2EE.encryptPairwise:129-153` — zero bundles give an empty envelope with no error.
    2026-08-16: fixed earlier. A recipient with no device throws `E2EEError.noDevices` before encryption (`E2EE.swift:199-201`), and the device list and the bundle list come from the same table, so zero bundles for an existing device is not reachable.
35. `SyncEngine.swift:510` — skd with a fresh `UUID()` clientMsgId on every attempt.
    2026-08-16: fixed earlier. The distribution id is derived from the chat, the key id, the sorted recipients and the round (`E2EE.swift:106-108, 127-131`), and a repeat inside the 60 s window produces no new distribution at all.
36. `WSClient.swift:32-36` — a second `events()` overwrites the continuation.
    2026-08-16: rejected as written. The overwrite is still in the code (`WSClient.swift:42-46`), but `events()` has exactly one call site, `SyncEngine.start()`, and no path starts an engine twice: `AppState.bootstrap` and `MacApp` build a fresh engine each time and `resetToRegistration` drops it. Nothing to reproduce; worth a guard the day a second consumer appears.
37. `ChatViewModel.react:239` — `targetMsgId = msg.msgId ?? msg.id`; before the ack the clientMsgId goes out.
    2026-08-16: confirmed, and it covers edits the same way — one double tap on a just-sent bubble is enough, and offline the window lasts as long as the outbox does. The peer parks the reaction in `pendingApply` under an id that never arrives. Fixed: the target is resolved against the message row at send time, and a service frame whose target has no server id yet waits for its ack instead of leaving. Tests `ServiceFrameTests.testReactionToUnackedTargetResolvesAtSendTime`, `testTargetFromPeerPassesThroughAndFailedTargetIsDropped`, `testAckReleasesWaitingOutboxRows`.

## Found along the way

- **Catch-up handed the journal to any authenticated user.**
  `UserSessionDO.serveCatchup` took the cursors from the client frame as they came
  and called `ConversationDO` `/history` and `/events`, neither of which checked
  membership — that check lived on the REST route alone. A direct chat's id is
  derived from the two user ids (`util.ts:57-59`), and `/api/users` hands out user
  ids, so the frame `{"t":"sync","cursors":{"direct:<a>:<b>":0}}` returned somebody
  else's whole conversation: envelopes, seq, msgId, sender, device and time. The
  bodies are encrypted, so no plaintext leaked.
  Fixed first thing in this sweep: `/history` and `/events` require a member.
