import Foundation
import CryptoKit
import MsngrCrypto

/// The name a vote carries in an anonymous poll: an HMAC of the account's
/// identity key over the poll id. One person lands on one key inside a poll,
/// which keeps replace-and-retract and one-person-one-vote working, and on
/// unrelated keys across polls, so two polls cannot be joined on a voter. Every
/// device of the account derives the same key, because a linked or restored
/// device carries the account's identity key.
public enum PollPseudonym {
    private static let info = Data("msngr poll pseudonym".utf8)
    public static let prefix = "anon:"

    public static func make(identity: IdentityKeyPair, pollId: String) -> String {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: identity.dh.rawRepresentation),
                                         info: info, outputByteCount: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(pollId.utf8), using: key)
        return prefix + Data(mac).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// The key this account's vote is stored under in `poll`: the pseudonym
    /// for an anonymous poll, the user id for a named one or when the poll
    /// carries no id to derive from.
    public static func voterKey(poll: PollInfo?, ownUserId: String, identity: IdentityKeyPair?) -> String {
        guard let poll, poll.anonymous, let pollId = poll.id, let identity else { return ownUserId }
        return make(identity: identity, pollId: pollId)
    }
}
