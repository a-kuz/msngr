import XCTest
@testable import MsngrCore

final class CountFormatterTests: XCTestCase {
    func testBelowThousand() {
        XCTAssertEqual(CountFormatter.short(0), "0")
        XCTAssertEqual(CountFormatter.short(9), "9")
        XCTAssertEqual(CountFormatter.short(550), "550")
        XCTAssertEqual(CountFormatter.short(999), "999")
    }

    func testThousands() {
        XCTAssertEqual(CountFormatter.short(1000), "1k")
        XCTAssertEqual(CountFormatter.short(1449), "1.4k")
        XCTAssertEqual(CountFormatter.short(1500), "1.5k")
        XCTAssertEqual(CountFormatter.short(9999), "10k")
        XCTAssertEqual(CountFormatter.short(12_000), "12k")
        XCTAssertEqual(CountFormatter.short(999_499), "999k")
    }

    func testMillions() {
        XCTAssertEqual(CountFormatter.short(1_000_000), "1M")
        XCTAssertEqual(CountFormatter.short(2_500_000), "2.5M")
        XCTAssertEqual(CountFormatter.short(15_000_000), "15M")
    }
}
