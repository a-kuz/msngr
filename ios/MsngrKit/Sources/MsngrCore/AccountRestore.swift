import Foundation
import MsngrCrypto

/// Claiming an account from a decrypted backup, with no other device online to
/// approve it.
///
/// `DeviceLink` gets its authorization from a live device's session token; this
/// has none, so it proves the same thing a different way — signing the
/// server's nonce with the account's own identity private key, which only a
/// holder of the backup (and its recovery code) has. `/api/restore/start` and
/// `/api/restore/:id/claim` on the server check that signature against the
/// identity key already on file, then add the device exactly as a live
/// approval would.
public enum AccountRestore {
    public enum Failure: Error, Equatable {
        /// The claim came back for an account other than the backup's.
        case accountMismatch
    }

    public static func claim(api: APIClient, payload: BackupPayload, store: IdentityStore,
                             deviceName: String, prekeyCount: Int = 100) async throws -> APIClient.RegisterResponse {
        guard let dh = Data(base64urlEncoded: payload.identityDH),
              let signing = Data(base64urlEncoded: payload.identitySigning) else {
            throw BackupSeal.Failure.badFormat
        }
        let identity = try store.adoptIdentity(dhRaw: dh, signingRaw: signing)
        let started = try await api.restoreStart(username: payload.username)
        // the server verifies the signature over the nonce's own UTF-8 bytes
        // (the b64url text it handed out), not the bytes that text decodes to
        let signature = try identity.signing.signature(for: Data(started.nonce.utf8))
        let prekeys = try store.generatePrekeys(count: prekeyCount)
        let claimed = try await api.restoreClaim(
            started.restoreId,
            APIClient.RestoreClaimRequest(
                identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
                identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
                identityKeySig: try identity.dhSignature.base64urlEncodedString(),
                signature: signature.base64urlEncodedString(),
                signedPrekey: .init(id: prekeys.signedPrekey.id,
                                    key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                    sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
                oneTimePrekeys: prekeys.oneTime.map {
                    .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
                },
                deviceName: deviceName))
        guard claimed.userId == payload.userId else { throw Failure.accountMismatch }
        return claimed
    }
}
