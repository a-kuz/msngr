import XCTest
import MsngrCore
@testable import Msngr

/// How one message's read-by list is split from the members and their marks:
/// who counts as having read, who as merely having it, who is left out.
final class ReadByRosterTests: XCTestCase {
    private let members = [
        User(id: "me", username: "alfa", displayName: "Alice"),
        User(id: "u2", username: "bravo", displayName: "Bob"),
        User(id: "u3", username: "charlie", displayName: "Charlie"),
        User(id: "u4", username: "delta", displayName: "Dave"),
    ]

    func testSplitsReadFromDeliveredAndSkipsTheRest() {
        let marks = [
            "u2": MemberMark(deliveredUpTo: 7, readUpTo: 7),   // read it
            "u3": MemberMark(deliveredUpTo: 7, readUpTo: 4),   // has it, unread
            "u4": MemberMark(deliveredUpTo: 4, readUpTo: 0),   // not reached yet
        ]
        let (read, delivered) = ReadByRoster.split(seq: 7, members: members,
                                                   marks: marks, ownUserId: "me")
        XCTAssertEqual(read.map(\.id), ["u2"])
        XCTAssertEqual(delivered.map(\.id), ["u3"])
    }

    /// The sender never lists themselves, whatever their own marks say.
    func testTheSenderIsNotListed() {
        let marks = ["me": MemberMark(deliveredUpTo: 9, readUpTo: 9)]
        let (read, delivered) = ReadByRoster.split(seq: 5, members: members,
                                                   marks: marks, ownUserId: "me")
        XCTAssertTrue(read.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
    }

    /// A member with no mark row yet has nothing, and is in neither list.
    func testAMemberWithNoMarksIsSkipped() {
        let (read, delivered) = ReadByRoster.split(seq: 1, members: members,
                                                   marks: [:], ownUserId: "me")
        XCTAssertTrue(read.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
    }

    func testEachListIsSortedByDisplayName() {
        let marks = [
            "u4": MemberMark(deliveredUpTo: 5, readUpTo: 5),
            "u2": MemberMark(deliveredUpTo: 5, readUpTo: 5),
            "u3": MemberMark(deliveredUpTo: 5, readUpTo: 5),
        ]
        let (read, _) = ReadByRoster.split(seq: 5, members: members,
                                           marks: marks, ownUserId: "me")
        XCTAssertEqual(read.map(\.displayName), ["Bob", "Charlie", "Dave"])
    }
}
