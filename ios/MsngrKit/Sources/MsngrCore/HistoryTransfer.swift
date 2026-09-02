import Foundation
import GRDB
import MsngrCrypto

/// The history moving to a device being linked.
///
/// The approving device packs the same payload a backup carries — the chats,
/// the messages, the media, the folders — encrypts it the way an attachment is
/// encrypted and uploads it as one; the key rides only inside the sealed
/// provisioning bundle, so the server holds bytes it cannot open. The new
/// device downloads the blob after its claim and writes the rows before its
/// first sync, which then names the end of each journal instead of asking for
/// all of it. Ratchet state stays behind, as with a backup: the new device's
/// sessions start fresh.
public enum HistoryTransfer {
    /// The blob is one attachment to the media store; the mime is what the
    /// cache files it under.
    public static let mime = "application/x-msngr-history"

    /// Packs the account's history and uploads it. Nil when there is nothing to
    /// carry or the upload did not go through: the link goes ahead without the
    /// past rather than not at all.
    public static func pack(db: DatabaseReader, media: MediaManager,
                            userId: String, username: String, displayName: String,
                            identity: IdentityKeyPair,
                            palette: String?, showsMessageText: Bool?,
                            progress: (@Sendable (Double) -> Void)? = nil) async -> Provisioning.Bundle.History? {
        guard let payload = try? await AccountBackup.buildPayload(
            db: db, media: media, userId: userId, username: username, displayName: displayName,
            identityDH: identity.dh.rawRepresentation.base64urlEncodedString(),
            identitySigning: identity.signing.rawRepresentation.base64urlEncodedString(),
            palette: palette, showsMessageText: showsMessageText),
              !payload.messages.isEmpty,
              let data = try? JSONEncoder().encode(payload),
              let uploaded = try? await media.upload(data, mime: mime, progress: progress)
        else { return nil }
        return Provisioning.Bundle.History(mediaId: uploaded.mediaId, key: uploaded.key,
                                           hash: uploaded.hash, size: uploaded.size)
    }

    /// The media store's description of the blob, as `MediaManager.fetch` reads it.
    public static func mediaInfo(_ history: Provisioning.Bundle.History) -> MediaInfo {
        MediaInfo(type: "file", mediaId: history.mediaId, key: history.key, hash: history.hash,
                  size: history.size, mime: mime)
    }

    /// Downloads and decodes the history the bundle points at.
    public static func unpack(_ history: Provisioning.Bundle.History,
                              media: MediaManager) async throws -> BackupPayload {
        let url = try await media.fetch(mediaInfo(history))
        let payload = try JSONDecoder().decode(BackupPayload.self, from: Data(contentsOf: url))
        // the blob is not an attachment of any message: once read it is not
        // worth its place in the cache
        media.remove(mediaInfo(history))
        return payload
    }
}
