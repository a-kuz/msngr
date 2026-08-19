import XCTest
import GRDB
import MsngrCrypto
@testable import MsngrCore

/// Driver for the live simulator run, not part of the suite: it skips itself
/// unless MSNGR_LIVE_LINK=1. It plays the second device of a user whose first
/// device is the app on a simulator: prints the provisioning code for the
/// operator to approve in that app, claims the account, waits for a message
/// addressed to it, then logs out so the revocation road is exercised too.
final class LiveLinkDriverTests: XCTestCase {
    /// stdout is block-buffered under a pipe, so progress goes to a file the
    /// operator tails; the path comes in MSNGR_LIVE_LOG.
    private func report(_ line: String) {
        print(line)
        guard let path = ProcessInfo.processInfo.environment["MSNGR_LIVE_LOG"] else { return }
        let url = URL(fileURLWithPath: path)
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    func testSecondDeviceLiveFlow() async throws {
        guard ProcessInfo.processInfo.environment["MSNGR_LIVE_LINK"] == "1" else {
            throw XCTSkip("live driver; set MSNGR_LIVE_LINK=1 to run")
        }
        let db = try AppDatabase.openInMemory()
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let api = APIClient(baseURL: CoreIntegrationTests.base)

        let pending = try await DeviceLink.begin(api: api, deviceName: "devcache-b2", platform: "test")
        report("LIVE-LINK CODE: \(DeviceLink.formatCode(pending.code))")

        var bundle: Provisioning.Bundle?
        let t0 = Date()
        while Date().timeIntervalSince(t0) < 240 {
            if let b = try await DeviceLink.poll(api: api, pending: pending) { bundle = b; break }
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        guard let bundle else { XCTFail("LIVE-LINK: approval never came"); return }
        report("LIVE-LINK APPROVED for \(bundle.username)")

        let claimed = try await DeviceLink.claim(api: api, pending: pending, bundle: bundle,
                                                 store: store, deviceName: "devcache-b2")
        api.token = claimed.token
        report("LIVE-LINK CLAIMED deviceId=\(claimed.deviceId)")

        let e2ee = E2EEManager(store: store, api: api,
                               ownUserId: claimed.userId, ownDeviceId: claimed.deviceId)
        var comps = URLComponents(url: CoreIntegrationTests.base.appendingPathComponent("ws"),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        comps.queryItems = [URLQueryItem(name: "token", value: claimed.token)]
        let engine = SyncEngine(db: db, api: api, e2ee: e2ee, wsURL: comps.url!,
                                ownUserId: claimed.userId, ownDeviceId: claimed.deviceId)
        await engine.start()
        defer { Task { await engine.stop() } }
        try await engine.refreshSnapshot()

        var got = false
        let t1 = Date()
        while Date().timeIntervalSince(t1) < 240 {
            let text = try await db.read { dbc in
                try String.fetchOne(dbc, sql: "SELECT text FROM message WHERE text LIKE 'for the new device%' LIMIT 1")
            }
            if text != nil { got = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        XCTAssertTrue(got, "LIVE-LINK: the message never reached the second device")
        report(got ? "LIVE-LINK B2 RECEIVED the message" : "LIVE-LINK B2 TIMED OUT")

        try await api.logout()
        report("LIVE-LINK B2 LOGGED OUT")
    }
}
