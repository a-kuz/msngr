import Foundation
import CryptoKit
import MsngrCrypto

/// Opening an incoming envelope: pairwise ratchet or sender key.
///
/// Decryption needs the device's own keys and nothing else, so it is separate
/// from the sending side and its network. The notification service extension
/// holds one of these over the shared database — it has keys, no socket and no
/// business asking the server anything.
///
/// Every entry point steps crypto state, so every one of them runs behind the
/// `CryptoGate`: the app and the extension open envelopes over one file.
public struct IncomingDecryptor: Sendable {
    let store: IdentityStore
    public let ownUserId: String
    public let ownDeviceId: String
    let gate: CryptoGate

    public init(store: IdentityStore, ownUserId: String, ownDeviceId: String,
                gate: CryptoGate = CryptoGate(url: nil)) {
        self.store = store
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
        self.gate = gate
    }

    private func addr(_ userId: String, _ deviceId: String) -> String { "\(userId)/\(deviceId)" }

    /// Opens an envelope, taking the gate for the length of the ratchet step.
    ///
    /// `plaintext` is the caller's statement that this chat is a channel, whose
    /// posts travel readable. Everywhere else a readable envelope is refused:
    /// otherwise anyone could put an unencrypted message into an encrypted chat
    /// and have it read as an ordinary one.
    public func decrypt(envelopeJSON: JSONValue, chatId: String,
                        fromUserId: String, fromDeviceId: String,
                        plaintext: Bool = false) throws -> DecryptedIncoming {
        try gate.withLock { ticket in
            try decrypt(envelopeJSON: envelopeJSON, chatId: chatId, fromUserId: fromUserId,
                        fromDeviceId: fromDeviceId, plaintext: plaintext, holding: ticket)
        }
    }

    /// Same, for a caller that already holds the gate — the extension takes it
    /// before opening the transaction it decrypts and stores in.
    public func decrypt(envelopeJSON: JSONValue, chatId: String, fromUserId: String,
                        fromDeviceId: String, plaintext: Bool = false,
                        holding _: CryptoGate.Ticket) throws -> DecryptedIncoming {
        let env: Envelope
        do { env = try envelopeJSON.decoded(Envelope.self) }
        catch { return .undecryptable(reason: "bad_envelope") }

        // an envelope written in a format this build does not know: its fields
        // may mean something else here, so it is not opened by guesswork. The
        // envelope is kept as it stands and replayed like any other unreadable
        // one — a build that knows the format opens it then.
        guard env.v <= MsngrProtocol.envelopeVersion else {
            return .undecryptable(reason: MessageRepair.envelopeAheadReason)
        }

        switch env.mode {
        case "plain":
            guard plaintext else { return .undecryptable(reason: "plaintext_refused") }
            guard let content = env.p else { return .undecryptable(reason: "bad_plain") }
            return .content(content)
        case "pw":
            guard let box = env.msgs?[addr(ownUserId, ownDeviceId)] else {
                return .undecryptable(reason: "not_addressed")
            }
            return try decryptPairwise(box: box, chatId: chatId,
                                       fromUserId: fromUserId, fromDeviceId: fromDeviceId)
        case "skm":
            guard let cB64 = env.c, let c = Data(base64Encoded: cB64),
                  let keyId = env.keyId, let iteration = env.iteration,
                  let sigB64 = env.sig, let sig = Data(base64Encoded: sigB64) else {
                return .undecryptable(reason: "bad_skm")
            }
            guard var receiver = try store.loadSenderKeyIn(chatId: chatId, senderUserId: fromUserId, keyId: keyId) else {
                return .undecryptable(reason: "no_sender_key")
            }
            let msg = SenderKeyMessage(keyId: keyId, iteration: iteration, ciphertext: c, signature: sig)
            let plaintext = try receiver.decrypt(msg)
            try store.saveSenderKeyIn(chatId: chatId, senderUserId: fromUserId, keyId: keyId, state: receiver)
            let content = try JSONDecoder().decode(ContentPayload.self, from: plaintext)
            return .content(content)
        default:
            return .undecryptable(reason: "unknown_mode")
        }
    }

    private func decryptPairwise(box: PairwiseBox, chatId: String,
                                 fromUserId: String, fromDeviceId: String) throws -> DecryptedIncoming {
        guard let msgData = Data(base64Encoded: box.c),
              let ratchetMsg = try? JSONDecoder().decode(RatchetMessage.self, from: msgData) else {
            return .undecryptable(reason: "bad_box")
        }

        var trustIssue: String?

        // Always try the sessions we already know first, active one before archived ones.
        // A message must not be lost just because the two sides' state drifted apart.
        let current = try store.loadSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
        if var existing = current, let plain = try? existing.decrypt(ratchetMsg) {
            try store.saveSession(existing, peerUserId: fromUserId, peerDeviceId: fromDeviceId)
            return try handleInner(plain, chatId: chatId, fromUserId: fromUserId, trustIssue: nil)
        }
        var archive = try store.archivedSessions(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
        for i in archive.indices {
            if let plain = try? archive[i].decrypt(ratchetMsg) {
                try store.saveArchivedSessions(archive, peerUserId: fromUserId, peerDeviceId: fromDeviceId)
                return try handleInner(plain, chatId: chatId, fromUserId: fromUserId, trustIssue: nil)
            }
        }

        if box.type == "pk" {
            // A pk that no known session could open: build a fresh responder session and
            // move the current one to the archive, where messages still in flight can
            // reach it. This resolves both simultaneous initiation (glare) and plain drift.
            guard let ikB64 = box.ik, let ik = Data(base64urlEncoded: ikB64),
                  let iskB64 = box.isk, let isk = Data(base64urlEncoded: iskB64),
                  let sigB64 = box.iksig, let iksig = Data(base64urlEncoded: sigB64),
                  let ekB64 = box.ek, let ek = Data(base64urlEncoded: ekB64),
                  let spkId = box.spkId,
                  let spkPriv = try store.signedPrekey(id: spkId) else {
                return .undecryptable(reason: "bad_pk")
            }
            // The identity is trusted by its signing key and the session runs on its
            // DH key, so an envelope that does not tie the two together is one where
            // the trust answer would be about a key nothing here uses.
            guard IdentityBinding.verify(dh: ik, signature: iksig, signingPub: isk) else {
                return .undecryptable(reason: "unbound_identity")
            }
            // The handshake this session already came out of, arriving again: a replay,
            // and rebuilding on it would put a live session in the archive and leave
            // this device with a responder session that cannot send.
            if current?.isReplayedHandshake(ephemeral: ek) == true
                || archive.contains(where: { $0.isReplayedHandshake(ephemeral: ek) }) {
                return .undecryptable(reason: MessageRepair.stalePrekeyReason)
            }
            let trust = try store.checkTrust(userId: fromUserId, identitySigning: iskB64)
            if case .changed = trust { trustIssue = iskB64 }
            var otpPriv: Curve25519.KeyAgreement.PrivateKey?
            if let otpId = box.otpId {
                otpPriv = try store.oneTimePrekey(id: otpId)
            }
            // Two candidates: with the one-time prekey and without it. The second covers a
            // prekey already spent by a re-issued bundle or a duplicated envelope.
            var candidates: [DoubleRatchetSession] = []
            let identity = try store.identity()
            for otp in [otpPriv, nil] as [Curve25519.KeyAgreement.PrivateKey?] {
                if otpPriv == nil && otp != nil { continue }
                if let x3dh = try? X3DH.respond(our: identity, ourSignedPreKey: spkPriv,
                                                ourOneTimePreKey: otp,
                                                theirIdentityDH: ik, theirEphemeral: ek) {
                    candidates.append(DoubleRatchetSession.initBob(
                        sharedSecret: x3dh.sharedSecret, ourRatchetKey: spkPriv,
                        ad: x3dh.associatedData, handshakeEphemeral: ek))
                }
                if otpPriv == nil { break }
            }
            for var candidate in candidates {
                if let plain = try? candidate.decrypt(ratchetMsg) {
                    if let otpId = box.otpId { try store.consumeOneTimePrekey(id: otpId) }
                    // the session in place goes to the archive only now, with a
                    // replacement that has opened something in hand
                    try store.archiveCurrentSession(peerUserId: fromUserId, peerDeviceId: fromDeviceId)
                    try store.saveSession(candidate, peerUserId: fromUserId, peerDeviceId: fromDeviceId)
                    return try handleInner(plain, chatId: chatId, fromUserId: fromUserId, trustIssue: trustIssue)
                }
            }
            return .undecryptable(reason: "pk_decrypt_failed")
        }

        // A dr message that neither the active nor any archived session could open. Its key
        // may still arrive (the message overtook its own pk), so the reason is retryable.
        return .undecryptable(reason: "no_session")
    }

    private func handleInner(_ plaintext: Data, chatId: String, fromUserId: String,
                             trustIssue: String?) throws -> DecryptedIncoming {
        let inner = try JSONDecoder().decode(InnerMessage.self, from: plaintext)
        if inner.type == "skd", let skd = inner.skd, let chainChatId = inner.chatId {
            // Re-distributing the same chain must not roll the receiver back: the stored
            // one may already have stepped forward through several iterations.
            if try store.loadSenderKeyIn(chatId: chainChatId, senderUserId: fromUserId, keyId: skd.keyId) == nil {
                let receiver = SenderKeyReceiver(distribution: skd)
                try store.saveSenderKeyIn(chatId: chainChatId, senderUserId: fromUserId,
                                          keyId: skd.keyId, state: receiver)
            }
            return .senderKeyDistribution(chatId: chainChatId, keyId: skd.keyId)
        }
        guard let content = inner.content else { return .undecryptable(reason: "empty_inner") }
        // The sender named the chat inside the sealed box; the chat the envelope
        // was delivered in comes from the server. A message put into another
        // conversation is not a message of this one.
        guard inner.chatId == chatId else {
            return .undecryptable(reason: MessageRepair.wrongChatReason)
        }
        if trustIssue != nil {
            return .identityChanged(userId: fromUserId, content: content)
        }
        return .content(content)
    }
}
