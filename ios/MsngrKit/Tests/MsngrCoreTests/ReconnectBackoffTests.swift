import XCTest
@testable import MsngrCore

final class ReconnectBackoffTests: XCTestCase {
    func testDelayGrowsAndCaps() {
        XCTAssertEqual(WSClient.reconnectDelay(attempt: 0), 1.0, accuracy: 0.001)
        XCTAssertGreaterThan(WSClient.reconnectDelay(attempt: 3),
                             WSClient.reconnectDelay(attempt: 1))
        // the cap: when the network comes back, the wait must not run into minutes
        XCTAssertEqual(WSClient.reconnectDelay(attempt: 20), 12.0, accuracy: 0.001)
        XCTAssertLessThanOrEqual(WSClient.reconnectDelay(attempt: 100), 12.0)
    }

    func testFirstAttemptsAreQuick() {
        for attempt in 0..<3 {
            XCTAssertLessThan(WSClient.reconnectDelay(attempt: attempt), 3.0)
        }
    }
}
