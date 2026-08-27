import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// TOFU runs over every device of a recipient, not just the first one. A peer
/// whose second device presents an identity key different from the first is
/// the shape an impersonating device takes, and a send to that peer has to
/// stop rather than go out to whichever device the loop happened to reach
/// first. Runs against a local server like CoreIntegrationTests and skips
/// itself when nothing listens.
final class MultiDeviceTofuTests: XCTestCase {
    private func waitUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () async throws -> Bool) async throws -> Bool {
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if (try? await cond()) == true { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private func makeSuffix() -> String {
        String(UUID().uuidString.prefix(6)).lowercased().replacingOccurrences(of: "-", with: "x")
    }

    func testASecondDeviceWithADivergentKeyBlocksTheSend() async throws {
        guard await CoreIntegrationTests.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = makeSuffix()
        let alice = try await CoreIntegrationTests.makeClient(username: "mta_\(suffix)")
        let bob = try await CoreIntegrationTests.makeClient(username: "mtb_\(suffix)")
        defer { Task { await alice.engine.stop(); await bob.engine.stop() } }

        // Bob links a real second device, then that device republishes a fresh
        // identity of its own: the account now carries two devices that do not
        // agree on their signing key.
        let db2 = try AppDatabase.openInMemory()
        let store2 = try IdentityStore(db: db2, masterKeyProvider: StaticMasterKey())
        let api2 = APIClient(baseURL: CoreIntegrationTests.base)
        let pending = try await DeviceLink.begin(api: api2, deviceName: "second", platform: "test")
        let lookup = try await bob.api.provisionLookup(code: pending.code)
        try await DeviceLink.approve(api: bob.api, lookup: lookup,
                                     identity: bob.e2ee.store.identity(),
                                     userId: bob.userId, username: "mtb_\(suffix)",
                                     displayName: "mtb_\(suffix)")
        guard let bundle = try await DeviceLink.poll(api: api2, pending: pending) else {
            XCTFail("provisioning bundle did not arrive"); return
        }
        let claimed = try await DeviceLink.claim(api: api2, pending: pending, bundle: bundle,
                                                 store: store2, deviceName: "second")
        api2.token = claimed.token

        let rogueDb = try AppDatabase.openInMemory()
        let rogueStore = try IdentityStore(db: rogueDb, masterKeyProvider: StaticMasterKey())
        let rogue = try rogueStore.identity()
        try await api2.publishIdentity(
            identityKey: rogue.dh.publicKey.rawRepresentation.base64urlEncodedString(),
            identitySignKey: rogue.signing.publicKey.rawRepresentation.base64urlEncodedString(),
            identityKeySig: try rogue.dhSignature.base64urlEncodedString())

        // Alice writes for the first time, so the device set is read cold and
        // holds both keys. One of them is trusted on first use; the other reads
        // as a change and the send stops.
        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        var content = ContentPayload(kind: "text")
        content.text = "must not reach a divergent device"
        try await alice.engine.enqueue(content: content, chatId: chatId)

        let blocked = try await waitUntil(15) {
            try await alice.db.read { dbc in
                try Int.fetchOne(
                    dbc,
                    sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND status = -1 AND failReason = ?",
                    arguments: [chatId, SendFailure.identityChanged]) == 1
            }
        }
        XCTAssertTrue(blocked, "a peer with a divergent second-device key must block the send")

        let (delivered, pendingTrust) = try await alice.db.read { dbc in
            (try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                              arguments: [chatId])!,
             try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM trustedIdentity WHERE userId = ? AND changedPending IS NOT NULL",
                              arguments: [bob.userId])!)
        }
        XCTAssertEqual(delivered, 0, "nothing may be delivered while a device key is unaccepted")
        XCTAssertEqual(pendingTrust, 1, "the divergent key has to land in the pending trust state")

        _ = store2; _ = claimed
    }
}
