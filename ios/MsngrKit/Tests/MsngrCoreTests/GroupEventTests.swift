import XCTest
@testable import MsngrCore

final class GroupEventTests: XCTestCase {
    /// Sentences are compared through the module's catalog, so the test asserts
    /// which sentence was chosen in whatever language the host runs.
    private func s(_ key: String.LocalizationValue) -> String { CoreStrings.string(key) }

    func testRoundTrip() {
        let event = GroupEvent(verb: .added, actor: "Anna", member: "Boris", memberId: "u2")
        let decoded = GroupEvent.decode(event.encoded)
        XCTAssertEqual(decoded, event)
    }

    func testATitleWithPunctuationSurvives() {
        let event = GroupEvent(verb: .title, actor: "Anna", text: "Roof: \"house\", 2nd floor")
        XCTAssertEqual(GroupEvent.decode(event.encoded)?.text, "Roof: \"house\", 2nd floor")
    }

    func testOrdinaryTextIsNotAnEvent() {
        XCTAssertNil(GroupEvent.decode("identity_changed:u1"))
        XCTAssertNil(GroupEvent.decode("Hello"))
        XCTAssertNil(GroupEvent.decode(nil))
        // the marker without a payload behind it
        XCTAssertNil(GroupEvent.decode("group:"))
    }

    func testTheAuthorReadsTheirOwnAction() {
        let event = GroupEvent(verb: .title, actor: "Anna", text: "Roof")
        XCTAssertEqual(event.sentence(isOwn: true), s("You renamed the group to “\("Roof")”"))
        XCTAssertEqual(event.sentence(isOwn: false), s("\("Anna") renamed the group to “\("Roof")”"))
    }

    func testTheMemberItHappenedToReadsYou() {
        let event = GroupEvent(verb: .added, actor: "Anna", member: "Boris", memberId: "u2")
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u2"), s("\("Anna") added you"))
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u3"), s("\("Anna") added: \("Boris")"))
        XCTAssertEqual(event.sentence(isOwn: true), s("You added: \("Boris")"))
    }

    func testLeavingIsSpokenOfByName() {
        let event = GroupEvent(verb: .left, actor: "Boris")
        XCTAssertEqual(event.sentence(isOwn: false), s("\("Boris") left the group"))
        XCTAssertEqual(event.sentence(isOwn: true), s("You left the group"))
    }

    func testAdminRights() {
        let granted = GroupEvent(verb: .adminGranted, actor: "Anna", member: "Boris", memberId: "u2")
        XCTAssertEqual(granted.sentence(isOwn: false, ownUserId: "u2"),
                       s("\("Anna") made you an admin"))
        let revoked = GroupEvent(verb: .adminRevoked, actor: "Anna", member: "Boris", memberId: "u2")
        XCTAssertEqual(revoked.sentence(isOwn: false, ownUserId: "u3"),
                       s("\("Anna") revoked admin rights from: \("Boris")"))
    }

    func testDescriptionClearedReadsDifferently() {
        XCTAssertEqual(GroupEvent(verb: .description, actor: "Anna").sentence(isOwn: false),
                       s("\("Anna") changed the group description"))
        XCTAssertEqual(GroupEvent(verb: .descriptionCleared, actor: "Anna").sentence(isOwn: false),
                       s("\("Anna") removed the group description"))
    }

    /// A group event is service on the wire — no unread, no push — and still
    /// leaves a row, unlike every other service kind.
    func testItIsServiceButNotRowless() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(GroupEvent.kind))
        XCTAssertFalse(SyncEngine.rowlessKinds.contains(GroupEvent.kind))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains("reaction"))
    }
}
