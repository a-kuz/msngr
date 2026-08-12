# Аудит кода 2026-08-12 (независимый агент-аудитор)

Статус каждого пункта: `open` — не проверен, `confirmed` — воспроизведён, `fixed` — починен с тестом, `rejected` — не баг (с объяснением).

| # | Статус | Кратко |
|---|--------|--------|
| 1 | open | /api/join: DO отвергает не-участника, viaInvite не читается, клиенту ok:true |
| 2 | open | Возврат из ChatInfo: onDisappear → stop(), start() гвардится по started — лента мертва |
| 3 | open | One-time prekeys выжигаются GET /prekeys на каждое сообщение, пополнения нет |
| 4 | open | Медиа/голосовые офлайн теряются: upload до enqueue, try? глотает |
| 5 | open | Обрыв между skd и skm: distributedTo помечен до отправки — группа в вечном no_sender_key |
| 6 | open | Kill во время отправки: inflight не сбрасывается в ready при рестарте |
| 7 | open | Read receipts / delete-for-all / recv офлайн: try? ws.send без очереди |
| 8 | open | Sync не реплеит тумбстоуны/read-марки — только msg-фреймы |
| 9 | open | Черновик: onAppear читает chat.draft пока chat nil; onDisappear затирает |
| 10 | open | expiresAt никогда не применяется — автоудаление не работает |
| 11 | open | identityChanged в группе: outbox blocked, но баннер только для direct |
| 12 | open | Push не шлётся пока жив подвешенный сокет (live.length === 0) |
| 13 | open | Реакции/edit/skd растят unreadCount — бейдж без сообщения |
| 14 | open | Возврат из фона: нет форс-реконнекта/ресинка, stale connected |
| 15 | open | Accept заявки офлайн: try? глотает, снапшот воскрешает заявку |
| 16 | open | Краш: Dictionary(uniqueKeysWithValues:) на дубликатах id (дата-сепараторы) |
| 17 | open | LIMIT 500 в ленте: история докачивается в БД, но не показывается |
| 18 | open | Delete-for-all чужого в direct: локально удалено, у собеседника нет |
| 19 | open | Голосовое без requestRecordPermission — пустая запись |
| 20 | open | setInsets никем не вызывается: контент под навбаром и инпутом |
| 21 | open | Typing-индикатор залипает: нет таймера, нет typing stop |
| 22 | open | Sync-лимит 200 без продолжения до следующего reconnect |
| 23 | open | Гонка генерации master key между app и NSE |
| 24 | open | Два процесса на одной DatabaseQueue без busy_timeout — молчаливый SQLITE_BUSY |
| 25 | open | Блокировка заявки только локальная, снапшот возвращает чат |
| 26 | open | Edit/reaction на нерасшифрованный target — no-op без повтора |
| 27 | open | loadOlder теряет реакции и правки исторических сообщений |
| 28 | open | undecryptable-плейсхолдер блокирует поздний контент по дедупу msgId |
| 29 | open | /api/chats/:id/invite не проверяет членство |
| 30 | open | Stale «в сети»: offline-презенс только из webSocketClose |
| 31 | open | Read receipt из свёрнутого приложения (isViewingBottom default true) |
| 32 | open | Edit A → edit B: в поле остаётся текст A (onAppear баннера) |
| 33 | open | TOFU проверяет только bundles.first — второе устройство не детектится |
| 34 | open | Ноль бандлов → пустой конверт «успешно отправлен» |
| 35 | open | skd с новым UUID на каждый ретрай — дубликаты в истории, двигают seq |
| 36 | open | WSClient.events() одноразовый: повторный вызов убивает старый стрим |
| 37 | open | Реакция на своё сообщение до ack уходит с clientMsgId — видна только автору |

Полные описания с файлами и строками — в тексте аудита ниже.

## Детали

1. `server/src/index.ts:303` — `/api/join` дергает `/members` с `actor` = вступающий, а `ConversationDO.ts:291` отвергает не-участника (`not_member`); флаг `viaInvite` в DO не читается. Результат `r` игнорируется (`void r`), клиенту возвращается `ok:true`.
2. `ChatScreen.swift:56-61` — `onDisappear` срабатывает и при push в `ChatInfoView`, вызывает `model.stop()`; при возврате `start()` отсекается по `guard !started` (`ChatViewModel.swift:48`) — ValueObservation не пересоздаётся.
3. `index.ts:118-124` удаляет OTP при каждом GET `/prekeys`, а `E2EE.swift:125` запрашивает бандлы на каждое отправляемое сообщение. `generateMoreOneTime`/`uploadPrekeys` никем не вызываются.
4. `ChatScreen.swift:248,297,332` — upload идёт до `enqueue`; без сети `try? upload` падает, `guard` выходит: сообщение не попадает в outbox.
5. `E2EE.swift:85-90` помечает устройства в `distributedTo` и сохраняет до отправки; если `ws.send(skd)` в `SyncEngine.swift:510` упал, при ретрае `missing` пуст.
6. `SyncEngine.swift:519` ставит `state='inflight'`, страховочный откат — in-memory Task на 15с. После kill при рестарте нет сброса `inflight→ready`.
7. `SyncEngine.swift:555,576,230` — read receipts, delete-for-all, recv уходят через `try? ws.send` без очереди.
8. `UserSessionDO.ts:240-273` — sync реплеит только `msg`-фреймы по курсорам; тумбстоуны, read-марки и смены состава — только при полном `refreshSnapshot`.
9. `ChatScreen.swift:53` — `text = model.chat?.draft` в `onAppear`, но `chat` грузится асинхронно и в этот момент nil; `onDisappear` перезапишет draft пустым.
10. `expiresAt` проставляется входящим (`SyncEngine.swift:337`), но нигде не читается; исходящие без `expiresAt`.
11. `SyncEngine.swift:456` ставит outbox `blocked` и для групповых, но `keyChangePending` считается только для direct (`ChatViewModel.swift:106`).
12. `UserSessionDO.ts:102` — push только при `live.length === 0`; iOS держит WS живым минуты после сворачивания.
13. Каждый send получает seq (`ConversationDO.ts:167`), а `applyIncomingMessage` (`SyncEngine.swift:217-227`) растит `lastSeq`/`unreadCount` для любых фреймов.
14. `AppState.scenePhaseChanged:105` только обнуляет лок; мёртвый сокет обнаружится через ping-таймаут или backoff до 30с (`WSClient.swift:139`).
15. `ChatViewModel.acceptRequest:267` — `try? api.acceptChat` молча падает, локально `isRequest=0`; следующий снапшот вернёт `isRequest`.
16. `MessagesViewController.swift:83-84` — `Dictionary(uniqueKeysWithValues:)` трапается при повторе id; id дата-сепараторов по label — при немонотонном `sentAt` один день дважды → краш.
17. `ChatViewModel.swift:57` LIMIT 500 — `loadOlder` докачивает в БД, лента не показывает.
18. Клиент тумбстоунит локально сразу (`SyncEngine.swift:566`), сервер молча пропускает не-своё для не-админа (`ConversationDO.ts:274`).
19. `Voice.swift:15` — `start()` не вызывает `requestRecordPermission`.
20. `MessagesViewController.swift:50` + `contentInsetAdjustmentBehavior = .never` — `setInsets` никем не вызывается.
21. `ChatListModel.swift:95-106` — истечение 5с проверяется лениво, таймера нет; typing stop не шлётся.
22. `UserSessionDO.ts:258` — при >200 пропущенных остаток только после следующего reconnect.
23. `KeyStore.swift:67-75` — app и NSE могут одновременно сгенерировать разные `.masterkey`.
24. `Database.swift:7-15` — NSE и приложение на одном SQLite; SQLITE_BUSY гасится `try? db.write`.
25. `ChatListModel.blockRequest:157-165` удаляет чат только локально.
26. `SyncEngine.applyContent:312-320` — UPDATE по msgId без строки = no-op; edit/reaction на застрявший в pendingDecrypt оригинал теряются.
27. `ChatViewModel.storeHistoric:329` пропускает `edit/reaction`.
28. `storeIncoming:296-303` сохраняет undecryptable-плейсхолдер (включая транзиентный `"exception"`) — дедуп по msgId блокирует поздний реальный контент.
29. `index.ts:287-295` — `/api/chats/:id/invite` не проверяет членство.
30. `UserSessionDO.ts:277` — offline-презенс только из `webSocketClose/Error`.
31. `ChatViewModel.markVisibleRead:296` на каждый DB-тик при `isViewingBottom=true` (default) — прочтение из свёрнутого приложения.
32. `InputBar.swift:83-85` — `text = e.text` только в `onAppear` баннера.
33. `E2EE.swift:138-140` — `checkTrust` по `bundles.first`.
34. `E2EE.encryptPairwise:129-153` — ноль бандлов → пустой конверт без ошибки.
35. `SyncEngine.swift:510` — skd с новым `UUID()` clientMsgId на каждую попытку.
36. `WSClient.swift:32-36` — повторный `events()` перезаписывает continuation.
37. `ChatViewModel.react:239` — `targetMsgId = msg.msgId ?? msg.id`; до ack уходит clientMsgId.
