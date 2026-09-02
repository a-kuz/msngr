import XCTest
@testable import MsngrCrypto

/// The iCloud backup is sealed under a key nobody types: random, held in the
/// iCloud Keychain, opened by any device signed into the same Apple ID.
final class BackupSealDeviceKeyTests: XCTestCase {
    struct Payload: Codable, Equatable { var name: String; var n: Int }
    let payload = Payload(name: "alfa", n: 7)

    func testDeviceKeyRoundTrip() throws {
        let key = BackupSeal.generateDeviceKey()
        XCTAssertEqual(key.count, BackupSeal.deviceKeyBytes)
        let sealed = try BackupSeal.seal(payload, deviceKey: key)
        XCTAssertEqual(sealed.v, 3)
        XCTAssertNil(sealed.salt)
        XCTAssertEqual(try BackupSeal.open(sealed, deviceKey: key, as: Payload.self), payload)
    }

    func testAnotherKeyDoesNotOpenIt() throws {
        let sealed = try BackupSeal.seal(payload, deviceKey: BackupSeal.generateDeviceKey())
        XCTAssertThrowsError(try BackupSeal.open(sealed, deviceKey: BackupSeal.generateDeviceKey(),
                                                 as: Payload.self)) { error in
            XCTAssertEqual(error as? BackupSeal.Failure, .decryptionFailed)
        }
    }

    func testTypedOpenRefusesADeviceKeyBackup() throws {
        let sealed = try BackupSeal.seal(payload, deviceKey: BackupSeal.generateDeviceKey())
        XCTAssertThrowsError(try BackupSeal.open(sealed, recoveryCode: "ABCD", as: Payload.self)) { error in
            XCTAssertEqual(error as? BackupSeal.Failure, .unsupportedVersion)
        }
    }

    func testDeviceKeyOpenRefusesATypedBackup() throws {
        let code = BackupSeal.generateRecoveryCode()
        let sealed = try BackupSeal.seal(payload, recoveryCode: code)
        XCTAssertThrowsError(try BackupSeal.open(sealed, deviceKey: BackupSeal.generateDeviceKey(),
                                                 as: Payload.self)) { error in
            XCTAssertEqual(error as? BackupSeal.Failure, .unsupportedVersion)
        }
    }

    func testAShortKeyIsRefused() {
        XCTAssertThrowsError(try BackupSeal.seal(payload, deviceKey: Data([1, 2, 3])))
    }
}
