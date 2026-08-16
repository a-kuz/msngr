# Аудит кода 2026-08-12 (независимый агент-аудитор)

Статус каждого пункта: `open` — не проверен, `confirmed` — воспроизведён, `fixed` — починен с тестом, `rejected` — не баг (с объяснением).

Re-triaged against the code on 2026-08-16; every item carries a `2026-08-16:` line
with what the check found. Fixes made during that sweep are in
`docs/qa/runs/2026-08-16-audit-sweep.md`.

| # | Статус | Кратко |
|---|--------|--------|
| 1 | fixed | /api/join: DO отвергает не-участника, viaInvite не читается, клиенту ok:true |
| 2 | fixed | Возврат из ChatInfo: onDisappear → stop(), start() гвардится по started — лента мертва |
| 3 | fixed | One-time prekeys выжигаются GET /prekeys на каждое сообщение, пополнения нет |
| 4 | fixed | Медиа/голосовые офлайн теряются: upload до enqueue, try? глотает |
| 5 | fixed | Обрыв между skd и skm: distributedTo помечен до отправки — группа в вечном no_sender_key |
| 6 | fixed | Kill во время отправки: inflight не сбрасывается в ready при рестарте |
| 7 | fixed | Read receipts / delete-for-all / recv офлайн: try? ws.send без очереди |
| 8 | fixed | Sync не реплеит тумбстоуны/read-марки — только msg-фреймы |
| 9 | fixed | Черновик: onAppear читает chat.draft пока chat nil; onDisappear затирает |
| 10 | fixed | expiresAt никогда не применяется — автоудаление не работает |
| 11 | fixed | identityChanged в группе: outbox blocked, но баннер только для direct |
| 12 | fixed | Push не шлётся пока жив подвешенный сокет (live.length === 0) |
| 13 | confirmed | Реакции/edit/skd растят unreadCount — бейдж без сообщения |
| 14 | fixed | Возврат из фона: нет форс-реконнекта/ресинка, stale connected |
| 15 | fixed | Accept заявки офлайн: try? глотает, снапшот воскрешает заявку |
| 16 | fixed | Краш: Dictionary(uniqueKeysWithValues:) на дубликатах id (дата-сепараторы) |
| 17 | fixed | LIMIT 500 в ленте: история докачивается в БД, но не показывается |
| 18 | confirmed | Delete-for-all чужого в direct: локально удалено, у собеседника нет |
| 19 | confirmed | Голосовое без requestRecordPermission — пустая запись |
| 20 | fixed | setInsets никем не вызывается: контент под навбаром и инпутом |
| 21 | fixed | Typing-индикатор залипает: нет таймера, нет typing stop |
| 22 | fixed | Sync-лимит 200 без продолжения до следующего reconnect |
| 23 | rejected | Гонка генерации master key между app и NSE |
| 24 | fixed | Два процесса на одной DatabaseQueue без busy_timeout — молчаливый SQLITE_BUSY |
| 25 | fixed | Блокировка заявки только локальная, снапшот возвращает чат |
| 26 | fixed | Edit/reaction на нерасшифрованный target — no-op без повтора |
| 27 | fixed | loadOlder теряет реакции и правки исторических сообщений |
| 28 | fixed | undecryptable-плейсхолдер блокирует поздний контент по дедупу msgId |
| 29 | fixed | /api/chats/:id/invite не проверяет членство |
| 30 | fixed | Stale «в сети»: offline-презенс только из webSocketClose |
| 31 | fixed | Read receipt из свёрнутого приложения (isViewingBottom default true) |
| 32 | fixed | Edit A → edit B: в поле остаётся текст A (onAppear баннера) |
| 33 | fixed | TOFU проверяет только bundles.first — второе устройство не детектится |
| 34 | fixed | Ноль бандлов → пустой конверт «успешно отправлен» |
| 35 | fixed | skd с новым UUID на каждый ретрай — дубликаты в истории, двигают seq |
| 36 | rejected | WSClient.events() одноразовый: повторный вызов убивает старый стрим |
| 37 | fixed | Реакция на своё сообщение до ack уходит с clientMsgId — видна только автору |

Полные описания с файлами и строками — в тексте аудита ниже.

## Детали

1. `server/src/index.ts:303` — `/api/join` дергает `/members` с `actor` = вступающий, а `ConversationDO.ts:291` отвергает не-участника (`not_member`); флаг `viaInvite` в DO не читается. Результат `r` игнорируется (`void r`), клиенту возвращается `ok:true`.
   2026-08-16: fixed earlier. `/api/join` passes `viaInvite: true` and returns the DO's error (`server/src/index.ts:464-470`); the DO builds `selfJoin` and only then skips the rejection (`ConversationDO.ts:672-682`). Covered by `server/test/smoke.mjs:405-417`.
2. `ChatScreen.swift:56-61` — `onDisappear` срабатывает и при push в `ChatInfoView`, вызывает `model.stop()`; при возврате `start()` отсекается по `guard !started` (`ChatViewModel.swift:48`) — ValueObservation не пересоздаётся.
   2026-08-16: fixed earlier. `onDisappear` returns before `stop()` when the push into ChatInfo caused it (`ChatScreen.swift:116-124`), and `start()` guards on `cancellable == nil`, which `stop()` clears (`ChatViewModel.swift:97-98, 216-223`).
3. `index.ts:118-124` удаляет OTP при каждом GET `/prekeys`, а `E2EE.swift:125` запрашивает бандлы на каждое отправляемое сообщение. `generateMoreOneTime`/`uploadPrekeys` никем не вызываются.
   2026-08-16: fixed earlier. Device addresses come from `/api/devices`, which spends nothing (`server/src/index.ts:186-205`); a bundle is fetched only for a device without a session (`E2EE.swift:254-269`). `SyncEngine.start()` tops the pool up below 20 (`SyncEngine.swift:92, 111-124`).
4. `ChatScreen.swift:248,297,332` — upload идёт до `enqueue`; без сети `try? upload` падает, `guard` выходит: сообщение не попадает в outbox.
   2026-08-16: fixed earlier. Every attachment path stashes the source into the app-group pending dir and enqueues at once (`ChatScreen.swift:540-654`); the upload moved into the outbox worker, where a network error is an ordinary retry (`SyncEngine.swift:1434-1438, 1501-1557`).
5. `E2EE.swift:85-90` помечает устройства в `distributedTo` и сохраняет до отправки; если `ws.send(skd)` в `SyncEngine.swift:510` упал, при ретрае `missing` пуст.
   2026-08-16: fixed earlier. `distributedTo` is filled only from the recipient's ack (`E2EE.swift:134-145`, `SyncEngine.swift:949-953`); the send attempt is remembered separately in `attemptedAt` and redistributed after 60 s (`E2EE.swift:91-96, 109`). Test `MessageRepairTests.testSenderKeyConfirmationClosesDistribution`.
6. `SyncEngine.swift:519` ставит `state='inflight'`, страховочный откат — in-memory Task на 15с. После kill при рестарте нет сброса `inflight→ready`.
   2026-08-16: fixed earlier. `start()` resets the stuck rows before anything else (`SyncEngine.swift:64-69`). Test `OfflineReliabilityTests.testStartResetsInflightToReady`.
7. `SyncEngine.swift:555,576,230` — read receipts, delete-for-all, recv уходят через `try? ws.send` без очереди.
   2026-08-16: fixed earlier. Read marks, delete-for-all, accept and chat-delete go through the durable `pendingAction` queue drained on `.connected` (`SyncEngine.swift:1565-1626, 1646-1748`). Tests in `OfflineReliabilityTests`. The recv ack stays fire-and-forget on purpose: delivered marks are monotonic on both sides, so a lost one is absorbed by the next.
8. `UserSessionDO.ts:240-273` — sync реплеит только `msg`-фреймы по курсорам; тумбстоуны, read-марки и смены состава — только при полном `refreshSnapshot`.
   2026-08-16: tombstones and marks were already replayed by `sendChatTail`; membership was not, and a member who was offline while somebody was removed never rotated the sender key, so he kept encrypting to a chain the removed user holds. Fixed: `/events` carries the roster, catch-up replays it, rotation triggers on any frame whose roster shrank, and a member who was removed is told so. Tests `server/test/smoke.mjs` ("catch-up replays the roster", "catch-up tells the removed member") and `MembershipReplayTests`.
9. `ChatScreen.swift:53` — `text = model.chat?.draft` в `onAppear`, но `chat` грузится асинхронно и в этот момент nil; `onDisappear` перезапишет draft пустым.
   2026-08-16: fixed earlier. The draft is filled when the chat arrives, into an empty field only (`ChatScreen.swift:101-115`), and every keystroke persists it (`ChatViewModel.swift:580-601`).
10. `expiresAt` проставляется входящим (`SyncEngine.swift:337`), но нигде не читается; исходящие без `expiresAt`.
    2026-08-16: confirmed — the field was written and never read, and outgoing copies were never stamped, so the TTL switch in ChatInfo promised and did nothing. Fixed on the device: the outgoing copy is stamped when its ack arrives and the historic one when it is pulled, and a sweep takes what expired along with its attachments, closing the seq with a `historyGap` record the way clearing does. The server journal still keeps the envelope — the expiry is this device's, not the conversation's. Tests in `DisappearingTests`.
11. `SyncEngine.swift:456` ставит outbox `blocked` и для групповых, но `keyChangePending` считается только для direct (`ChatViewModel.swift:106`).
    2026-08-16: confirmed — in a group the block is reachable (a changed key means a new device, so `missing` is non-empty and the distribution goes pairwise) and the banner was direct-only, leaving the send blocked with no action. Fixed: the pending change is read over every member of the chat and accepting covers all of them. Tests `KeyChangeTests.testAcceptCoversEveryMemberOfTheChat`, `testAcceptLeavesOutsidersPending`.
12. `UserSessionDO.ts:102` — push только при `live.length === 0`; iOS держит WS живым минуты после сворачивания.
    2026-08-16: fixed earlier. The push goes out for every non-service, non-muted, non-echo `msg` regardless of live sockets (`UserSessionDO.ts:168-187`). Test `server/test/smoke.mjs:750-752`.
13. Каждый send получает seq (`ConversationDO.ts:167`), а `applyIncomingMessage` (`SyncEngine.swift:217-227`) растит `lastSeq`/`unreadCount` для любых фреймов.
    2026-08-16: the client half was fixed earlier (`SyncEngine.advanceChat`, test `ServiceFrameTests.testServiceFrameDoesNotGrowUnread`), but the badge is the server's number and `/unread-count` counted `lastSeq − readMark`, service frames included. Fix pending.
14. `AppState.scenePhaseChanged:105` только обнуляет лок; мёртвый сокет обнаружится через ping-таймаут или backoff до 30с (`WSClient.swift:139`).
    2026-08-16: fixed earlier. Foreground calls `appBecameActive` → `ws.nudge()`, which cancels the backoff and reconnects at once (`AppState.swift:259-281`, `SyncEngine.swift:143-157`, `WSClient.swift:238-248`); the backoff cap is 12 s.
15. `ChatViewModel.acceptRequest:267` — `try? api.acceptChat` молча падает, локально `isRequest=0`; следующий снапшот вернёт `isRequest`.
    2026-08-16: confirmed on the chat-list path only — the chat screen queues the accept durably, the list swipe still called the API directly and flipped the flag regardless, leaving the server at `accepted = false` forever. Fixed: the swipe goes through the same queued accept as the chat screen.
16. `MessagesViewController.swift:83-84` — `Dictionary(uniqueKeysWithValues:)` трапается при повторе id; id дата-сепараторов по label — при немонотонном `sentAt` один день дважды → краш.
    2026-08-16: fixed earlier. Separator ids derive from the message id (`ChatViewModel.swift:347-353`) and the diff uses `uniquingKeysWith:` (`MessagesViewController.swift:194-195`). Tests `ChatFeedTests.testSeparatorIdsUniqueForNonMonotonicSentAt`, `HistoryFeedTests.testFeedIdsStayUnique`.
17. `ChatViewModel.swift:57` LIMIT 500 — `loadOlder` докачивает в БД, лента не показывает.
    2026-08-16: fixed earlier. The feed reads a window whose floor and capacity are state, and `loadOlder` lowers the floor (`FeedWindow.swift`, `ChatViewModel.swift:154-168, 623-663`). Tests in `FeedWindowTests`.
18. Клиент тумбстоунит локально сразу (`SyncEngine.swift:566`), сервер молча пропускает не-своё для не-админа (`ConversationDO.ts:274`).
    2026-08-16: the server behaviour is deliberate and pinned by `server/test/smoke.mjs:298-308`, and iOS stopped offering the action on a foreign message. The macOS target still offered it on every bubble, so the divergence survived there. Fix pending.
19. `Voice.swift:15` — `start()` не вызывает `requestRecordPermission`.
    2026-08-16: confirmed — no permission request anywhere, so the first take records over the system prompt and a denial leaves the mic button silently dead. Fix pending.
20. `MessagesViewController.swift:50` + `contentInsetAdjustmentBehavior = .never` — `setInsets` никем не вызывается.
    2026-08-16: fixed earlier. Insets are recomputed on every layout pass and keyboard change (`MessagesViewController.swift:110, 118-135`).
21. `ChatListModel.swift:95-106` — истечение 5с проверяется лениво, таймера нет; typing stop не шлётся.
    2026-08-16: fixed earlier. Both consumers hold a real timer (`ChatViewModel.swift:134-138`, `ChatListModel.swift:117-124`) and a stop frame goes out when the field empties (`ChatViewModel.swift:583-587`).
22. `UserSessionDO.ts:258` — при >200 пропущенных остаток только после следующего reconnect.
    2026-08-16: fixed earlier. Catch-up is served in bounded portions that state what is left, and the client asks for the next one inside the same connection (`UserSessionDO.ts:10-18, 437-467`, `SyncEngine.swift:316-341`). Tests `server/test/smoke.mjs:492-532`, `CatchupCursorTests`.
23. `KeyStore.swift:67-75` — app и NSE могут одновременно сгенерировать разные `.masterkey`.
    2026-08-16: rejected — the extension reads the key only when `session.json` is next to it (`NotificationService.swift:59-71`), and registration writes the key before the session (`RegisterView.swift:93, 115`), so the file exists before the first push. It was not true on 12 August either: that revision's extension never built an `IdentityStore`.
24. `Database.swift:7-15` — NSE и приложение на одном SQLite; SQLITE_BUSY гасится `try? db.write`.
    2026-08-16: fixed earlier. The file is opened with `busyMode = .timeout(5)`, immediate transactions and WAL, by both processes (`Database.swift:22-35`, `NotificationService.swift:47`), so a cross-process conflict waits instead of failing.
25. `ChatListModel.blockRequest:157-165` удаляет чат только локально.
    2026-08-16: confirmed — the block reached the server but the chat did not, so the next snapshot brought the request back, and without a tombstone it came back at seq 0 and re-requested journal ranges whose keys are gone. Fixed: rejecting runs the same queued chat delete as any other deletion, and the block itself became a queued action too, so neither half is lost offline (migration v17 — `pendingAction.chatId` is now optional). Tests `OfflineReliabilityTests.testRejectingRequestOfflineQueuesBothHalves`, `testServerListKeepsQueuedBlock`.
26. `SyncEngine.applyContent:312-320` — UPDATE по msgId без строки = no-op; edit/reaction на застрявший в pendingDecrypt оригинал теряются.
    2026-08-16: fixed earlier. A zero-row update parks the event in `pendingApply`, applied when the original lands (`SyncEngine.swift:1102-1124, 1868-1901`). Tests `ServiceFrameTests.testReactionAndEditBeforeOriginalApplyAfter`, `testDeletedBeforeOriginalAndReplay`.
27. `ChatViewModel.storeHistoric:329` пропускает `edit/reaction`.
    2026-08-16: fixed earlier. `storeHistoric` handles edit, reaction and disappearing, buffering when the original is missing (`SyncEngine.swift:1155-1197`). Tests in `HistoricReplayTests`.
28. `storeIncoming:296-303` сохраняет undecryptable-плейсхолдер (включая транзиентный `"exception"`) — дедуп по msgId блокирует поздний реальный контент.
    2026-08-16: fixed earlier. No placeholder row is written at all; the envelope goes to `pendingDecrypt` with a reason and an attempt counter, and the transient `"exception"` is retryable (`SyncEngine.swift:673-716, 1084-1087`). Tests in `MessageRepairTests`.
29. `index.ts:287-295` — `/api/chats/:id/invite` не проверяет членство.
    2026-08-16: fixed earlier. The route answers `not_member` 403 unless the caller is in the roster (`server/src/index.ts:443-450`). Test `server/test/smoke.mjs:396`.
30. `UserSessionDO.ts:277` — offline-презенс только из `webSocketClose/Error`.
    2026-08-16: fixed earlier. Presence follows ping freshness with a 35 s TTL alarm, plus an explicit `bg` frame (`UserSessionDO.ts:76-82, 518-521, 610-616`). No test asserts the TTL path.
31. `ChatViewModel.markVisibleRead:296` на каждый DB-тик при `isViewingBottom=true` (default) — прочтение из свёрнутого приложения.
    2026-08-16: fixed earlier. The mark bails when the scene is not active, and `isViewingBottom` follows whether item 0 is on screen (`ChatViewModel.swift:610-615`, `AppState.swift:259-270`). Test `ViewingBottomTests`.
32. `InputBar.swift:83-85` — `text = e.text` только в `onAppear` баннера.
    2026-08-16: fixed earlier. The field refills from a change of the edited message's identity (`ChatScreen.swift:128-131`).
33. `E2EE.swift:138-140` — `checkTrust` по `bundles.first`.
    2026-08-16: fixed earlier. Trust is checked over every device of every recipient, and the device list comes from `/devices` rather than from bundles (`E2EE.swift:186-189, 203-211`).
34. `E2EE.encryptPairwise:129-153` — ноль бандлов → пустой конверт без ошибки.
    2026-08-16: fixed earlier. A recipient with no device throws `E2EEError.noDevices` before encryption (`E2EE.swift:199-201`), and the device list and the bundle list come from the same table, so zero bundles for an existing device is not reachable.
35. `SyncEngine.swift:510` — skd с новым `UUID()` clientMsgId на каждую попытку.
    2026-08-16: fixed earlier. The distribution id is derived from the chat, the key id, the sorted recipients and the round (`E2EE.swift:106-108, 127-131`), and a repeat inside the 60 s window produces no new distribution at all.
36. `WSClient.swift:32-36` — повторный `events()` перезаписывает continuation.
    2026-08-16: rejected as written. The overwrite is still in the code (`WSClient.swift:42-46`), but `events()` has exactly one call site, `SyncEngine.start()`, and no path starts an engine twice: `AppState.bootstrap` and `MacApp` build a fresh engine each time and `resetToRegistration` drops it. Nothing to reproduce; worth a guard the day a second consumer appears.
37. `ChatViewModel.react:239` — `targetMsgId = msg.msgId ?? msg.id`; до ack уходит clientMsgId.
    2026-08-16: confirmed, and it covers edits the same way — one double tap on a just-sent bubble is enough, and offline the window lasts as long as the outbox does. The peer parks the reaction in `pendingApply` under an id that never arrives. Fixed: the target is resolved against the message row at send time, and a service frame whose target has no server id yet waits for its ack instead of leaving. Tests `ServiceFrameTests.testReactionToUnackedTargetResolvesAtSendTime`, `testTargetFromPeerPassesThroughAndFailedTargetIsDropped`, `testAckReleasesWaitingOutboxRows`.

## Найдено попутно

- **Catch-up отдавал журнал любому аутентифицированному пользователю.**
  `UserSessionDO.serveCatchup` брал курсоры из клиентского фрейма как есть и
  ходил в `ConversationDO` `/history` и `/events`, а те членство не проверяли —
  оно жило только на REST-маршруте. Id direct-чата выводится из двух
  пользовательских id (`util.ts:57-59`), а id пользователей отдаёт
  `/api/users`, так что кадр `{"t":"sync","cursors":{"direct:<a>:<b>":0}}`
  возвращал чужую переписку целиком: конверты, seq, msgId, отправителя,
  устройство и время. Тела зашифрованы, открытого текста утечки нет.
  Чинится в этом проходе первым делом: `/history` и `/events` требуют участника.
