import XCTest
@testable import Msngr

final class TypingStateTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// A peer typing without pause repeats the frame every three seconds. Each frame
    /// moves the deadline, and nothing falls out in between: this is what made the
    /// subtitle blink between «печатает…» and the presence line.
    func testRepeatedFrameHoldsTheEntry() {
        var state = TypingState()
        state.began("u1", at: start)
        state.began("u1", at: start.addingTimeInterval(3))
        state.expire(at: start.addingTimeInterval(6))
        XCTAssertEqual(state.users, ["u1"])
        state.expire(at: start.addingTimeInterval(8.1))
        XCTAssertTrue(state.isEmpty)
    }

    func testQuietUserFallsOutAfterTheTtl() {
        var state = TypingState()
        state.began("u1", at: start)
        state.expire(at: start.addingTimeInterval(4.9))
        XCTAssertEqual(state.users, ["u1"])
        state.expire(at: start.addingTimeInterval(5))
        XCTAssertTrue(state.isEmpty)
    }

    /// In a group one person going quiet must leave the others typing.
    func testEveryUserCarriesItsOwnDeadline() {
        var state = TypingState()
        state.began("u1", at: start)
        state.began("u2", at: start.addingTimeInterval(4))
        state.expire(at: start.addingTimeInterval(5))
        XCTAssertEqual(state.users, ["u2"])
    }

    /// The header names whoever started first.
    func testOrderOfArrivalIsKept() {
        var state = TypingState()
        state.began("u1", at: start)
        state.began("u2", at: start.addingTimeInterval(1))
        state.began("u1", at: start.addingTimeInterval(2))
        XCTAssertEqual(state.users, ["u1", "u2"])
    }

    func testStopTakesTheUserOff() {
        var state = TypingState()
        state.began("u1", at: start)
        state.ended("u1")
        XCTAssertTrue(state.isEmpty)
        XCTAssertNil(state.nextExpiry())
    }

    func testNextExpiryIsTheEarliestOne() {
        var state = TypingState()
        state.began("u1", at: start)
        state.began("u2", at: start.addingTimeInterval(2))
        XCTAssertEqual(state.nextExpiry(), start.addingTimeInterval(TypingState.ttl))
    }
}
