import XCTest
@testable import MsngrCrypto

final class BackupSealTests: XCTestCase {
    struct Payload: Codable, Equatable {
        var name: String
        var n: Int
    }

    let payload = Payload(name: "alfa", n: 7)

    func testRecoveryCodeRoundTrip() throws {
        let code = BackupSeal.generateRecoveryCode()
        let sealed = try BackupSeal.seal(payload, recoveryCode: code)
        XCTAssertEqual(sealed.v, 1)
        XCTAssertNil(sealed.salt)
        let opened = try BackupSeal.open(sealed, recoveryCode: code, as: Payload.self)
        XCTAssertEqual(opened, payload)
    }

    func testPassphraseRoundTrip() throws {
        let sealed = try BackupSeal.seal(payload, passphrase: "correct horse battery")
        XCTAssertEqual(sealed.v, 2)
        XCTAssertNotNil(sealed.salt)
        let opened = try BackupSeal.open(sealed, recoveryCode: "correct horse battery", as: Payload.self)
        XCTAssertEqual(opened, payload)
    }

    func testWrongPassphraseFails() throws {
        let sealed = try BackupSeal.seal(payload, passphrase: "correct horse battery")
        XCTAssertThrowsError(try BackupSeal.open(sealed, recoveryCode: "wrong horse", as: Payload.self)) {
            XCTAssertEqual($0 as? BackupSeal.Failure, .decryptionFailed)
        }
    }

    func testPassphraseWhitespaceIsTrimmedOnBothSides() throws {
        let sealed = try BackupSeal.seal(payload, passphrase: " secret phrase\n")
        let opened = try BackupSeal.open(sealed, recoveryCode: "secret phrase", as: Payload.self)
        XCTAssertEqual(opened, payload)
    }

    func testSaltDiffersBetweenSeals() throws {
        let a = try BackupSeal.seal(payload, passphrase: "secret phrase")
        let b = try BackupSeal.seal(payload, passphrase: "secret phrase")
        XCTAssertNotEqual(a.salt, b.salt)
        XCTAssertNotEqual(a.ct, b.ct)
    }

    func testEmptyPassphraseIsRefused() {
        XCTAssertThrowsError(try BackupSeal.seal(payload, passphrase: "   ")) {
            XCTAssertEqual($0 as? BackupSeal.Failure, .badFormat)
        }
    }
}
