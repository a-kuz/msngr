import XCTest
import CryptoKit
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Opening a prekey envelope: what it has to prove about the sender, and what a
/// second copy of one must not do to the session it already built.
final class PrekeyEnvelopeTests: XCTestCase {
    private let ownUserId = "me"
    private let ownDeviceId = "dev"
    private let peerUserId = "peer"
    private let peerDeviceId = "peerdev"

    /// The other side of the conversation: it holds this device's published
    /// bundle and produces the envelopes a socket would carry.
    private struct Peer {
        var identity: IdentityKeyPair
        var session: DoubleRatchetSession
        var ephemeral: Data

        mutating func message(_ text: String, type: String = "pk",
                              spkId: UInt32, chatId: String = "c1") throws -> PairwiseBox {
            var payload = ContentPayload(kind: "text")
            payload.text = text
            let inner = InnerMessage(content: payload, chatId: chatId)
            let msg = try session.encrypt(try JSONEncoder().encode(inner))
            var box = PairwiseBox(type: type, c: try JSONEncoder().encode(msg).base64EncodedString())
            guard type == "pk" else { return box }
            box.ik = identity.dh.publicKey.rawRepresentation.base64urlEncodedString()
            box.isk = identity.signing.publicKey.rawRepresentation.base64urlEncodedString()
            box.iksig = try identity.dhSignature.base64urlEncodedString()
            box.ek = ephemeral.base64urlEncodedString()
            box.spkId = spkId
            return box
        }
    }

    private func makePeer(against store: IdentityStore,
                          identity: IdentityKeyPair = IdentityKeyPair()) throws -> (Peer, UInt32) {
        let ours = try store.identity()
        let prekeys = try store.generatePrekeys(count: 4)
        let spkPub = prekeys.signedPrekey.key.publicKey.rawRepresentation
        let bundle = PreKeyBundle(identity: try ours.publicKeys,
                                  signedPreKeyId: prekeys.signedPrekey.id,
                                  signedPreKey: spkPub,
                                  signedPreKeySignature: prekeys.signedPrekey.signature,
                                  oneTimePreKeyId: nil, oneTimePreKey: nil)
        let x3dh = try X3DH.initiate(our: identity, their: bundle)
        let session = try DoubleRatchetSession.initAlice(
            sharedSecret: x3dh.sharedSecret, theirRatchetPub: spkPub, ad: x3dh.associatedData)
        return (Peer(identity: identity, session: session, ephemeral: x3dh.ephemeralPublic),
                prekeys.signedPrekey.id)
    }

    private func envelope(_ box: PairwiseBox) throws -> JSONValue {
        var env = Envelope(mode: "pw")
        env.msgs = ["\(ownUserId)/\(ownDeviceId)": box]
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(env))
    }

    private func makeStore() throws -> (IdentityStore, IncomingDecryptor) {
        let db = try AppDatabase.openInMemory()
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        return (store, IncomingDecryptor(store: store, ownUserId: ownUserId, ownDeviceId: ownDeviceId))
    }

    private func text(_ result: DecryptedIncoming) -> String? {
        switch result {
        case .content(let payload): return payload.text
        case .identityChanged(_, let payload): return payload?.text
        default: return nil
        }
    }

    private func reason(_ result: DecryptedIncoming) -> String? {
        if case .undecryptable(let reason) = result { return reason }
        return nil
    }

    /// A canonical encoding of the session, safe to compare byte-for-byte:
    /// the session holds a dictionary, and plain JSONEncoder output does not
    /// promise a key order.
    private func fields(of session: DoubleRatchetSession) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(session)
    }

    /// The signing key is the peer's real one, the DH key is somebody else's.
    /// The pair is not signed as one, so the envelope opens nothing and the
    /// peer's trusted identity is not written on the strength of it.
    func testRefusesAnIdentityWhoseDHKeyIsNotItsOwn() throws {
        let (store, decryptor) = try makeStore()
        var (peer, spkId) = try makePeer(against: store)
        var box = try peer.message("hello", spkId: spkId)
        box.ik = IdentityKeyPair().dh.publicKey.rawRepresentation.base64urlEncodedString()

        let result = try decryptor.decrypt(envelopeJSON: try envelope(box), chatId: "c1",
                                           fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(reason(result), "unbound_identity")
        XCTAssertNil(try store.loadSession(peerUserId: peerUserId, peerDeviceId: peerDeviceId))
    }

    /// An envelope that names no identity at all is refused too: there is no
    /// "trust it anyway" path around the check.
    func testRefusesAPrekeyEnvelopeWithNoIdentity() throws {
        let (store, decryptor) = try makeStore()
        var (peer, spkId) = try makePeer(against: store)
        var box = try peer.message("hello", spkId: spkId)
        box.isk = nil
        box.iksig = nil

        let result = try decryptor.decrypt(envelopeJSON: try envelope(box), chatId: "c1",
                                           fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(reason(result), "bad_pk")
        XCTAssertNil(try store.loadSession(peerUserId: peerUserId, peerDeviceId: peerDeviceId))
    }

    /// The same prekey envelope delivered twice. The second copy is refused, the
    /// session that came out of the first one stays in place and can still send,
    /// and nothing is pushed into the archive.
    func testAReplayedPrekeyEnvelopeLeavesTheLiveSessionAlone() throws {
        let (store, decryptor) = try makeStore()
        var (peer, spkId) = try makePeer(against: store)
        let first = try peer.message("hello", spkId: spkId)

        let opened = try decryptor.decrypt(envelopeJSON: try envelope(first), chatId: "c1",
                                           fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(text(opened), "hello")
        let established = try XCTUnwrap(try store.loadSession(peerUserId: peerUserId,
                                                              peerDeviceId: peerDeviceId))

        let replayed = try decryptor.decrypt(envelopeJSON: try envelope(first), chatId: "c1",
                                             fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(reason(replayed), MessageRepair.stalePrekeyReason)

        var current = try XCTUnwrap(try store.loadSession(peerUserId: peerUserId,
                                                          peerDeviceId: peerDeviceId))
        XCTAssertEqual(try fields(of: current), try fields(of: established),
                       "the replay must not have moved the session")
        XCTAssertNoThrow(try current.encrypt(Data("reply".utf8)),
                         "the session still has a sending chain")
        XCTAssertTrue(try store.archivedSessions(peerUserId: peerUserId,
                                                 peerDeviceId: peerDeviceId).isEmpty)

        // and the peer's next message still opens under that session
        let next = try peer.message("second", type: "dr", spkId: spkId)
        let followUp = try decryptor.decrypt(envelopeJSON: try envelope(next), chatId: "c1",
                                             fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(text(followUp), "second")
    }

    /// The server hands the reader a message of one chat inside another. The
    /// sender named the chat in the sealed box, so it opens nothing here.
    func testAMessageDeliveredInAnotherChatIsRefused() throws {
        let (store, decryptor) = try makeStore()
        var (peer, spkId) = try makePeer(against: store)
        let box = try peer.message("meant for c1", spkId: spkId, chatId: "c1")

        let result = try decryptor.decrypt(envelopeJSON: try envelope(box), chatId: "c2",
                                           fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(reason(result), MessageRepair.wrongChatReason)
        XCTAssertNil(text(result))
    }

    /// The peer started over — new keys, new handshake — while this device still
    /// holds the old session. That envelope is not a replay: the session is
    /// rebuilt on it and the message is read.
    func testAPeerThatStartedOverRebuildsTheSession() throws {
        let (store, decryptor) = try makeStore()
        var (peer, spkId) = try makePeer(against: store)
        let first = try peer.message("hello", spkId: spkId)
        XCTAssertEqual(text(try decryptor.decrypt(envelopeJSON: try envelope(first), chatId: "c1",
                                                  fromUserId: peerUserId,
                                                  fromDeviceId: peerDeviceId)), "hello")

        // reinstalled: keys of its own, a handshake of its own, against a bundle
        // this device publishes anew
        var (reborn, newSpkId) = try makePeer(against: store)
        let afterReinstall = try reborn.message("i am back", spkId: newSpkId)
        let result = try decryptor.decrypt(envelopeJSON: try envelope(afterReinstall), chatId: "c1",
                                           fromUserId: peerUserId, fromDeviceId: peerDeviceId)
        XCTAssertEqual(text(result), "i am back")
        guard case .identityChanged = result else {
            return XCTFail("a peer with new identity keys is reported as changed")
        }
        // the session in place is the new one, and the old one is kept for
        // messages still in flight under it
        XCTAssertEqual(try store.archivedSessions(peerUserId: peerUserId,
                                                  peerDeviceId: peerDeviceId).count, 1)
        let follow = try reborn.message("still me", type: "dr", spkId: newSpkId)
        XCTAssertEqual(text(try decryptor.decrypt(envelopeJSON: try envelope(follow), chatId: "c1",
                                                  fromUserId: peerUserId,
                                                  fromDeviceId: peerDeviceId)), "still me")
    }
}
