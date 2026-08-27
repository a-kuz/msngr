import XCTest
@testable import Msngr

/// The number as discovery sees it: E.164 on the device, SHA-256 on the wire.
final class PhoneTests: XCTestCase {

    func testInternationalFormPassesThrough() {
        XCTAssertEqual(Phone.e164("+79261234567"), "+79261234567")
    }

    func testSeparatorsAreStripped() {
        XCTAssertEqual(Phone.e164("+7 (926) 123-45-67"), "+79261234567")
    }

    func testRussianEightFoldsIntoPlusSeven() {
        XCTAssertEqual(Phone.e164("89261234567"), "+79261234567")
    }

    func testShortOrLocalNumbersDoNotNormalize() {
        XCTAssertEqual(Phone.e164("123-45-67"), "")
        XCTAssertEqual(Phone.e164("+7926"), "")
        XCTAssertEqual(Phone.e164(""), "")
    }

    /// Both sides — the settings screen and the address-book sync — must hash
    /// the same string to the same value, or a match never happens.
    func testHashIsDeterministic() {
        XCTAssertEqual(Phone.hash("+79261234567"), Phone.hash("+79261234567"))
        XCTAssertEqual(Phone.hash("+79261234567").count, 64)
        XCTAssertNotEqual(Phone.hash("+79261234567"), Phone.hash("+79261234568"))
    }
}
