import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// The device cache on the send path: a run of messages shares one
/// /api/devices read, and the `devices` frame is what drops the cached list
/// when the peer links or revokes a device. Runs against a local server the
/// same way CoreIntegrationTests does and skips itself when nothing listens.
final class DeviceCacheTests: XCTestCase {
    func waitUntil(_ timeout: TimeInterval = 8, _ cond: @escaping () async throws -> Bool) async throws -> Bool {
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

    func testTenSendsShareOneDevicesRequest() async throws {
        guard await CoreIntegrationTests.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = makeSuffix()
        let alice = try await CoreIntegrationTests.makeClient(username: "dca_\(suffix)")
        let bob = try await CoreIntegrationTests.makeClient(username: "dcb_\(suffix)")
        defer { Task { await alice.engine.stop(); await bob.engine.stop() } }

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        let before = alice.api.devicesRequestCount
        for i in 1...10 {
            var content = ContentPayload(kind: "text")
            content.text = "burst \(i)"
            try await alice.engine.enqueue(content: content, chatId: chatId)
        }
        let allAcked = try await waitUntil(15) {
            try await alice.db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND seq IS NOT NULL",
                                 arguments: [chatId]) == 10
            }
        }
        XCTAssertTrue(allAcked, "not all 10 sends were acked")
        let requests = alice.api.devicesRequestCount - before
        XCTAssertEqual(requests, 1, "10 sequential sends must share one /api/devices read, got \(requests)")
    }

    func testLinkedDeviceReachesSenderWithoutReconnect() async throws {
        guard await CoreIntegrationTests.serverUp() else {
            throw XCTSkip("wrangler dev is not running")
        }
        let suffix = makeSuffix()
        let alice = try await CoreIntegrationTests.makeClient(username: "dcl_\(suffix)")
        let bob = try await CoreIntegrationTests.makeClient(username: "dcm_\(suffix)")
        defer { Task { await alice.engine.stop(); await bob.engine.stop() } }

        let chatId = try await alice.api.createChat(kind: "direct", memberIds: [bob.userId], title: nil)
        try await alice.engine.refreshSnapshot()

        // the first message warms Alice's device cache with Bob's single device
        var first = ContentPayload(kind: "text")
        first.text = "before the second device"
        try await alice.engine.enqueue(content: first, chatId: chatId)
        let warmed = try await waitUntil {
            alice.e2ee.cachedDevices(userId: bob.userId)?.count == 1
        }
        XCTAssertTrue(warmed, "the first send did not fill the device cache")

        // Bob links a second device while Alice's socket stays up
        let db2 = try AppDatabase.openInMemory()
        let store2 = try IdentityStore(db: db2, masterKeyProvider: StaticMasterKey())
        let api2 = APIClient(baseURL: CoreIntegrationTests.base)
        let pending = try await DeviceLink.begin(api: api2, deviceName: "second", platform: "test")
        let lookup = try await bob.api.provisionLookup(code: pending.code)
        try await DeviceLink.approve(api: bob.api, lookup: lookup,
                                     identity: bob.e2ee.store.identity(),
                                     userId: bob.userId, username: "dcm_\(suffix)",
                                     displayName: "dcm_\(suffix)")
        guard let bundle = try await DeviceLink.poll(api: api2, pending: pending) else {
            XCTFail("provisioning bundle did not arrive"); return
        }
        let claimed = try await DeviceLink.claim(api: api2, pending: pending, bundle: bundle,
                                                 store: store2, deviceName: "second")
        api2.token = claimed.token

        // the devices frame reaches Alice with no reconnect and drops the entry
        let invalidated = try await waitUntil {
            alice.e2ee.cachedDevices(userId: bob.userId) == nil
        }
        XCTAssertTrue(invalidated, "the devices frame did not drop Alice's cached list")

        // Bob's new device comes up and the next message reaches it
        let e2ee2 = E2EEManager(store: store2, api: api2,
                                ownUserId: claimed.userId, ownDeviceId: claimed.deviceId)
        var comps = URLComponents(url: CoreIntegrationTests.base.appendingPathComponent("ws"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: claimed.token)]
        let engine2 = SyncEngine(db: db2, api: api2, e2ee: e2ee2, wsURL: comps.url!,
                                 ownUserId: claimed.userId, ownDeviceId: claimed.deviceId)
        await engine2.start()
        defer { Task { await engine2.stop() } }
        try await engine2.refreshSnapshot()

        var second = ContentPayload(kind: "text")
        second.text = "for the new device"
        try await alice.engine.enqueue(content: second, chatId: chatId)

        let reachedNew = try await waitUntil(15) {
            try await db2.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND text = 'for the new device'",
                                 arguments: [chatId]) == 1
            }
        }
        XCTAssertTrue(reachedNew, "the message never reached the freshly linked device")
        let refilled = alice.e2ee.cachedDevices(userId: bob.userId)?.count
        XCTAssertEqual(refilled, 2, "the re-read list must hold both of Bob's devices")

        // revocation travels the same road: the entry drops again, and the
        // next send addresses one device
        try await bob.api.revokeSession(deviceId: claimed.deviceId)
        let droppedAgain = try await waitUntil {
            alice.e2ee.cachedDevices(userId: bob.userId) == nil
        }
        XCTAssertTrue(droppedAgain, "revocation did not drop Alice's cached list")

        var third = ContentPayload(kind: "text")
        third.text = "after the revocation"
        try await alice.engine.enqueue(content: third, chatId: chatId)
        let narrowed = try await waitUntil {
            alice.e2ee.cachedDevices(userId: bob.userId)?.count == 1
        }
        XCTAssertTrue(narrowed, "the send after revocation must see one device")
    }
}
