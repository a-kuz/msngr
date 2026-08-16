# Code audit 2026-08-12, by an independent auditor agent

Status of each item: `open` means unverified, `confirmed` means reproduced,
`fixed` means fixed with a test, `rejected` means not a bug, with the reason.

| # | Status | Summary |
|---|--------|---------|
| 1 | open | /api/join: the DO rejects a non-member, `viaInvite` is never read, the client still gets ok:true |
| 2 | open | Coming back from ChatInfo: onDisappear calls stop(), start() is guarded by `started`, so the feed is dead |
| 3 | open | One-time prekeys are burned by GET /prekeys on every message and never topped up |
| 4 | open | Media and voice messages are lost offline: the upload happens before enqueue and `try?` swallows it |
| 5 | open | A break between skd and skm: `distributedTo` is marked before sending, leaving the group in permanent no_sender_key |
| 6 | open | Killed mid-send: `inflight` is not reset to `ready` on restart |
| 7 | open | Read receipts, delete-for-all and recv offline: `try? ws.send` with no queue |
| 8 | open | Sync never replays tombstones or read marks, only msg frames |
| 9 | open | Drafts: onAppear reads chat.draft while chat is still nil, and onDisappear overwrites it |
| 10 | open | `expiresAt` is never applied, so disappearing messages do not work |
| 11 | open | identityChanged in a group: the outbox is blocked but the banner is direct-only |
| 12 | open | No push is sent while a suspended socket is still alive (live.length === 0) |
| 13 | open | Reactions, edits and skd inflate unreadCount, giving a badge with no message |
| 14 | open | Returning from the background: no forced reconnect or resync, connection stays stale |
| 15 | open | Accepting a request offline: `try?` swallows it and the snapshot resurrects the request |
| 16 | open | Crash: `Dictionary(uniqueKeysWithValues:)` on duplicate ids from date separators |
| 17 | open | LIMIT 500 in the feed: history is fetched into the database but never shown |
| 18 | open | Delete-for-all on someone else's message in a direct chat: deleted locally, still there for the peer |
| 19 | open | Voice recording without requestRecordPermission produces an empty recording |
| 20 | open | setInsets is never called, so content sits under the nav bar and the input |
| 21 | open | The typing indicator sticks: no timer and no typing stop |
| 22 | open | The sync limit of 200 does not continue until the next reconnect |
| 23 | open | A race generating the master key between the app and the NSE |
| 24 | open | Two processes on one DatabaseQueue without busy_timeout, silently hitting SQLITE_BUSY |
| 25 | open | Blocking a request is local only, and the snapshot brings the chat back |
| 26 | open | An edit or reaction against an undecrypted target is a no-op with no retry |
| 27 | open | loadOlder loses the reactions and edits of historic messages |
| 28 | open | The undecryptable placeholder blocks later content through msgId dedup |
| 29 | open | /api/chats/:id/invite does not check membership |
| 30 | open | Stale "online": offline presence comes only from webSocketClose |
| 31 | open | A read receipt is sent from a backgrounded app (isViewingBottom defaults to true) |
| 32 | open | Edit A then edit B: the field keeps A's text, from the banner's onAppear |
| 33 | open | TOFU checks only `bundles.first`, so a second device is never detected |
| 34 | open | Zero bundles produce an empty envelope reported as sent successfully |
| 35 | open | skd gets a new UUID on every retry, duplicating history and moving seq |
| 36 | open | WSClient.events() is single-use: calling it again kills the previous stream |
| 37 | open | A reaction to your own message before its ack goes out with the clientMsgId and is visible only to the author |

Full descriptions with files and line numbers follow.

## Details

1. `server/src/index.ts:303` — `/api/join` calls `/members` with `actor` set to
   the person joining, and `ConversationDO.ts:291` rejects a non-member with
   `not_member`; the `viaInvite` flag is never read in the DO. The result `r` is
   ignored (`void r`) and the client is told `ok:true`.
2. `ChatScreen.swift:56-61` — `onDisappear` also fires when pushing into
   `ChatInfoView` and calls `model.stop()`; on the way back `start()` is cut off
   by `guard !started` (`ChatViewModel.swift:48`), so the ValueObservation is
   never recreated.
3. `index.ts:118-124` deletes a one-time prekey on every GET `/prekeys`, while
   `E2EE.swift:125` requests bundles for every message sent.
   `generateMoreOneTime` and `uploadPrekeys` are never called.
4. `ChatScreen.swift:248,297,332` — the upload runs before `enqueue`; with no
   network `try? upload` fails and the `guard` returns, so the message never
   reaches the outbox.
5. `E2EE.swift:85-90` marks devices in `distributedTo` and saves before sending;
   if `ws.send(skd)` at `SyncEngine.swift:510` failed, `missing` is empty on the
   retry.
6. `SyncEngine.swift:519` sets `state='inflight'`, with an in-memory 15 s Task as
   the safety rollback. After a kill there is no `inflight→ready` reset on
   restart.
7. `SyncEngine.swift:555,576,230` — read receipts, delete-for-all and recv all go
   through `try? ws.send` with no queue.
8. `UserSessionDO.ts:240-273` — sync replays only `msg` frames by cursor;
   tombstones, read marks and membership changes arrive only on a full
   `refreshSnapshot`.
9. `ChatScreen.swift:53` — `text = model.chat?.draft` in `onAppear`, but `chat`
   loads asynchronously and is nil at that moment; `onDisappear` then writes the
   draft back as empty.
10. `expiresAt` is set on incoming messages (`SyncEngine.swift:337`) and never
    read anywhere; outgoing messages have no `expiresAt` at all.
11. `SyncEngine.swift:456` sets the outbox to `blocked` for group messages too,
    but `keyChangePending` is only computed for direct chats
    (`ChatViewModel.swift:106`).
12. `UserSessionDO.ts:102` — a push is sent only when `live.length === 0`, and
    iOS keeps the WS alive for minutes after backgrounding.
13. Every send is assigned a seq (`ConversationDO.ts:167`), and
    `applyIncomingMessage` (`SyncEngine.swift:217-227`) grows `lastSeq` and
    `unreadCount` for any frame.
14. `AppState.scenePhaseChanged:105` only clears the lock; a dead socket is
    discovered through the ping timeout or a backoff of up to 30 s
    (`WSClient.swift:139`).
15. `ChatViewModel.acceptRequest:267` — `try? api.acceptChat` fails silently and
    `isRequest=0` is set locally; the next snapshot restores `isRequest`.
16. `MessagesViewController.swift:83-84` — `Dictionary(uniqueKeysWithValues:)`
    traps on a repeated id. Date separator ids come from the label, so a
    non-monotonic `sentAt` can produce the same day twice and crash.
17. `ChatViewModel.swift:57` LIMIT 500 — `loadOlder` fetches into the database
    and the feed does not show it.
18. The client tombstones locally straight away (`SyncEngine.swift:566`) while
    the server silently skips a message that is not yours unless you are an
    admin (`ConversationDO.ts:274`).
19. `Voice.swift:15` — `start()` never calls `requestRecordPermission`.
20. `MessagesViewController.swift:50` with `contentInsetAdjustmentBehavior =
    .never` — `setInsets` is never called by anyone.
21. `ChatListModel.swift:95-106` — the 5 s expiry is checked lazily with no
    timer, and no typing stop is ever sent.
22. `UserSessionDO.ts:258` — with more than 200 missed, the remainder arrives
    only after the next reconnect.
23. `KeyStore.swift:67-75` — the app and the NSE can generate different
    `.masterkey` files at the same time.
24. `Database.swift:7-15` — the NSE and the app share one SQLite, and
    SQLITE_BUSY is swallowed by `try? db.write`.
25. `ChatListModel.blockRequest:157-165` deletes the chat locally only.
26. `SyncEngine.applyContent:312-320` — an UPDATE by msgId with no matching row
    is a no-op, so an edit or reaction against an original still stuck in
    `pendingDecrypt` is lost.
27. `ChatViewModel.storeHistoric:329` skips `edit` and `reaction`.
28. `storeIncoming:296-303` stores the undecryptable placeholder, including for
    a transient `"exception"`, and msgId dedup then blocks the real content when
    it arrives later.
29. `index.ts:287-295` — `/api/chats/:id/invite` does not check membership.
30. `UserSessionDO.ts:277` — offline presence comes only from `webSocketClose`
    and `webSocketError`.
31. `ChatViewModel.markVisibleRead:296` runs on every database tick while
    `isViewingBottom` is true, which is the default, so a backgrounded app marks
    messages read.
32. `InputBar.swift:83-85` — `text = e.text` happens only in the banner's
    `onAppear`.
33. `E2EE.swift:138-140` — `checkTrust` looks at `bundles.first`.
34. `E2EE.encryptPairwise:129-153` — zero bundles produce an empty envelope with
    no error.
35. `SyncEngine.swift:510` — skd is sent with a fresh `UUID()` clientMsgId on
    every attempt.
36. `WSClient.swift:32-36` — calling `events()` again overwrites the
    continuation.
37. `ChatViewModel.react:239` — `targetMsgId = msg.msgId ?? msg.id`, so before
    the ack it goes out with the clientMsgId.
