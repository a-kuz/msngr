import Foundation
import GRDB

/// Chat folders: the tabs above the chat list.
///
/// A folder is a set of rules plus the chats the user put in or took out by
/// hand. The rules describe a kind of chat (people, groups, unread, a chat with
/// a given contact); the hand-picked rows override them for one chat. A chat
/// belongs to as many folders as match it, and a folder holds no copy of the
/// chat — deleting the folder drops its own rows only.
///
/// Folders live on the device that made them. There is no multi-device sync in
/// the product yet, so nothing here is sent to the server and no frame carries
/// it. The rows are already shaped for the sync that will come: the folder id is
/// a stable string rather than a rowid, order is an explicit `position`, and
/// every row carries `updatedAt` for a later last-writer-wins merge.
public struct ChatFolder: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var position: Int
    public var rules: ChatFolderRules
    public var updatedAt: Double

    public init(id: String, title: String, position: Int,
                rules: ChatFolderRules, updatedAt: Double) {
        self.id = id
        self.title = title
        self.position = position
        self.rules = rules
        self.updatedAt = updatedAt
    }
}

/// What a folder takes in on its own. Rules are additive: a chat matching any
/// enabled rule is in.
public struct ChatFolderRules: Equatable, Sendable {
    /// One-to-one chats.
    public var direct: Bool
    /// Group chats.
    public var groups: Bool
    /// Chats with something unread right now.
    public var unread: Bool
    /// Chats with these contacts.
    public var peerIds: Set<String>

    public init(direct: Bool = false, groups: Bool = false,
                unread: Bool = false, peerIds: Set<String> = []) {
        self.direct = direct
        self.groups = groups
        self.unread = unread
        self.peerIds = peerIds
    }

    /// A folder with no rules holds only what was added by hand.
    public var isEmpty: Bool { !direct && !groups && !unread && peerIds.isEmpty }
}

/// A chat the user placed by hand, against what the rules say.
public enum ChatFolderPin: String, Sendable {
    case included
    case excluded
}

/// The chat properties a rule looks at.
public struct ChatFolderCandidate: Sendable {
    public var chatId: String
    public var isGroup: Bool
    public var hasUnread: Bool
    /// Peer of a one-to-one chat.
    public var peerId: String?

    public init(chatId: String, isGroup: Bool, hasUnread: Bool, peerId: String?) {
        self.chatId = chatId
        self.isGroup = isGroup
        self.hasUnread = hasUnread
        self.peerId = peerId
    }
}

public enum ChatFolderMembership {
    /// Whether a chat shows in a folder. A hand-picked row decides on its own:
    /// taking a chat out is the only way to drop it from a rule that keeps
    /// matching, and putting one in is the only way to hold a chat no rule
    /// describes.
    public static func matches(_ chat: ChatFolderCandidate,
                               rules: ChatFolderRules,
                               pin: ChatFolderPin?) -> Bool {
        switch pin {
        case .excluded: return false
        case .included: return true
        case nil: break
        }
        if rules.direct && !chat.isGroup { return true }
        if rules.groups && chat.isGroup { return true }
        if rules.unread && chat.hasUnread { return true }
        if let peerId = chat.peerId, rules.peerIds.contains(peerId) { return true }
        return false
    }
}

public enum ChatFolderStore {
    // MARK: - Reading

    public static func all(_ db: Database) throws -> [ChatFolder] {
        let peers = try peerRules(db)
        return try Row.fetchAll(db, sql: """
            SELECT * FROM chatFolder ORDER BY position, title
            """).map { row in
            let id: String = row["id"]
            return ChatFolder(
                id: id,
                title: row["title"],
                position: row["position"],
                rules: ChatFolderRules(direct: row["ruleDirect"],
                                       groups: row["ruleGroups"],
                                       unread: row["ruleUnread"],
                                       peerIds: peers[id] ?? []),
                updatedAt: row["updatedAt"])
        }
    }

    /// Hand-picked rows, folder id → chat id → placement.
    public static func pins(_ db: Database) throws -> [String: [String: ChatFolderPin]] {
        var out: [String: [String: ChatFolderPin]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT folderId, chatId, mode FROM chatFolderChat") {
            let folderId: String = row["folderId"]
            guard let mode = ChatFolderPin(rawValue: row["mode"]) else { continue }
            out[folderId, default: [:]][row["chatId"]] = mode
        }
        return out
    }

    private static func peerRules(_ db: Database) throws -> [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT folderId, userId FROM chatFolderPeer") {
            out[row["folderId"], default: []].insert(row["userId"])
        }
        return out
    }

    // MARK: - Writing

    @discardableResult
    public static func create(_ db: Database, title: String,
                              rules: ChatFolderRules = ChatFolderRules(),
                              id: String = UUID().uuidString,
                              now: Double = Date().timeIntervalSince1970) throws -> ChatFolder {
        let position = (try Int.fetchOne(db, sql: "SELECT MAX(position) FROM chatFolder") ?? -1) + 1
        let folder = ChatFolder(id: id, title: title, position: position,
                                rules: rules, updatedAt: now)
        try db.execute(sql: """
            INSERT INTO chatFolder (id, title, position, ruleDirect, ruleGroups, ruleUnread, updatedAt)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """, arguments: [folder.id, folder.title, folder.position,
                             rules.direct, rules.groups, rules.unread, now])
        try writePeerRules(db, folderId: folder.id, peerIds: rules.peerIds)
        return folder
    }

    public static func rename(_ db: Database, folderId: String, title: String,
                              now: Double = Date().timeIntervalSince1970) throws {
        try db.execute(sql: "UPDATE chatFolder SET title = ?, updatedAt = ? WHERE id = ?",
                       arguments: [title, now, folderId])
    }

    public static func setRules(_ db: Database, folderId: String, rules: ChatFolderRules,
                                now: Double = Date().timeIntervalSince1970) throws {
        try db.execute(sql: """
            UPDATE chatFolder SET ruleDirect = ?, ruleGroups = ?, ruleUnread = ?, updatedAt = ?
            WHERE id = ?
            """, arguments: [rules.direct, rules.groups, rules.unread, now, folderId])
        try writePeerRules(db, folderId: folderId, peerIds: rules.peerIds)
    }

    /// Deletes the folder and its own rows. The chats it showed are not touched:
    /// a folder is a view over the chat list, never a place a chat is kept.
    public static func delete(_ db: Database, folderId: String) throws {
        try db.execute(sql: "DELETE FROM chatFolder WHERE id = ?", arguments: [folderId])
        try db.execute(sql: "DELETE FROM chatFolderChat WHERE folderId = ?", arguments: [folderId])
        try db.execute(sql: "DELETE FROM chatFolderPeer WHERE folderId = ?", arguments: [folderId])
    }

    /// Writes the tab order given as the full list of folder ids.
    public static func reorder(_ db: Database, orderedIds: [String],
                               now: Double = Date().timeIntervalSince1970) throws {
        for (index, id) in orderedIds.enumerated() {
            try db.execute(sql: "UPDATE chatFolder SET position = ?, updatedAt = ? WHERE id = ?",
                           arguments: [index, now, id])
        }
    }

    /// Puts a chat in or takes it out by hand; `nil` hands the chat back to the
    /// rules.
    public static func setPin(_ db: Database, folderId: String, chatId: String,
                              pin: ChatFolderPin?) throws {
        guard let pin else {
            try db.execute(sql: "DELETE FROM chatFolderChat WHERE folderId = ? AND chatId = ?",
                           arguments: [folderId, chatId])
            return
        }
        try db.execute(sql: """
            INSERT INTO chatFolderChat (folderId, chatId, mode) VALUES (?, ?, ?)
            ON CONFLICT(folderId, chatId) DO UPDATE SET mode = excluded.mode
            """, arguments: [folderId, chatId, pin.rawValue])
    }

    private static func writePeerRules(_ db: Database, folderId: String, peerIds: Set<String>) throws {
        try db.execute(sql: "DELETE FROM chatFolderPeer WHERE folderId = ?", arguments: [folderId])
        for userId in peerIds {
            try db.execute(sql: "INSERT INTO chatFolderPeer (folderId, userId) VALUES (?, ?)",
                           arguments: [folderId, userId])
        }
    }
}
