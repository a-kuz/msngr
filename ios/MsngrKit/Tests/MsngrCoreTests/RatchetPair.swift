import Foundation
import CryptoKit
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// A pair of ratchet sessions with no server in between: the device's own
/// session goes into the store the code under test reads, and the peer's stays
/// here to produce the envelopes a socket or a push would carry.
///
/// Both chains are running by the time the caller gets it — the device has sent
/// once and received once — so its session can both encrypt and decrypt, as a
/// session in a live chat does.
struct RatchetPair {
    /// The peer, encrypting to this device.
    private var peer: DoubleRatchetSession
    let ownUserId: String
    let ownDeviceId: String
    let peerUserId: String
    let peerDeviceId: String

    init(store: IdentityStore, ownUserId: String = "me", ownDeviceId: String = "dev",
         peerUserId: String = "peer", peerDeviceId: String = "peerdev") throws {
        self.ownUserId = ownUserId
        self.ownDeviceId = ownDeviceId
        self.peerUserId = peerUserId
        self.peerDeviceId = peerDeviceId

        let secret = SymmetricKey(size: .bits256)
        let ad = Data("test-ad".utf8)
        let peerKey = Curve25519.KeyAgreement.PrivateKey()
        var device = try DoubleRatchetSession.initAlice(
            sharedSecret: secret, theirRatchetPub: peerKey.publicKey.rawRepresentation, ad: ad)
        peer = DoubleRatchetSession.initBob(sharedSecret: secret, ourRatchetKey: peerKey, ad: ad)

        // one round trip: the peer's receiving chain starts at the device's
        // first message, and the device's at the answer to it
        _ = try peer.decrypt(try device.encrypt(Data("hello".utf8)))
        _ = try device.decrypt(try peer.encrypt(Data("hi".utf8)))

        try store.saveSession(device, peerUserId: peerUserId, peerDeviceId: peerDeviceId,
                              theirIdentityDH: "")
    }

    /// One message from the peer, as the envelope that travels.
    mutating func envelope(text: String, kind: String = "text") throws -> JSONValue {
        var payload = ContentPayload(kind: kind)
        payload.text = text
        let inner = InnerMessage(content: payload)
        let message = try peer.encrypt(try JSONEncoder().encode(inner))
        var env = Envelope(mode: "pw")
        env.msgs = ["\(ownUserId)/\(ownDeviceId)": PairwiseBox(
            type: "dr", c: try JSONEncoder().encode(message).base64EncodedString())]
        return try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(env))
    }
}

enum TestStorage {
    /// A storage location under a fresh temporary directory. Two databases
    /// opened at its path are two processes as far as SQLite and the crypto
    /// gate are concerned.
    static func temporary() throws -> StorageLocation {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msngr-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return StorageLocation(root: root)
    }

    static func remove(_ location: StorageLocation) {
        try? FileManager.default.removeItem(at: location.root)
    }
}
