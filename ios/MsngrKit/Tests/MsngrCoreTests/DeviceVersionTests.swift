import XCTest
import MsngrCrypto
@testable import MsngrCore

/// The device cache across a reconnect, at the cache level and offline: a
/// reconnect marks entries suspect, the server's `deviceVersions` answer
/// confirms the unchanged ones and drops the changed and the unknown, and the
/// `devices` frame keeps an entry that already holds the version it names.
final class DeviceVersionTests: XCTestCase {
    private func makeE2EE() throws -> E2EEManager {
        let db = try AppDatabase.openInMemory()
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        return E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
    }

    private func device(_ userId: String, _ deviceId: String) -> APIClient.DeviceDTO {
        APIClient.DeviceDTO(userId: userId, deviceId: deviceId,
                            identityKey: "ik", identitySignKey: "isk", identityKeySig: "sig")
    }

    func testUnchangedVersionSurvivesReconnect() throws {
        let e2ee = try makeE2EE()
        e2ee.seedDeviceCache(userId: "u1", devices: [device("u1", "d1")], version: 5)

        e2ee.markDeviceCacheSuspect()
        let suspect = e2ee.cachedDeviceState(userId: "u1")
        XCTAssertEqual(suspect?.verified, false, "a reconnect must leave the entry untrusted")
        XCTAssertNotNil(e2ee.cachedDevices(userId: "u1"), "the data itself stays")

        e2ee.reconcileDeviceVersions(["u1": 5])
        let confirmed = e2ee.cachedDeviceState(userId: "u1")
        XCTAssertEqual(confirmed?.verified, true, "a matching version confirms the entry")
        XCTAssertEqual(e2ee.cachedDevices(userId: "u1")?.count, 1)
    }

    func testChangedVersionIsDropped() throws {
        let e2ee = try makeE2EE()
        e2ee.seedDeviceCache(userId: "u1", devices: [device("u1", "d1")], version: 5)

        e2ee.markDeviceCacheSuspect()
        e2ee.reconcileDeviceVersions(["u1": 6])
        XCTAssertNil(e2ee.cachedDevices(userId: "u1"),
                     "a version the server moved past must drop the entry")
    }

    func testUnknownUserIsDropped() throws {
        let e2ee = try makeE2EE()
        e2ee.seedDeviceCache(userId: "u1", devices: [device("u1", "d1")], version: 5)
        // an entry the server never stamped: nothing can confirm it
        e2ee.seedDeviceCache(userId: "u2", devices: [device("u2", "d2")], version: nil)

        e2ee.markDeviceCacheSuspect()
        e2ee.reconcileDeviceVersions(["u2": 3])
        XCTAssertNil(e2ee.cachedDevices(userId: "u1"),
                     "a user missing from the answer must drop the entry")
        XCTAssertNil(e2ee.cachedDevices(userId: "u2"),
                     "an entry with no version of its own cannot be confirmed")
    }

    func testDevicesFrameKeepsEntryAlreadyAtItsVersion() throws {
        let e2ee = try makeE2EE()
        e2ee.seedDeviceCache(userId: "u1", devices: [device("u1", "d1")], version: 7)

        // the fresh read raced the frame: the cache already holds the change
        e2ee.invalidateDeviceCache(userId: "u1", version: 7)
        XCTAssertNotNil(e2ee.cachedDevices(userId: "u1"))

        e2ee.invalidateDeviceCache(userId: "u1", version: 8)
        XCTAssertNil(e2ee.cachedDevices(userId: "u1"),
                     "a version past the cached one must drop the entry")
    }

    func testSyncReportsVersionsOfSuspectEntriesToo() throws {
        let e2ee = try makeE2EE()
        e2ee.seedDeviceCache(userId: "u1", devices: [device("u1", "d1")], version: 5)
        e2ee.seedDeviceCache(userId: "u2", devices: [device("u2", "d2")], version: nil)
        e2ee.markDeviceCacheSuspect()
        XCTAssertEqual(e2ee.deviceCacheVersions(), ["u1": 5],
                       "the sync asks about every entry that has a version")
    }
}
