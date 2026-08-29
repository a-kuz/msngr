import Foundation
import GRDB
import MsngrCrypto

/// Rows of `chatFolder`/`chatFolderChat`/`chatFolderPeer`, exactly as the
/// tables store them. `ChatFolders.swift` reads and writes the richer domain
/// model (`ChatFolder`, `ChatFolderRules`); a backup only ever moves the raw
/// rows between one database and another, so it does not need that model.
public struct BackupFolderRow: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatFolder"
    public var id: String
    public var title: String
    public var position: Int
    public var ruleDirect: Bool
    public var ruleGroups: Bool
    public var ruleUnread: Bool
    public var updatedAt: Double
}

public struct BackupFolderChatRow: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatFolderChat"
    public var folderId: String
    public var chatId: String
    public var mode: String
}

public struct BackupFolderPeerRow: Codable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "chatFolderPeer"
    public var folderId: String
    public var userId: String
}

/// One attachment's plaintext, addressed by the mediaId a message row already
/// names. Thumbnails travel as their own blob under `thumbMediaId`.
public struct BackupMediaBlob: Codable, Sendable {
    public var mediaId: String
    public var mime: String?
    public var data: Data
}

/// Everything a backup carries, once decrypted. What it does NOT carry:
/// `ratchetSession`, `senderKeyIn`/`senderKeyOut`, `trustedIdentity`, and every
/// row that exists only to bookkeep them (`pendingDecrypt`, `pendingApply`,
/// `historyGap`, `outbox`, `sentServiceFrame`). Restoring session state onto a
/// second device would reuse a sending-chain position the original device
/// already spent; a restored device starts every session fresh, exactly as a
/// linked device does (`DeviceLink.claim`).
public struct BackupPayload: Codable, Sendable {
    public var v: Int = 1
    public var userId: String
    public var username: String
    public var displayName: String
    /// Raw private keys, base64url — the account's identity, not the device's.
    public var identityDH: String
    public var identitySigning: String
    public var createdAt: Double

    public var users: [User]
    public var chats: [Chat]
    public var members: [ChatMemberRow]
    public var messages: [Message]
    public var folders: [BackupFolderRow]
    public var folderChats: [BackupFolderChatRow]
    public var folderPeers: [BackupFolderPeerRow]

    /// Device-local settings that are not in any table:
    /// `ThemeStore`'s palette and `NotificationPreferences.showsMessageText`.
    /// Opaque strings here — MsngrCore does not know the app's `Palette` enum.
    public var palette: String?
    public var showsMessageText: Bool?

    public var media: [BackupMediaBlob]

    public init(userId: String, username: String, displayName: String,
                identityDH: String, identitySigning: String, createdAt: Double,
                users: [User], chats: [Chat], members: [ChatMemberRow], messages: [Message],
                folders: [BackupFolderRow], folderChats: [BackupFolderChatRow],
                folderPeers: [BackupFolderPeerRow], palette: String?, showsMessageText: Bool?,
                media: [BackupMediaBlob]) {
        self.userId = userId
        self.username = username
        self.displayName = displayName
        self.identityDH = identityDH
        self.identitySigning = identitySigning
        self.createdAt = createdAt
        self.users = users
        self.chats = chats
        self.members = members
        self.messages = messages
        self.folders = folders
        self.folderChats = folderChats
        self.folderPeers = folderPeers
        self.palette = palette
        self.showsMessageText = showsMessageText
        self.media = media
    }
}

/// Building and applying the plaintext side of a backup. `BackupSeal` handles
/// the encryption; this handles what goes in and out of the database and the
/// media cache.
public enum AccountBackup {
    /// Reads everything a backup carries out of the local database, and
    /// fetches (or downloads) the plaintext of every attachment referenced by
    /// a message so the backup does not depend on what still happens to be in
    /// the media cache.
    public static func buildPayload(db: DatabaseReader, media: MediaManager,
                                    userId: String, username: String, displayName: String,
                                    identityDH: String, identitySigning: String,
                                    palette: String?, showsMessageText: Bool?) async throws -> BackupPayload {
        let (users, chats, members, messages, folders, folderChats, folderPeers) =
            try await db.read { dbc in
                (try User.fetchAll(dbc), try Chat.fetchAll(dbc), try ChatMemberRow.fetchAll(dbc),
                 try Message.fetchAll(dbc), try BackupFolderRow.fetchAll(dbc),
                 try BackupFolderChatRow.fetchAll(dbc), try BackupFolderPeerRow.fetchAll(dbc))
            }

        var blobs: [BackupMediaBlob] = []
        var seen = Set<String>()
        func include(_ info: MediaInfo?) async {
            guard let info, !info.mediaId.isEmpty, !seen.contains(info.mediaId) else { return }
            seen.insert(info.mediaId)
            if let url = try? await media.fetch(info), let data = try? Data(contentsOf: url) {
                blobs.append(BackupMediaBlob(mediaId: info.mediaId, mime: info.mime, data: data))
            }
            if let thumbId = info.thumbMediaId, !seen.contains(thumbId) {
                seen.insert(thumbId)
                if let url = try? await media.fetchThumb(info), let data = try? Data(contentsOf: url) {
                    blobs.append(BackupMediaBlob(mediaId: thumbId, mime: "image/jpeg", data: data))
                }
            }
        }
        for message in messages {
            await include(message.media)
            for item in message.album ?? [] { await include(item) }
        }

        return BackupPayload(userId: userId, username: username, displayName: displayName,
                             identityDH: identityDH, identitySigning: identitySigning,
                             createdAt: Date().timeIntervalSince1970,
                             users: users, chats: chats, members: members, messages: messages,
                             folders: folders, folderChats: folderChats, folderPeers: folderPeers,
                             palette: palette, showsMessageText: showsMessageText, media: blobs)
    }

    /// Writes a decrypted payload into freshly opened storage: the rows first,
    /// then the media cache. Called after `StorageOwnership.openOwned` has
    /// cleared whatever the container held before and before the identity
    /// keys are adopted into the same database.
    public static func apply(_ payload: BackupPayload, db: DatabaseWriter, media: MediaManager) async throws {
        try await db.write { dbc in
            for user in payload.users { try user.insert(dbc, onConflict: .replace) }
            for chat in payload.chats { try chat.insert(dbc, onConflict: .replace) }
            for member in payload.members { try member.insert(dbc, onConflict: .replace) }
            for message in payload.messages { try message.insert(dbc, onConflict: .replace) }
            for folder in payload.folders { try folder.insert(dbc, onConflict: .replace) }
            for folderChat in payload.folderChats { try folderChat.insert(dbc, onConflict: .replace) }
            for folderPeer in payload.folderPeers { try folderPeer.insert(dbc, onConflict: .replace) }
        }
        for blob in payload.media {
            try? media.seedCache(mediaId: blob.mediaId, mime: blob.mime, data: blob.data)
        }
    }
}
