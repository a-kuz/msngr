import Foundation

/// Pure "show a notification or not" logic. With the app active the same
/// message lands twice: the WS frame, and the system push some 150-500 ms
/// later. Deduplication between the two lives here.
enum NotificationDecision {
    /// What to do about a content message received over WS.
    enum WSAction: Equatable {
        case none
        /// top in-app banner; app active and the chat not open
        case inAppBanner
        /// system banner the app posts itself
        case localNotification
    }

    /// A message arrived over WS.
    /// In the background the system APNs push shows the banner and a local
    /// notification would duplicate it. When no push can arrive (simulator, a
    /// device with no registered token) and WS is still alive, the app posts
    /// the banner itself.
    static func forIncomingWS(appActive: Bool, chatOpen: Bool, isOwn: Bool,
                              isService: Bool, muted: Bool, alreadyShown: Bool,
                              apnsAvailable: Bool = true) -> WSAction {
        if isOwn || isService || muted || alreadyShown { return .none }
        guard appActive else { return apnsAvailable ? .none : .localNotification }
        return chatOpen ? .none : .inAppBanner
    }

    /// Whether to present a notification the system asked the delegate about (willPresent).
    /// - isLocal: the app posted this notification itself from a WS frame. It
    ///   passed every check when it was posted and its key is in alreadyShown,
    ///   so the common dedup would suppress the app's own banner.
    /// - messageInDB: the message already arrived over WS (a row in the DB), the banner would be a duplicate
    /// - alreadyShown: an in-app banner or a system push has already been shown for this (chatId, seq)
    /// - messageRead: the message is already read (seq <= myReadUpTo)
    static func shouldPresentSystemPush(isLocal: Bool = false,
                                        chatOpen: Bool, alreadyShown: Bool,
                                        messageInDB: Bool, messageRead: Bool,
                                        muted: Bool) -> Bool {
        if isLocal { return true }
        return !(chatOpen || alreadyShown || messageInDB || messageRead || muted)
    }
}
