import UserNotifications
import GRDB
import MsngrCore

/// One gate for the whole process. `didReceive` may be entered several times at
/// once and not necessarily on the same instance, so the handlers of one burst
/// meet here: the gate holds them for the length of its window, orders the
/// batch by seq and answers them one by one.
private let burstGate = NotificationBurstGate(resolve: { await burstPlan($0) })

/// The envelopes of the pushes this process has seen, by msgId. A handler puts
/// its envelope here and the window resolves them all in one transaction.
private let envelopes = PushEnvelopeBox()

private final class PushEnvelopeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var byMsgId: [String: PushEnvelope] = [:]

    func put(_ envelope: PushEnvelope, msgId: String) {
        lock.lock()
        defer { lock.unlock() }
        byMsgId[msgId] = envelope
    }

    func take(_ msgIds: [String]) -> [String: PushEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        var out: [String: PushEnvelope] = [:]
        for id in msgIds {
            if let e = byMsgId.removeValue(forKey: id) { out[id] = e }
        }
        return out
    }
}

/// The database of the app group, opened once: a burst enters the extension
/// many times. The app owns the location, so the extension only reads the
/// container it prepared.
/// Trace of what the system actually let this extension do.
private let journal = NotificationJournal.shared()

private let sharedLocation: StorageLocation? = AppContainer.groupLocation()

private let sharedDatabase: DatabaseQueue? = {
    guard let url = sharedLocation?.databaseURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? AppDatabase.open(at: url)
}()

/// Keys of this device, and who this device is. Without them a push is still
/// answered — with the neutral text it arrived with.
private let decryption: (decryptor: IncomingDecryptor, store: IdentityStore, ownUserId: String)? = {
    struct StoredSession: Decodable { let userId: String; let deviceId: String }
    guard let location = sharedLocation, let db = sharedDatabase,
          let data = try? Data(contentsOf: location.sessionURL),
          let session = try? JSONDecoder().decode(StoredSession.self, from: data),
          let store = try? IdentityStore(db: db,
                                         masterKeyProvider: SharedFileMasterKey(location: location))
    else { return nil }
    let decryptor = IncomingDecryptor(store: store, ownUserId: session.userId,
                                      ownDeviceId: session.deviceId,
                                      gate: CryptoGate.shared(location: location))
    return (decryptor, store, session.userId)
}()

/// An empty plan leaves every push with the content it arrived with: a neutral
/// banner is the right answer when the database cannot be consulted.
///
/// The crypto gate is taken around the whole window and released when its
/// transaction commits: the app steps the same ratchet from its own process,
/// and only one of them may be inside a step at a time (see `CryptoGate`).
private func burstPlan(_ items: [BurstItem]) async -> BurstPlan {
    guard let db = sharedDatabase else { return BurstPlan() }
    let showsText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
    let carried = envelopes.take(items.map(\.msgId))
    guard let decryption, !carried.isEmpty else {
        return (try? NotificationBurstStore.resolve(db: db, items: items,
                                                    showsMessageText: showsText,
                                                    journal: journal)) ?? BurstPlan()
    }
    let gate = CryptoGate.shared(location: sharedLocation!)
    let plan = try? gate.withLock { ticket -> BurstPlan in
        let writer = PushMessageWriter(decryptor: decryption.decryptor, store: decryption.store,
                                       ownUserId: decryption.ownUserId, holding: ticket)
        return try NotificationBurstStore.resolve(db: db, items: items,
                                                  showsMessageText: showsText,
                                                  envelopes: carried, writer: writer,
                                                  journal: journal)
    }
    if plan == nil {
        journal?.record(.stored, msgId: "", seq: 0, detail: "gate-busy")
    }
    return plan ?? (try? NotificationBurstStore.resolve(db: db, items: items,
                                                        showsMessageText: showsText,
                                                        journal: journal)) ?? BurstPlan()
}

/// The banner says what the message says: the push carries the message itself,
/// the extension decrypts it and writes it down, and the text is then read from
/// the row it just wrote. A push whose envelope did not fit, or a message this
/// device already has, is read from the database as it stands.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?
    private var pushedItem: BurstItem?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        bestAttempt = content
        applyBadge(to: content)

        guard let item = Self.item(from: request.content.userInfo) else {
            journal?.record(.received, msgId: "", seq: 0, detail: "no-item")
            contentHandler(content)
            return
        }
        pushedItem = item
        let envelope = PushEnvelope.fromPush(request.content.userInfo)
        if let envelope { envelopes.put(envelope, msgId: item.msgId) }
        journal?.record(.received, msgId: item.msgId, seq: item.seq,
                        detail: envelope == nil ? "no-envelope" : "envelope")
        let answer = PushAnswer(content: content, handler: contentHandler)
        Task {
            await burstGate.submit(item) { answer.answer($0) }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        journal?.record(.expired, msgId: pushedItem?.msgId ?? "", seq: pushedItem?.seq ?? 0)
        // out of time: close the window, and answer with what this handler has
        // — a push left unanswered is delivered by the system as it arrived
        Task { await burstGate.flushNow() }
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }

    /// The unread total on the icon is the server's count, carried by the push.
    /// The extension only orders the counts: the handlers of a burst run at
    /// once and answer in no fixed order, so the number that arrives after a
    /// newer one is dropped rather than put back on the icon.
    ///
    /// Without the database there is nothing to order against, and the count
    /// the push arrived with stays — the system applies it either way.
    private func applyBadge(to content: UNMutableNotificationContent) {
        guard let db = sharedDatabase,
              let pushed = BadgeStore.pushedBadge(from: content.userInfo,
                                                  badge: content.badge?.intValue) else { return }
        guard let resolved = try? db.write({ dbc in
            try BadgeStore.applyFromPush(dbc, value: pushed.value, stamp: pushed.stamp)
        }) else { return }
        content.badge = NSNumber(value: resolved)
    }

    /// The push carries the address of the message and its place in the chat.
    static func item(from userInfo: [AnyHashable: Any]) -> BurstItem? {
        guard let chatId = userInfo["chatId"] as? String,
              let msgId = userInfo["msgId"] as? String,
              let seq = userInfo["seq"] as? Int else { return nil }
        return BurstItem(chatId: chatId, msgId: msgId, seq: seq,
                         sentAt: userInfo["sentAt"] as? Double ?? 0)
    }
}

/// The answer to one push. The gate calls it once, from its own chain, which is
/// what keeps the notification content and the handler to a single thread.
private final class PushAnswer: @unchecked Sendable {
    private let content: UNMutableNotificationContent
    private let handler: (UNNotificationContent) -> Void

    init(content: UNMutableNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.content = content
        self.handler = handler
    }

    func answer(_ step: BurstStep) {
        switch step.outcome {
        case .show:
            journal?.record(.answered, msgId: step.item.msgId, seq: step.item.seq, detail: "show")
            if let built = step.content {
                content.title = built.title
                content.subtitle = built.subtitle ?? ""
                content.body = built.body
                content.threadIdentifier = built.threadIdentifier
            }
            handler(content)
        case .skip(let reason):
            journal?.record(.answered, msgId: step.item.msgId, seq: step.item.seq,
                            detail: "skip:" + reason.rawValue)
            // content without an alert is not presented: this message already
            // has its banner, or is not to be announced at all. The badge still
            // travels with it — the count is about the mailbox, not about this
            // one banner.
            let silent = UNMutableNotificationContent()
            silent.badge = content.badge
            handler(silent)
        }
    }
}

enum AppGroup {
    static let identifier = AppContainer.appGroupIdentifier
    static let keychainGroup = "ai.enface.msngr.shared"
    static let defaults = UserDefaults(suiteName: identifier) ?? .standard
}
