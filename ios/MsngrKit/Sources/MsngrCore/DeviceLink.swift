import Foundation
import GRDB
import MsngrCrypto

/// Signing in on a device the owner authorised from one already on the account.
///
/// The two halves never talk directly. The device being linked opens a session
/// and shows a code; the device that approves seals the account's identity keys
/// to the session's ephemeral key and hands the result to the server, which
/// carries it without being able to read it. Design and threat model:
/// `docs/research/2026-08-16-second-device.md`.
public enum DeviceLink {
    /// What the device being linked holds while it waits.
    public struct Pending: Sendable {
        public let provisionId: String
        public let provisionToken: String
        public let code: String
        public let expiresIn: Double
        public let ephemeral: Provisioning.EphemeralKeyPair
    }

    public enum Failure: Error, Equatable {
        /// The claim came back for an account other than the bundle's.
        case accountMismatch
    }

    /// Code as it is shown and as it is read back: four and four, and a reader
    /// who types a lowercase letter or the dash means the same thing.
    public static func formatCode(_ code: String) -> String {
        guard code.count == 8 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 4)
        return code[code.startIndex..<mid] + "-" + code[mid...]
    }

    public static func normalizeCode(_ typed: String) -> String {
        String(typed.uppercased().unicodeScalars.filter {
            ("0"..."9").contains(String($0)) || ("A"..."Z").contains(String($0))
        }.map(Character.init))
    }

    // MARK: - The device being linked

    public static func begin(api: APIClient, deviceName: String,
                             platform: String) async throws -> Pending {
        let ephemeral = Provisioning.EphemeralKeyPair()
        let started = try await api.provisionStart(
            ephemeralKey: ephemeral.publicKey.base64urlEncodedString(),
            deviceName: deviceName, platform: platform)
        return Pending(provisionId: started.provisionId, provisionToken: started.provisionToken,
                       code: started.code, expiresIn: started.expiresIn, ephemeral: ephemeral)
    }

    /// The account bundle, once the other device has approved. Nil while the
    /// session is still pending.
    public static func poll(api: APIClient, pending: Pending) async throws -> Provisioning.Bundle? {
        let status = try await api.provisionStatus(pending.provisionId,
                                                   provisionToken: pending.provisionToken)
        guard status.status == "approved", let envelope = status.envelope,
              let data = envelope.data(using: .utf8) else { return nil }
        let sealed = try JSONDecoder().decode(Provisioning.SealedBundle.self, from: data)
        return try Provisioning.open(sealed, with: pending.ephemeral,
                                     provisionId: pending.provisionId)
    }

    /// Takes the account: the identity comes from the bundle, the prekeys are
    /// this device's own, and the token comes back from the claim.
    ///
    /// The claim answers with the account it actually created the device under.
    /// It has to be the one the bundle named — a session someone else approved
    /// would hand this device a working token on an account its owner never
    /// asked for — and the caller is left with nothing when it is not.
    public static func claim(api: APIClient, pending: Pending, bundle: Provisioning.Bundle,
                             store: IdentityStore, deviceName: String,
                             prekeyCount: Int = 100) async throws -> APIClient.RegisterResponse {
        guard let dh = Data(base64urlEncoded: bundle.identityDH),
              let signing = Data(base64urlEncoded: bundle.identitySigning) else {
            throw Provisioning.Failure.badFormat
        }
        let identity = try store.adoptIdentity(dhRaw: dh, signingRaw: signing)
        let prekeys = try store.generatePrekeys(count: prekeyCount)
        let claimed = try await api.provisionClaim(
            pending.provisionId, provisionToken: pending.provisionToken,
            APIClient.ProvisionClaimRequest(
                identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
                identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
                signedPrekey: .init(id: prekeys.signedPrekey.id,
                                    key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                    sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
                oneTimePrekeys: prekeys.oneTime.map {
                    .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
                },
                deviceName: deviceName))
        guard claimed.userId == bundle.userId else { throw Failure.accountMismatch }
        return claimed
    }

    /// Every chat the account already has starts at its current end on this
    /// device.
    ///
    /// The ratchet destroyed the keys of everything said before this device
    /// existed and the server holds only envelopes addressed elsewhere, so
    /// replaying that history produces unreadable rows and repair requests for
    /// messages nobody can serve. A chat marked here is in the state a chat this
    /// device once deleted is in: `SyncEngine.upsertChatState` reads the mark as
    /// the position its cursors start from, the catch-up asks only for what
    /// comes after, and pagination never goes above it.
    public static func startChatsFromNow(_ dbc: GRDB.Database, chats: [(chatId: String, lastSeq: Int)],
                                         now: Double = Date().timeIntervalSince1970) throws {
        for chat in chats {
            try dbc.execute(sql: """
                INSERT INTO chatTombstone (chatId, seq, deletedAt) VALUES (?,?,?)
                ON CONFLICT(chatId) DO UPDATE SET
                  seq = MAX(chatTombstone.seq, excluded.seq), deletedAt = excluded.deletedAt
                """, arguments: [chat.chatId, chat.lastSeq, now])
        }
    }

    // MARK: - The device that approves

    /// Seals the account for the device waiting on `lookup`.
    public static func approve(api: APIClient, lookup: APIClient.ProvisionLookupResponse,
                               identity: IdentityKeyPair, userId: String,
                               username: String, displayName: String) async throws {
        guard let recipient = Data(base64urlEncoded: lookup.ephemeralKey) else {
            throw Provisioning.Failure.badFormat
        }
        let sealed = try Provisioning.seal(
            Provisioning.Bundle(
                userId: userId, username: username, displayName: displayName,
                identityDH: identity.dh.rawRepresentation.base64urlEncodedString(),
                identitySigning: identity.signing.rawRepresentation.base64urlEncodedString()),
            to: recipient, provisionId: lookup.provisionId)
        let envelope = String(data: try JSONEncoder().encode(sealed), encoding: .utf8)!
        try await api.provisionApprove(lookup.provisionId, envelope: envelope)
    }
}
