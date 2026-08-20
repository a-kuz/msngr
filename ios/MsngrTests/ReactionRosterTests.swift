import XCTest
import MsngrCore
@testable import Msngr

/// Who is listed behind the reaction capsules: grouping, order of the
/// sections, order of the people, and what happens to a reactor the roster no
/// longer knows.
final class ReactionRosterTests: XCTestCase {
    private let users = [
        User(id: "u1", username: "alfa", displayName: "Алиса"),
        User(id: "u2", username: "bravo", displayName: "Боб"),
        User(id: "u3", username: "charlie", displayName: "Чарли"),
    ]

    func testGroupsByEmojiWithCountsDescending() {
        let sections = ReactionRoster.sections(
            reactions: ["👍": ["u1"], "❤️": ["u2", "u3"]], users: users)
        XCTAssertEqual(sections.map(\.emoji), ["❤️", "👍"])
        XCTAssertEqual(sections[0].entries.map(\.name), ["Боб", "Чарли"])
    }

    /// The capsule that was tapped opens its own people first, whatever its count.
    func testTappedEmojiComesFirst() {
        let sections = ReactionRoster.sections(
            reactions: ["👍": ["u1"], "❤️": ["u2", "u3"]], users: users, tapped: "👍")
        XCTAssertEqual(sections.map(\.emoji), ["👍", "❤️"])
    }

    /// People stand in the order they reacted — the stored array keeps arrival order.
    func testPeopleKeepArrivalOrder() {
        let sections = ReactionRoster.sections(
            reactions: ["🔥": ["u3", "u1", "u2"]], users: users)
        XCTAssertEqual(sections[0].entries.map(\.id), ["u3", "u1", "u2"])
    }

    /// A reactor who left the group is listed under their id, not dropped: the
    /// count on the capsule and the people behind it must agree.
    func testUnknownReactorIsKept() {
        let sections = ReactionRoster.sections(
            reactions: ["❤️": ["u1", "gone"]], users: users)
        XCTAssertEqual(sections[0].entries.map(\.name), ["Алиса", "gone"])
    }

    /// Equal counts fall back to the emoji itself, so redraws never shuffle.
    func testTiesAreStable() {
        let sections = ReactionRoster.sections(
            reactions: ["🔥": ["u1"], "❤️": ["u2"], "👍": ["u3"]], users: users)
        XCTAssertEqual(sections.map(\.emoji), sections.map(\.emoji).sorted())
    }
}
