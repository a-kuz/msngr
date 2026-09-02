import XCTest
import CryptoKit
@testable import MsngrCore
@testable import MsngrCrypto

/// The history rides inside the sealed provisioning bundle as a pointer to a
/// blob on the media store: the bundle carries it or not, the pointer maps to
/// the attachment the media manager knows how to fetch.
final class HistoryTransferTests: XCTestCase {
    private func bundle(history: Provisioning.Bundle.History?) -> Provisioning.Bundle {
        Provisioning.Bundle(userId: "u1", username: "alfa", displayName: "Alfa",
                            identityDH: "ZGg", identitySigning: "c2ln", history: history)
    }

    func testBundleWithHistorySurvivesSealAndOpen() throws {
        let ephemeral = Provisioning.EphemeralKeyPair()
        let history = Provisioning.Bundle.History(mediaId: "m1", key: "a2V5", hash: "aGFzaA==", size: 1234)
        let sealed = try Provisioning.seal(bundle(history: history), to: ephemeral.publicKey,
                                           provisionId: "p1")
        let opened = try Provisioning.open(sealed, with: ephemeral, provisionId: "p1")
        XCTAssertEqual(opened.history, history)
        XCTAssertEqual(opened.userId, "u1")
    }

    func testBundleWithoutHistoryDecodesToNil() throws {
        let ephemeral = Provisioning.EphemeralKeyPair()
        let sealed = try Provisioning.seal(bundle(history: nil), to: ephemeral.publicKey, provisionId: "p2")
        let opened = try Provisioning.open(sealed, with: ephemeral, provisionId: "p2")
        XCTAssertNil(opened.history)
    }

    func testBundleJSONWithoutTheFieldStillDecodes() throws {
        // a bundle written before the history existed names no history
        let json = """
        {"v":1,"userId":"u1","username":"alfa","displayName":"Alfa","identityDH":"ZGg","identitySigning":"c2ln"}
        """
        let decoded = try JSONDecoder().decode(Provisioning.Bundle.self, from: Data(json.utf8))
        XCTAssertNil(decoded.history)
    }

    func testHistoryPointerMapsToTheAttachmentTheStoreReads() {
        let history = Provisioning.Bundle.History(mediaId: "m9", key: "k", hash: "h", size: 42)
        let info = HistoryTransfer.mediaInfo(history)
        XCTAssertEqual(info.mediaId, "m9")
        XCTAssertEqual(info.key, "k")
        XCTAssertEqual(info.hash, "h")
        XCTAssertEqual(info.size, 42)
        XCTAssertEqual(info.mime, HistoryTransfer.mime)
    }
}
