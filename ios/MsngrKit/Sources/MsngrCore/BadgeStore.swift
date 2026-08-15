import Foundation
import GRDB

/// The number on the app icon.
///
/// The count itself is the server's: it is the only party that knows how many
/// messages the user has not read, whatever the app was doing at the time. The
/// device therefore never computes a badge to grow it — it carries the number
/// the push brought and reports the number the user's own reading produced.
///
/// Two processes write here, the app and the notification extension, and both
/// may be inside a burst at once. `stamp` is what orders them: the server
/// numbers every count it hands out, and a push that arrives after a newer one
/// is dropped instead of putting an older total back on the icon.
public enum BadgeStore {
    /// The number the icon carries now.
    public static func current(_ dbc: GRDB.Database) throws -> Int {
        try Int.fetchOne(dbc, sql: "SELECT value FROM badge WHERE id = 0") ?? 0
    }

    /// Applies a count the server sent with a push.
    ///
    /// - Returns: the number the icon should carry — the count when it is the
    ///   newest one seen, and the stored number when the push was overtaken.
    @discardableResult
    public static func applyFromPush(_ dbc: GRDB.Database, value: Int, stamp: Int) throws -> Int {
        // one statement, so two handlers in the same burst cannot both read the
        // old stamp and both decide they are the newer one
        try dbc.execute(sql: """
            INSERT INTO badge (id, value, stamp) VALUES (0, ?, ?)
            ON CONFLICT(id) DO UPDATE SET value = excluded.value, stamp = excluded.stamp
            WHERE excluded.stamp > badge.stamp
            """, arguments: [max(0, value), stamp])
        return try current(dbc)
    }

    /// Applies the count the app itself reached: the user read a chat, or the
    /// session ended. The stamp stays where it is — this is the same number
    /// from the same source, arrived at locally rather than over a push.
    @discardableResult
    public static func applyLocal(_ dbc: GRDB.Database, value: Int) throws -> Int {
        try dbc.execute(sql: """
            INSERT INTO badge (id, value, stamp) VALUES (0, ?, 0)
            ON CONFLICT(id) DO UPDATE SET value = excluded.value
            """, arguments: [max(0, value)])
        return try current(dbc)
    }

    /// Unread total over the chats this device stores: a chat waiting to be
    /// accepted does not tell how much was written into it.
    public static func localUnread(_ dbc: GRDB.Database) throws -> Int {
        try Row.fetchAll(dbc, sql: "SELECT unreadCount, isRequest, iAccepted FROM chat")
            .reduce(0) { sum, row in
                sum + ChatPrivacy.visibleUnread(isRequest: row["isRequest"],
                                                iAccepted: row["iAccepted"],
                                                unreadCount: row["unreadCount"])
            }
    }

    /// The count a push carries, taken from the payload the extension received.
    /// Both fields have to be there: a number without its place in the sequence
    /// cannot be ordered against the one already on the icon.
    public static func pushedBadge(from userInfo: [AnyHashable: Any],
                                   badge: Int?) -> (value: Int, stamp: Int)? {
        guard let badge, let stamp = userInfo["badgeStamp"] as? Int else { return nil }
        return (badge, stamp)
    }
}
