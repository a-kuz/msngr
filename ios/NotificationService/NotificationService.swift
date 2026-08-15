import UserNotifications
import GRDB
import MsngrCore

/// One gate for the whole process. `didReceive` may be entered several times at
/// once and not necessarily on the same instance, so the handlers of one burst
/// meet here: the gate holds them for the length of its window, orders the
/// batch by seq and answers them one by one.
private let burstGate = NotificationBurstGate(resolve: { await burstPlan($0) })

/// The database of the app group, opened once: a burst enters the extension
/// many times. The app owns the location, so the extension only reads the
/// container it prepared.
private let sharedDatabase: DatabaseQueue? = {
    guard let url = AppContainer.groupLocation()?.databaseURL,
          FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try? AppDatabase.open(at: url)
}()

/// An empty plan leaves every push with the content it arrived with: a neutral
/// banner is the right answer when the database cannot be consulted.
private func burstPlan(_ items: [BurstItem]) async -> BurstPlan {
    guard let db = sharedDatabase else { return BurstPlan() }
    let showsText = NotificationPreferences.showsMessageText(in: AppGroup.defaults)
    return (try? NotificationBurstStore.resolve(db: db, items: items,
                                                showsMessageText: showsText)) ?? BurstPlan()
}

/// The push text comes from the message already decrypted by the app and stored
/// in the shared database; keys are not needed to read it.
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)
            ?? UNMutableNotificationContent()
        bestAttempt = content

        guard let item = Self.item(from: request.content.userInfo) else {
            contentHandler(content)
            return
        }
        let answer = PushAnswer(content: content, handler: contentHandler)
        Task {
            await burstGate.submit(item) { answer.answer($0) }
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // out of time: close the window, and answer with what this handler has
        // — a push left unanswered is delivered by the system as it arrived
        Task { await burstGate.flushNow() }
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
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
            if let built = step.content {
                content.title = built.title
                content.subtitle = built.subtitle ?? ""
                content.body = built.body
                content.threadIdentifier = built.threadIdentifier
            }
            if let badge = step.badge { content.badge = NSNumber(value: badge) }
            handler(content)
        case .skip:
            // content without an alert is not presented: this message already
            // has its banner, or is not to be announced at all
            handler(UNMutableNotificationContent())
        }
    }
}

enum AppGroup {
    static let identifier = AppContainer.appGroupIdentifier
    static let keychainGroup = "ai.enface.msngr.shared"
    static let defaults = UserDefaults(suiteName: identifier) ?? .standard
}
