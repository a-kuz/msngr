# Signal-iOS NSE: how the reference implementation works

> Signal-iOS is GPLv3: this note describes principles, copying code is not allowed.

Source: https://github.com/signalapp/Signal-iOS, commit `a9f55ea599`, studied 2026-08-13. Paths and line numbers refer to that commit. Key files: `SignalNSE/NotificationService.swift`, `SignalNSE/NSEEnvironment.swift`, `SignalNSE/NSEContext.swift`, `SignalNSE/NSECallMessageHandler.swift`, `SignalNSE/NSELogger.swift`, plus `SignalServiceKit`.

## 1. A shared GRDB database in the app group

How Signal does it:

- The database lives in the app group container: `NSEContext.appDatabaseBaseDirectoryPath` returns the group container path (NSEContext.swift:31-40), and the file itself is `<group>/grdb/signal.sqlite` (GRDBDatabaseStorageAdapter.swift:53-61).
- Both processes open a `DatabasePool`, not a Queue: `GRDBStorage.pool` (GRDBDatabaseStorageAdapter.swift:615, 632-656). The pool is created inside `NSFileCoordinator.coordinate(writingItemAt:options:.forMerging)`, the technique from the GRDB SharingADatabase guide, so that creating the file and running its first migration cannot race between processes.
- WAL is on (a GRDB pool is always WAL); the WAL and SHM files sit next to the database (`walFileUrl`/`shmFileUrl`, GRDBDatabaseStorageAdapter.swift:803-815). After write transactions they run a truncate checkpoint themselves, debounced by roughly 750 ms on a separate utility queue and wrapped in a background task (GRDBDatabaseStorageAdapter.swift:103-122, 378-420); a long explanatory comment sits at lines 447-527.
- busy handler: the callback sleeps in 25 ms steps and never gives up on an ordinary write, but during a checkpoint a timeout of about 50 ms applies (`GRDBStorage.maxBusyTimeoutMs = 50`, busyMode at GRDBDatabaseStorageAdapter.swift:620, 693-711; the timeout flag is kept in thread-local storage, lines 658-669). So a checkpoint never blocks the other process: under contention it is simply abandoned, and SQLITE_BUSY is treated as a normal outcome (lines 944-953).
- Extensions get trimmed resources: `maximumReaderCount` is 4 against 10 in the app (line 692), and the SQLite `cache_size` per connection is cut to 2000 KiB / (4+1) (prepareDatabase, lines 211-219).
- Against 0xdead10cc there is no direct suspend hook. The strategy is short transactions (in the background a decryption batch is one message, MessageProcessor.swift:201-208, the same technique with a 0xdead10cc comment in GroupMessageProcessor.swift:114) together with a careful shutdown: before calling contentHandler the NSE waits for the socket to close and for every pending operation to finish (`stopAndWaitBeforeSuspending`, BackgroundMessageFetcher.swift:145-162), so no file locks are held by the time suspension arrives.
- File protection: entitlements set NSFileProtectionComplete as the default (SignalNSE.entitlements), but the database folder is explicitly given `.completeUntilFirstUserAuthentication` (`OWSFileSystem.protectFileOrFolder`, OWSFileSystem.swift:116; the call at storage creation is GRDBDatabaseStorageAdapter.swift:628). The SQLCipher key lives in the keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; if the phone has not been unlocked since reboot, the keychain is unavailable and the NSE shows a static "unlock your phone" notification instead of processing anything (comment at GRDBDatabaseStorageAdapter.swift:189-194; `KeychainError.notAllowed` handling at NotificationService.swift:124-136). They also set `PRAGMA cipher_plaintext_header_size = 32` (line 207) so that the header of the SQLCipher file stays readable to the system in WAL mode inside a shared container.
- Cross-process cache invalidation: `SDSCrossProcess` posts a Darwin notification after every write transaction and listens for the notifications of all other process types (SDSCrossProcess.swift:13-48; wiring at SDSDatabaseStorage.swift:19, 48-60, 292).

Porting to msngr: the database will have to move out of Application Support into the app group and be opened through a `DatabasePool` in both processes, since our single `DatabaseQueue` does not work across processes. WAL, `.completeUntilFirstUserAuthentication` on the database directory, the key in the keychain with `afterFirstUnlockThisDeviceOnly`, and a static banner instead of decryption when that key is unavailable. Short write transactions in the NSE (one message per transaction) and finishing didReceive only after every network and file resource is released close the 0xdead10cc question without any special suspend mechanism.

## 2. Races for ratchet state between the NSE and the app

How Signal does it: decryption is bound to a single websocket connection to the server, and the right to hold that connection is arbitrated across processes.

- `ConnectionLock` (SignalServiceKit/Network/ConnectionLock.swift) uses fcntl byte-range advisory locks on the file `chat-connection.lock` in the app group, plus Darwin notifications to ask a lower-priority holder to step aside. Priorities: share extension = 1, main app = 2, NSE = 3, where lower means more important (OWSChatConnection.swift:880-887). Opening the socket requires taking the lock (`connectChatService` → `acquireConnectionLock`, OWSChatConnection.swift:975-976, 1054-1062); on close the lock is released (1016-1031, 1064-1071).
- When a more important process wants the connection, it locks a signalling byte and posts a Darwin notification; the less important one cycles and closes its socket from the `onInterrupt` callback (ConnectionLock.swift:41-96; the handler is OWSChatConnection.swift:1056-1059, "Cycling the socket because the connection lock was interrupted").
- The NSE notices that it lost the connection through a race between two waits: "wait until processing is done" against "the socket should be closed" (`waitForFetchingProcessingAndSideEffects` plus `waitUntilSocketShouldBeClosedIfCanUseSockets`, BackgroundMessageFetcher.swift:91-116). If the main app took the connection, the second wait throws and the NSE quietly finishes, leaving the work to the app. The current code has no UserDefaults flags of the "main app is running" kind; arbitration rests entirely on file locks and Darwin notifications.
- What this gives for the ratchet: incoming traffic arrives only over one identified socket and exactly one process holds it, so two processes never decrypt in parallel and the ratchet state in the shared database is mutated sequentially.
- There is also `MessagePipelineSupervisor`, a refcounted suppression of the processing pipeline within one process (MessagePipelineSupervisor.swift:31-146). The NSE uses it for an incoming call: it puts the call payload into the database, suspends its own processing for 10 seconds and wakes the app through `CXProvider.reportNewIncomingVoIPPushPayload` so the app can take the call (NSECallMessageHandler.swift:168-204).

Porting to msngr: our SyncEngine actor serialises the ratchet inside a process, but between processes an external arbiter is needed. One fcntl lock on a file in the app group ("who holds the connection and the processing") plus a Darwin notification along the lines of "the app woke up, NSE, let go" is enough. On losing the lock the NSE finishes didReceive with what it managed to do, and only the lock holder touches ratchet state.

## 3. Environment bootstrap in the NSE

How Signal does it:

- The environment is a process-global singleton (`globalEnvironment = NSEEnvironment()`, NotificationService.swift:29-31): the NSE process outlives a single push and may handle several pushes in parallel, so the database, logs and DI graph come up once per process rather than once per didReceive.
- `NSEEnvironment.setUpDatabase` (NSEEnvironment.swift:44-78) runs lazily and once: it opens storage, runs schema and data migrations, and assembles the DI graph through the same `AppSetup` the app uses, but with stand-ins: no battery or sleep managers (nil), a minimal payments helper, a no-op current-call provider, and its own `NSECallMessageHandler`.
- Redone on every push: caches are warmed again so that changes made by the app are picked up (`runLaunchTasksIfNeededAndReloadCaches`, NotificationService.swift:141-142), and registration is rechecked (`setUpLocalIdentifiers`, 143-153).
- `NSEContext` (NSEContext.swift) tells the rest of the code that the process is a background one without UI: `hasUI = false`, `isInBackground = true`, background tasks are stubs, while `canPresentNotifications = true` and `shouldProcessIncomingMessages = true`.
- Not brought up: the UI stack, the calling stack (calls are handed to the app), the storage service sync only runs as "wait until it settles", and periodic jobs are a trimmed `cron.runOnce` (NotificationService.swift:215-234).
- Memory: the code has no explicit budget (the NSE limit is set by the OS, on the order of 24 MB, which is outside knowledge rather than something from the repository). What the code does have: a DispatchSource memory-pressure watcher with logging (NSEContext.swift:49-67), a memoryUsage log line on every push (NSEEnvironment.swift:39), and in internal builds a timer that logs memory once a second (NotificationService.swift:44-55), plus the trimmed pool readers and SQLite cache from section 1.

Porting to msngr: build an NSEEnvironment equivalent as a once-per-process bootstrap (open GRDB, KeyStore, assemble a minimal SyncEngine with no UI dependencies), and on each push only drop and reread caches and recheck whether the user is still signed in. Anything memory-hungry (image caches, previews) should not be created in the NSE at all.

## 4. The push path: didReceive to banner

How Signal does it (their push is an empty wake-up, all content is fetched from the server):

1. `didReceive` puts the work into `SerialTaskQueue.enqueueCancellingPrevious` and stores contentHandler in an atomic (NotificationService.swift:83-94).
2. Prelude: check free disk space, check that the database is available (phone not unlocked means a static banner), check for an outdated app version, and mark the APNS token as alive (NotificationService.swift:100-178).
3. `fetchAndProcessMessages` (NotificationService.swift:208-254) opens the websocket (through the ConnectionLock from section 2), and `MessageProcessor` decrypts envelopes in batches and writes the result to the database (MessageProcessor.swift; in the background the batch is 1).
4. Delivery receipts: yes, they are sent from the NSE. While handling an incoming message `MessageReceiver` puts the receipt into a persistent queue (MessageReceiver.swift:1020, 2270 → ReceiptSender.swift:89-156), sending happens right away over the same connection, and before finishing the NSE explicitly waits on `waitForPendingReceipts`, and also on outgoing sends, sync requests and attachment downloads (BackgroundMessageFetcher.swift:118-143).
5. The banners are not built by the final contentHandler: during processing `NotificationPresenterImpl` posts separate `UNNotificationRequest`s through `UNUserNotificationCenter.add` (UserNotificationsPresenter.swift:106-209), with `threadIdentifier = uniqueId` of the thread so the system groups them per chat (lines 185-186). Posting is serialised by a chain of Tasks and tied to the transaction commit (NotificationPresenterImpl.swift:1773-1790); NSE shutdown waits on `waitForPendingNotifications` (BackgroundMessageFetcher.swift:142, 156-161).
6. Finale: contentHandler receives content carrying only an updated badge (the unread count from the database, NotificationService.swift:246-253). The original push is suppressed, and what stays visible are the banners posted in step 5.
7. Timeout: `serviceExtensionTimeWillExpire` cancels the queue and calls contentHandler with empty content so the system does not show the raw payload (NotificationService.swift:181-193). There is no special "save progress" step: everything is already in the database, and whatever was not processed will be handled by the next push or by the app.

Porting to msngr: didReceive → one-time bootstrap → SyncEngine.pullAndProcess (decrypt, write to GRDB, delivery receipt into a persistent queue with a wait for the send) → one separate UNNotificationRequest per new message with threadIdentifier = chatId → contentHandler with badge-only content; on serviceExtensionTimeWillExpire cancel the task and finish with empty content. Processing must be designed to be idempotent: everything is persisted before the server is acknowledged, so a repeat is safe.

## 5. Suppressing and filtering notifications

How Signal does it:

- The filtering entitlement is there: `com.apple.developer.usernotifications.filtering = true` in SignalNSE-AppStore.entitlements (the dev entitlements, SignalNSE.entitlements, do not have it). It is what lets them finish contentHandler with "empty" content and no visible banner, which is how both the original wake-up push and the "nothing to show" cases are suppressed.
- "Read on another device": the read sync from a linked device arrives in the same batch of envelopes; `OWSReceiptManager.processReadReceiptsFromLinkedDevice` (OWSReceiptManager.swift:558) marks the messages as read and removes already shown banners through `cancelNotifications(messageIds:)` (OWSReceiptManager.swift:842 → NotificationPresenterImpl.swift:1720-1734 → `removeDeliveredNotifications` in UserNotificationsPresenter.swift:356, 458). Because banner posting is serialised after the database write, a message read within the same batch usually never reaches a banner at all.
- False and service pushes: a verification code request is handled and finished with empty content and no fetch (NotificationService.swift:155-167); call messages are not shown by the NSE but handed over to the app (NSECallMessageHandler.swift).

Porting to msngr: request the filtering entitlement from Apple in advance (it goes through a review of the request and is granted to E2EE messengers). In the NSE, after processing a batch, check whether anything from that batch is still unread and remove delivered banners by message id when a read sync from another device arrives. Make the UNNotificationRequest identifier equal to the messageId so removal can be targeted.

## 6. Logging and diagnostics

How Signal does it:

- NSE file logs are written into the app group, into the `<group>/NSELogs` directory (DebugLogger.swift:94-98), so the app can see them and include them in a debug log export together with its own and the share extension's (`allLogsDirPaths`, DebugLogger.swift:104-108). Rotation: up to 3 files, 12 MB per file, by day; the formatter scrubs sensitive data (DebugLogger.swift:134-160). Log files carry `.completeUntilFirstUserAuthentication` protection since they are written before unlock (DebugLogger.swift:139).
- Correlation: each didReceive gets its own `NSELogger` with the prefix `[NSE]` and a UUID suffix (NSELogger.swift:12-17), so parallel pushes in one process can be told apart in the log. Logs are explicitly `flush()`ed at key points (NotificationService.swift:72, 108-112 and others), because killing the process loses the buffer.
- Diagnosing invisible deaths: pid and memoryUsage are logged on every push (NSEEnvironment.swift:39), so a changed pid in the log gives away a restart or a death of the process; the memory-pressure source writes warnings (NSEContext.swift:49-67); the `nseLaunchDidComplete` marker records the version of the last successfully completed NSE run (AppVersion.swift:315-319, called from NSEEnvironment.swift:92), and a mismatch with the current version is visible on the next launch; in internal builds memory is logged once a second (NotificationService.swift:44-55).

Porting to msngr: write the NSE log into a separate app group directory with rotation and an explicit flush after each stage, prefix entries with a per-push UUID, log pid and memory on entry, and add a screen or an export in the main app covering all logs including the NSE's. Plus a "NSE started / NSE finished" marker in shared UserDefaults: an unclosed marker seen on the next launch means a silent death (jetsam or the 30 s limit).

## 7. Ordering and notification avalanches

Same commit `a9f55ea599`, studied 2026-08-15.

### 7.1 What sets the order

Signal uses no system API to influence sorting. A search across the whole tree returns zero occurrences of `relevanceScore`, `interruptionLevel`, `sortingDate`, `filterCriteria`, `targetContentIdentifier`, `summaryArgument`. There is no removal and re-posting for ordering either: `removeDeliveredNotifications` is only called for removal by messageId, threadId or reactionId, for the cleanup when the app becomes active, and for replacing a notification when a message is edited (UserNotificationsPresenter.swift:283-288, 324-372, 442-470).

The order in their notification centre is inherited entirely from the order of posting, and the order of posting is set by three things.

1. One sequential chain. Every post and every removal is wrapped in `enqueueNotificationAction`: a new Task awaits `await oldTask?.value` of the previous one, and the reference to the tail lives in the `mostRecentTask` atomic (NotificationPresenterImpl.swift:1771-1799). Inside the process banners cannot overtake each other, and a removal enqueued after a post is guaranteed to run after it.
2. Binding to the database commit. `enqueueNotificationAction(afterCommitting: tx)` creates a guarantee through `tx.addSyncCompletion` and awaits it before posting (same place, 1776-1786). A banner physically cannot appear before the message is in the database.
3. FIFO with no re-sorting on the way in. `PendingEnvelopes` is a plain array with `append` at the end and `prefix(batchSize)` on the way out (MessageProcessor.swift:664-707). Envelopes are sorted neither by sender timestamp nor by serverDeliveryTimestamp: processing order equals arrival order from the socket. In the background the batch size is forced to 1 (MessageProcessor.swift:205-208).

The arrival order from the socket is set by the server: it keeps a personal queue and hands it out in order, and the client acknowledges each envelope separately (`sendAck` in `chatConnection(_:didReceiveIncomingMessage:...)`, OWSChatConnection.swift:1156-1170). The ack does not go out immediately but from a completion callback invoked via `tx.addSyncCompletion` after the processing transaction commits (MessageProcessor.swift:363). Only what is already persisted gets acknowledged.

The request identifier itself is a random UUID (UserNotificationsPresenter.swift:133); targeting comes not from it but from the `userInfo` fields (threadId, messageId, reactionId) that are matched during removal (same file, 414-450). Grouping in the centre is `threadIdentifier = thread.uniqueId` (NotificationPresenterImpl.swift:888-894), and the system takes care of the per-chat stack from there.

One place where their own ordering guarantee sags: v2 group messages that first need a group state update go into a separate persistent queue, `GroupMessageProcessorManager` (MessageProcessor.swift:472-481, 338-345). Such a message will be processed and shown later than non-group messages that arrived after it. That is a conclusion drawn from the structure of the code, not from a comment by the authors.

### 7.2 What happens during an avalanche

There is no cap on the number of notifications shown. No collapsing into a summary. No dropping of old ones. No per-chat limit. One message produces exactly one notification, however many arrive.

This works because an avalanche of pushes does not become an avalanche of work. Their push is empty, an alarm clock, and N pushes mean N calls of "drain the queue", not N tasks. All `NotificationService` instances in one process share the global `NSEEnvironment`, one `MessageProcessor` and one socket connection; each call simply waits until the pipeline goes quiet (`waitForFetchingProcessingAndSideEffects`, BackgroundMessageFetcher.swift:91-143). A push about an already processed message finds no work and finishes with empty content.

There is no debounce or batching of notifications inside the process. All there is is `fetchQueue.enqueueCancellingPrevious` (NotificationService.swift:90), which cancels the previous task of the same `NotificationService` instance. A process may hold several instances, and the authors say plainly in the file header that `didReceive` can be called in parallel and not necessarily on the same instance (NotificationService.swift:22-27). Cancellation is cheap precisely because the processing itself is shared.

There is no sound throttle during an avalanche. `checkIfShouldPlaySound` returns true immediately if the app is not active (NotificationPresenterImpl.swift:1814-1817); the "2 sounds per 5 seconds" limit (constants on lines 270-271) applies only in the active foreground. From the NSE every notification makes a sound.

The only real damper is a deferred display. If a sync message from a linked device arrived within the last 60 seconds, an incoming message or a reaction is posted not immediately but with a `UNTimeIntervalNotificationTrigger` of 20 seconds (UserNotificationsPresenter.swift:75-77, 140-151; `hasReceivedSyncMessage(inLastSeconds: 60)` at OWSDeviceManager.swift:42). The point: the user is reading the conversation on desktop, the read sync will arrive within those 20 seconds, and the removal takes the notification out of pending before it is ever shown.

### 7.3 Push to message, and "read on another device"

The relation is strictly one to one: for every inserted incoming message `MessageReceiver` calls `notifyUser(forIncomingMessage:)` (MessageReceiver.swift:1747), and that is the single entry point for ordinary messages. Reactions, poll endings and poll votes produce their own separate notifications.

An edit does not create a second notification: before posting the edit, `replaceNotification(messageId:)` is called against the original, and if the original is no longer in the centre, the edit is not shown at all (NotificationPresenterImpl.swift:953-957). The sound is suppressed for an edit.

Read on another device: the read sync arrives in the same stream of envelopes, `markMessageAsReadOnLinkedDevice` marks both the message itself and all earlier unread ones in the chat, and the removal is done as a single batch over the whole list of ids (OWSReceiptManager.swift:807-842). One detail matters: the removal goes through the same `enqueueNotificationAction`, so it joins the shared sequential chain behind the posts already queued. The "removed before it was shown" race cannot happen. While catching up after being offline, banners for already read messages do get a chance to blink and disappear if the 20-second deferral from 7.2 did not kick in.

### 7.4 Gaps

They have no concept of a gap between messages, because there are no sequence numbers. The guarantee is built on the server queue with a per-item ack after commit: anything unacknowledged is handed out again on the next connection. The "catch-up is finished" signal comes explicitly from the server, `chatConnectionDidReceiveQueueEmpty` sets `hasEmptiedInitialQueue` (OWSChatConnection.swift:1172-1195), and it is that flag `waitForFetchingAndProcessing` waits for before the NSE decides to finish (MessageProcessor.swift:37-59).

The only gaps they have are semantic ones, when something arrives about a message not yet received (a receipt, a reaction, an edit, a revision). That is what `EarlyMessageManager` is for: the deferred item is filed under the key "author aci plus timestamp" and applied at the moment the target message is inserted, in the same transaction (EarlyMessageManager.swift:10-17, 340; `applyPendingMessages` is called from MessageReceiver.swift:1728). Early envelopes are stored with a 1024-byte limit (EarlyMessageManager.swift:167, 190). A separate case is a message that failed to decrypt: then an `OWSRecoverableDecryptionPlaceholder` is inserted into the chat and a resend request goes out.

### 7.5 Budget

Memory is limited by the size of the step rather than by a budget: in the background a transaction processes one envelope, and envelopes larger than 256 KB are dropped on the way in (MessageProcessor.swift:128-132, 149); the GRDB pool in the extension has fewer readers and a smaller cache (see section 1).

On time, the NSE does not count seconds and does not try to fit into them. It just waits for the whole list to be ready: the processing pipeline, receipt sending, outgoing sends, sync requests, storage service, attachment downloads, and at the very end `NotificationPresenterImpl.waitForPendingNotifications` (BackgroundMessageFetcher.swift:118-143). The same waiter is repeated in `stopAndWaitBeforeSuspending` after the socket is released (same file, 151-162), so no queued banner is lost at suspension.

On `serviceExtensionTimeWillExpire` they cancel the queue and call contentHandler with an empty `UNMutableNotificationContent` (NotificationService.swift:182-193). No summary is shown, no "how much is left" is reported, no progress is saved anywhere: everything processed is already in the database, and everything unprocessed was never acknowledged to the server and will come again. A normal finish differs only in that the content carries a recomputed badge (NotificationService.swift:246-253).

### 7.6 What of this is worth taking

"One message equals one notification" holds literally in Signal, and it holds without a single avalanche-limiting mechanism. So our problem reduces to ordering.

An assessment of our draft plan (record the highest shown seq per chat, and on a late push remove and re-post the tail of roughly the last 20 in seq order). The rakes that become visible against their solution:

- Re-posting is a repeated alert. To the system, `UNUserNotificationCenter.add` with a new identifier is always a new delivery: sound, vibration, the banner sliding in, the screen lighting up. Re-posting 20 notifications for the sake of order means poking the user 20 times with something already seen. Signal does remove-plus-add in exactly one place and for exactly one notification (a message edit), and with the sound explicitly turned off.
- The problem is solved one step earlier. If display order is determined by a single sequential posting chain bound to the commit of the database write, and write order is FIFO from one ordered stream, then the "late push" stops being a case at all: it arrives, finds nothing new and shows nothing. Re-posting is only needed where the display is bound to the push itself.
- Re-posting competes with removal. If a "read on another device" mark arrives during the pass, we can resurrect banners that were just correctly removed. In Signal this is impossible only because posts and removals share one queue. If we introduce re-posting, it has to run in that same chain and recheck unread state at the moment of posting.
- The "highest shown seq" mark per chat has to be written in the same transaction as the message insert. Otherwise two parallel `didReceive` calls in one process (their file header, NotificationService.swift:22-27, describes exactly that parallelism) will both decide they are the newest and both run the re-posting pass.
- A tail of 20 per chat, across several chats, gives a hundred deliveries per pass. The system keeps a limited number of delivered notifications per app and evicts older ones; Apple does not document the exact number, and Signal's repository has no accounting for that limit anywhere. This is an outside consideration, not a fact confirmed by them, but the risk of evicting other apps' notifications and our own is real.
- Grouping by `threadIdentifier` means the user sees a stack per chat, so the order within a chat is what is actually perceived. Cross-chat order is barely observable. That narrows the area where re-posting improves anything to one case: a chat whose messages really did arrive out of order.

What to take instead:

- One sequential chain for posting and removal, each link awaiting the commit of its own transaction. That is the only thing that produces correct order, and it also makes removal after display reliable.
- FIFO with no re-sorting, acknowledgement to the server only after commit, and an explicit "queue drained" signal as the condition for the NSE to finish.
- Request identifier equal to messageId (better for us than their UUID plus matching on userInfo), `threadIdentifier` equal to chatId.
- A store for "arrived before its target" items covering reactions, edits and receipts about a message not yet received, applied in the transaction that inserts the target message.
- If we ever get multi-device: defer the display by about 20 seconds while another device is active. A cheap way to avoid flashing banners during catch-up.
- On timeout, show nothing and save nothing: the state is in the database, and anything unacknowledged will come again.

If our transport can after all show content straight from the push and push delivery order is not guaranteed, then a coalescing window is cheaper than re-posting: on the first push wait a bounded time and drain the stream up to a point with no gaps, then post everything at once in seq order as one chain. One posting pass, no removals.
