import XCTest
import MsngrCore
@testable import Msngr

/// Who is listed behind a non-anonymous poll: one section per chosen option in
/// the poll's own order, people by name, a voter the roster no longer knows
/// kept under their id.
final class PollVotersTests: XCTestCase {
    private let users = [
        User(id: "u1", username: "alfa", displayName: "Alice"),
        User(id: "u2", username: "bravo", displayName: "Bob"),
        User(id: "u3", username: "charlie", displayName: "Charlie"),
    ]
    private let poll = PollInfo(question: "Lunch?", options: ["Pizza", "Sushi", "Soup"],
                                multiple: true, anonymous: false)

    func testSectionsFollowThePollOrderAndSkipUnchosenOptions() {
        let sections = PollVoters.sections(
            poll: poll, votes: ["u1": [1], "u2": [1], "u3": [0]], users: users)
        XCTAssertEqual(sections.map(\.option), ["Pizza", "Sushi"])
        XCTAssertEqual(sections[0].entries.map(\.name), ["Charlie"])
        XCTAssertEqual(sections[1].entries.map(\.name), ["Alice", "Bob"])
    }

    /// A multiple-answer vote puts the same person under every option they chose.
    func testMultipleAnswersListThePersonInEachSection() {
        let sections = PollVoters.sections(
            poll: poll, votes: ["u1": [0, 2]], users: users)
        XCTAssertEqual(sections.map(\.option), ["Pizza", "Soup"])
        XCTAssertEqual(sections.flatMap { $0.entries.map(\.id) }, ["u1", "u1"])
    }

    /// A voter who left the group is listed under their id, not dropped: the
    /// count on the bubble and the people behind it must agree.
    func testUnknownVoterIsKept() {
        let sections = PollVoters.sections(
            poll: poll, votes: ["gone": [0], "u1": [0]], users: users)
        XCTAssertEqual(sections[0].entries.map(\.name).sorted(), ["Alice", "gone"])
    }
}
