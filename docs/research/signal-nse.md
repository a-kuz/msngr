# Signal-iOS NSE: как устроен эталон

> Signal-iOS — GPLv3: справка описывает принципы, перенос кода запрещён.

Источник: https://github.com/signalapp/Signal-iOS, commit `a9f55ea599`, изучен 2026-08-13. Пути и номера строк относятся к этому коммиту. Ключевые файлы: `SignalNSE/NotificationService.swift`, `SignalNSE/NSEEnvironment.swift`, `SignalNSE/NSEContext.swift`, `SignalNSE/NSECallMessageHandler.swift`, `SignalNSE/NSELogger.swift`, плюс `SignalServiceKit`.

## 1. Общая GRDB-база в app group

Как у Signal:

- База лежит в контейнере app group: `NSEContext.appDatabaseBaseDirectoryPath` возвращает путь контейнера группы (NSEContext.swift:31-40), сам файл — `<group>/grdb/signal.sqlite` (GRDBDatabaseStorageAdapter.swift:53-61).
- Оба процесса открывают `DatabasePool` (не Queue): `GRDBStorage.pool` (GRDBDatabaseStorageAdapter.swift:615, 632-656). Пул создаётся внутри `NSFileCoordinator.coordinate(writingItemAt:options:.forMerging)` — приём из GRDB-документации SharingADatabase, чтобы создание/первая миграция файла не гонялась между процессами.
- WAL включён (пул GRDB всегда WAL); WAL/SHM-файлы лежат рядом (`walFileUrl`/`shmFileUrl`, GRDBDatabaseStorageAdapter.swift:803-815). После write-транзакций сами делают truncate-checkpoint с дебаунсом ~750 мс на отдельной utility-очереди, обёрнутый в background task (GRDBDatabaseStorageAdapter.swift:103-122, 378-420); огромный поясняющий комментарий — строки 447-527.
- busy handler: колбэк спит по 25 мс и в обычных write никогда не сдаётся, но во время checkpoint действует таймаут ~50 мс (`GRDBStorage.maxBusyTimeoutMs = 50`, busyMode — GRDBDatabaseStorageAdapter.swift:620, 693-711; флаг таймаута хранится в thread-local, строки 658-669). То есть checkpoint не блокирует чужой процесс: при контеншене он просто отменяется (SQLITE_BUSY трактуется как норма, строки 944-953).
- В расширениях урезают ресурсы: `maximumReaderCount` = 4 против 10 в приложении (строка 692); SQLite `cache_size` на соединение режется до 2000 KiB / (4+1) (prepareDatabase, строки 211-219).
- Против 0xdead10cc прямой «suspend-хук» не используется. Стратегия: короткие транзакции (в фоне батч расшифровки = 1 сообщение — MessageProcessor.swift:201-208, тот же приём с комментарием про 0xdead10cc в GroupMessageProcessor.swift:114) плюс аккуратное завершение: перед вызовом contentHandler NSE дожидается закрытия сокета и всех отложенных операций (`stopAndWaitBeforeSuspending`, BackgroundMessageFetcher.swift:145-162), так что к моменту суспенда файловые локи не удерживаются.
- File protection: entitlements ставят дефолт NSFileProtectionComplete (SignalNSE.entitlements), но папке БД явно назначается `.completeUntilFirstUserAuthentication` (`OWSFileSystem.protectFileOrFolder`, OWSFileSystem.swift:116; вызов при создании storage — GRDBDatabaseStorageAdapter.swift:628). Ключ SQLCipher в keychain с `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; если телефон ещё не разблокирован после ребута, keychain недоступен и NSE вместо обработки показывает статичное уведомление «разблокируйте телефон» (комментарий GRDBDatabaseStorageAdapter.swift:189-194; обработка `KeychainError.notAllowed` — NotificationService.swift:124-136). Также ставят `PRAGMA cipher_plaintext_header_size = 32` (строка 207), чтобы заголовок SQLCipher-файла оставался читаемым системе в WAL-режиме shared-контейнера.
- Инвалидация кэшей между процессами: `SDSCrossProcess` шлёт Darwin-notification после каждой write-транзакции и слушает нотификации всех остальных типов процессов (SDSCrossProcess.swift:13-48; подключение — SDSDatabaseStorage.swift:19, 48-60, 292).

Перенос на msngr: базу придётся переместить из Application Support в app group и открывать через `DatabasePool` в обоих процессах (наш единый `DatabaseQueue` не работает межпроцессно); WAL + защита `.completeUntilFirstUserAuthentication` на каталог БД, ключ в keychain c `afterFirstUnlockThisDeviceOnly`, а при его недоступности показывать статичный баннер вместо расшифровки. Короткие write-транзакции в NSE (одно сообщение за транзакцию) и завершение didReceive только после закрытия всех сетевых/файловых ресурсов закрывают тему 0xdead10cc без специального suspend-механизма.

## 2. Гонки за ratchet-состояние между NSE и приложением

Как у Signal: расшифровка привязана к одному websocket-соединению с сервером, и само право держать это соединение арбитрируется межпроцессно.

- `ConnectionLock` (SignalServiceKit/Network/ConnectionLock.swift) — байтовые advisory-локи fcntl на файле `chat-connection.lock` в app group + Darwin-notifications для «попроси младшего отойти». Приоритеты: share extension = 1, main app = 2, NSE = 3, меньше = важнее (OWSChatConnection.swift:880-887). Открытие сокета требует захвата лока (`connectChatService` → `acquireConnectionLock`, OWSChatConnection.swift:975-976, 1054-1062); при закрытии лок отпускается (1016-1031, 1064-1071).
- Когда более важный процесс хочет соединение, он лочит «сигнальный» байт и постит Darwin-notification; менее важный по колбэку `onInterrupt` цикл ует и закрывает свой сокет (ConnectionLock.swift:41-96; обработчик — OWSChatConnection.swift:1056-1059 «Cycling the socket because the connection lock was interrupted»).
- NSE замечает потерю соединения через гонку двух ожиданий: «дождаться конца обработки» против «сокет должен закрыться» (`waitForFetchingProcessingAndSideEffects` + `waitUntilSocketShouldBeClosedIfCanUseSockets`, BackgroundMessageFetcher.swift:91-116). Если main app забрал соединение, второе ожидание бросает ошибку и NSE тихо завершается, оставив обработку приложению. Флагов в UserDefaults типа «main app запущен» в текущем коде нет; арбитраж целиком на файловых локах + Darwin-notifications.
- Итог для ratchet: раз входящие приходят только по одному identified-сокету и держит его ровно один процесс, два процесса никогда не расшифровывают параллельно, ratchet-состояние в общей БД мутируется последовательно.
- Дополнительно есть `MessagePipelineSupervisor` — refcount-подавление конвейера обработки внутри процесса (MessagePipelineSupervisor.swift:31-146). NSE использует его при входящем звонке: складывает call-payload в БД, суспендит собственную обработку на 10 секунд и будит приложение через `CXProvider.reportNewIncomingVoIPPushPayload`, чтобы приложение забрало звонок (NSECallMessageHandler.swift:168-204).

Перенос на msngr: наш SyncEngine actor сериализует ratchet внутри процесса, но между процессами нужен внешний арбитр. Достаточно одного fcntl-лока на файл в app group («кто держит соединение/обработку») плюс Darwin-notification «приложение проснулось, NSE, отпусти»; NSE при потере лока завершает didReceive с тем, что успел, а состояние ratchet трогает только владелец лока.

## 3. Bootstrap окружения в NSE

Как у Signal:

- Окружение — глобальный синглтон процесса (`globalEnvironment = NSEEnvironment()`, NotificationService.swift:29-31): NSE-процесс живёт дольше одного пуша и может обрабатывать несколько пушей параллельно, поэтому БД/логи/DI поднимаются один раз на процесс, а не на didReceive.
- `NSEEnvironment.setUpDatabase` (NSEEnvironment.swift:44-78) лениво и один раз: открывает storage, прогоняет миграции схемы и данных, собирает DI-граф через тот же `AppSetup`, что и приложение, но с заглушками: без battery/sleep-менеджеров (nil), минимальный payments-хелпер, no-op провайдер текущего звонка, свой `NSECallMessageHandler`.
- На каждый пуш заново: перегрев кэшей, чтобы подхватить изменения, сделанные приложением (`runLaunchTasksIfNeededAndReloadCaches`, NotificationService.swift:141-142), перепроверка регистрации (`setUpLocalIdentifiers`, 143-153).
- `NSEContext` (NSEContext.swift) сообщает остальному коду, что процесс фоновый и без UI: `hasUI = false`, `isInBackground = true`, background task'и — заглушки, зато `canPresentNotifications = true` и `shouldProcessIncomingMessages = true`.
- Не поднимается: UI-стек, звонковый стек (звонки перекидываются в приложение), storage-service-синк запускается только как «дождаться устаканивания», периодические джобы — усечённый `cron.runOnce` (NotificationService.swift:215-234).
- Память: явного бюджета в коде нет (лимит NSE задаёт ОС, порядка 24 МБ — это внешнее знание, не из репозитория). В коде: DispatchSource memory-pressure с логированием (NSEContext.swift:49-67), лог memoryUsage на каждый пуш (NSEEnvironment.swift:39), в internal-сборках таймер логирует память раз в секунду (NotificationService.swift:44-55); плюс урезание читателей пула и SQLite-кэша из п.1.

Перенос на msngr: сделать NSEEnvironment-аналог как одноразовый на процесс bootstrap (открыть GRDB, KeyStore, собрать минимальный SyncEngine без UI-зависимостей), а на каждый пуш только сбрасывать/перечитывать кэши и перепроверять «залогинен ли пользователь». Всё, что тянет память (кэши картинок, превью), в NSE не создавать вообще.

## 4. Путь пуша: didReceive → баннер

Как у Signal (пуш у них пустой «wake-up», всё содержимое тянется с сервера):

1. `didReceive` кладёт работу в `SerialTaskQueue.enqueueCancellingPrevious` и сохраняет contentHandler в атомике (NotificationService.swift:83-94).
2. Прелюдия: проверка свободного диска, доступности БД (телефон не разблокирован → статичный баннер), протухшей версии приложения; отметка «APNS-токен жив» (NotificationService.swift:100-178).
3. `fetchAndProcessMessages` (NotificationService.swift:208-254): открывает websocket (через ConnectionLock из п.2), `MessageProcessor` батчами расшифровывает конверты и пишет результат в БД (MessageProcessor.swift; в фоне батч = 1).
4. Delivery receipts — да, шлют из NSE: при обработке входящего `MessageReceiver` ставит receipt в персистентную очередь (MessageReceiver.swift:1020, 2270 → ReceiptSender.swift:89-156), отправка идёт тут же по тому же соединению, и NSE перед завершением явно ждёт `waitForPendingReceipts`, а также отправки исходящих, sync-запросов и attachment-догрузок (BackgroundMessageFetcher.swift:118-143).
5. Баннеры строит не финальный contentHandler: в ходе обработки `NotificationPresenterImpl` постит отдельные `UNNotificationRequest` через `UNUserNotificationCenter.add` (UserNotificationsPresenter.swift:106-209), с `threadIdentifier = uniqueId` треда для системной группировки по чатам (строки 185-186). Постинг сериализован цепочкой Task'ов и привязан к коммиту транзакции (NotificationPresenterImpl.swift:1773-1790); завершение NSE ждёт `waitForPendingNotifications` (BackgroundMessageFetcher.swift:142, 156-161).
6. Финал: contentHandler получает контент только с обновлённым badge (unread count из БД, NotificationService.swift:246-253) — исходный пуш «гасится», видимыми остаются баннеры, запощенные в п.5.
7. Таймаут: `serviceExtensionTimeWillExpire` отменяет очередь и вызывает contentHandler с пустым контентом, чтобы система не показала сырой payload (NotificationService.swift:181-193). Специального «сохранить прогресс» нет: всё уже в БД, недообработанное доделает следующий пуш или приложение.

Перенос на msngr: didReceive → одноразовый bootstrap → SyncEngine.pullAndProcess (расшифровка + запись в GRDB + delivery receipt в персистентной очереди с ожиданием отправки) → на каждое новое сообщение отдельный UNNotificationRequest с threadIdentifier = chatId → contentHandler с badge-only контентом; в serviceExtensionTimeWillExpire отменяем задачу и завершаемся пустым контентом. Обязательно проектировать обработку идемпотентной: всё персистится до подтверждения серверу, повтор безопасен.

## 5. Гашение и фильтрация уведомлений

Как у Signal:

- Filtering entitlement есть: `com.apple.developer.usernotifications.filtering = true` в SignalNSE-AppStore.entitlements (в dev-entitlements SignalNSE.entitlements его нет). Он и позволяет завершать contentHandler «пустым» контентом без видимого баннера — так гасятся и исходный wake-up-пуш, и случаи «нечего показывать».
- «Прочитано на другом устройстве»: read sync из связанного устройства приходит в той же пачке конвертов; `OWSReceiptManager.processReadReceiptsFromLinkedDevice` (OWSReceiptManager.swift:558) помечает сообщения прочитанными и снимает уже показанные баннеры через `cancelNotifications(messageIds:)` (OWSReceiptManager.swift:842 → NotificationPresenterImpl.swift:1720-1734 → `removeDeliveredNotifications` в UserNotificationsPresenter.swift:356, 458). Поскольку постинг баннеров сериализован после записи в БД, сообщение, прочитанное в той же пачке, чаще просто не доходит до баннера.
- Ложные/служебные пуши: запрос кода верификации обрабатывается и завершается пустым контентом без fetch (NotificationService.swift:155-167); call-сообщения не показываются NSE, а перекидываются в приложение (NSECallMessageHandler.swift).

Перенос на msngr: заказать filtering entitlement у Apple заранее (ревью по заявке, дают мессенджерам с E2EE); в NSE после обработки пачки сверять «остались ли непрочитанные из этой пачки» и снимать доставленные баннеры по message-id при read-sync с другого устройства. Идентификатор UNNotificationRequest делать равным messageId, чтобы снятие было адресным.

## 6. Логирование и диагностика

Как у Signal:

- Файловые логи NSE пишутся в app group: каталог `<group>/NSELogs` (DebugLogger.swift:94-98), поэтому приложение видит их и включает в выгрузку debug-логов вместе со своими и share-extension (`allLogsDirPaths`, DebugLogger.swift:104-108). Ротация: до 3 файлов, 12 МБ/файл, по дням; форматтер скраббит чувствительные данные (DebugLogger.swift:134-160). Файлы логов с protection `.completeUntilFirstUserAuthentication`, раз пишутся до разблокировки (DebugLogger.swift:139).
- Корреляция: каждый didReceive получает свой `NSELogger` с префиксом `[NSE]` и UUID-суффиксом (NSELogger.swift:12-17) — параллельные пуши в одном процессе различимы в логе. Логи явно `flush()`-ятся в ключевых точках (NotificationService.swift:72, 108-112 и др.), потому что убийство процесса теряет буфер.
- Диагностика невидимых смертей: pid и memoryUsage логируются на каждый пуш (NSEEnvironment.swift:39) — смена pid в логе выдаёт перезапуск/смерть процесса; memory-pressure source пишет warning'и (NSEContext.swift:49-67); маркер `nseLaunchDidComplete` фиксирует версию последнего успешно завершённого запуска NSE (AppVersion.swift:315-319, вызов NSEEnvironment.swift:92) — расхождение с текущей версией видно при следующем запуске; в internal-сборках память логируется раз в секунду (NotificationService.swift:44-55).

Перенос на msngr: писать NSE-лог в отдельный каталог app group с ротацией и явным flush после каждого этапа, префиксовать записи per-push UUID, логировать pid+память на входе; в основной приложение добавить экран/экспорт «все логи, включая NSE». Плюс маркер «NSE стартовал/завершился» в shared UserDefaults: незакрытый маркер при следующем запуске = молчаливая смерть (jetsam или 30 с).
