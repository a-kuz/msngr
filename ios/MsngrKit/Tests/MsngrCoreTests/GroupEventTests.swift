import XCTest
@testable import MsngrCore

final class GroupEventTests: XCTestCase {
    /// Sentences are compared through the module's catalog, so the test asserts
    /// which sentence was chosen in whatever language the host runs.
    private func s(_ key: String.LocalizationValue) -> String { CoreStrings.string(key) }

    func testRoundTrip() {
        let event = GroupEvent(verb: .added, actor: "Аня", member: "Боря", memberId: "u2")
        let decoded = GroupEvent.decode(event.encoded)
        XCTAssertEqual(decoded, event)
    }

    func testATitleWithPunctuationSurvives() {
        let event = GroupEvent(verb: .title, actor: "Аня", text: "Крыша: «дом», 2 этаж")
        XCTAssertEqual(GroupEvent.decode(event.encoded)?.text, "Крыша: «дом», 2 этаж")
    }

    func testOrdinaryTextIsNotAnEvent() {
        XCTAssertNil(GroupEvent.decode("identity_changed:u1"))
        XCTAssertNil(GroupEvent.decode("Привет"))
        XCTAssertNil(GroupEvent.decode(nil))
        // the marker without a payload behind it
        XCTAssertNil(GroupEvent.decode("group:"))
    }

    func testTheAuthorReadsTheirOwnAction() {
        let event = GroupEvent(verb: .title, actor: "Аня", text: "Крыша")
        XCTAssertEqual(event.sentence(isOwn: true), s("You renamed the group to “\("Крыша")”"))
        XCTAssertEqual(event.sentence(isOwn: false), s("\("Аня") renamed the group to “\("Крыша")”"))
    }

    func testTheMemberItHappenedToReadsYou() {
        let event = GroupEvent(verb: .added, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u2"), s("\("Аня") added you"))
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u3"), s("\("Аня") added: \("Боря")"))
        XCTAssertEqual(event.sentence(isOwn: true), s("You added: \("Боря")"))
    }

    func testLeavingIsSpokenOfByName() {
        let event = GroupEvent(verb: .left, actor: "Боря")
        XCTAssertEqual(event.sentence(isOwn: false), s("\("Боря") left the group"))
        XCTAssertEqual(event.sentence(isOwn: true), s("You left the group"))
    }

    func testAdminRights() {
        let granted = GroupEvent(verb: .adminGranted, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(granted.sentence(isOwn: false, ownUserId: "u2"),
                       s("\("Аня") made you an admin"))
        let revoked = GroupEvent(verb: .adminRevoked, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(revoked.sentence(isOwn: false, ownUserId: "u3"),
                       s("\("Аня") revoked admin rights from: \("Боря")"))
    }

    func testDescriptionClearedReadsDifferently() {
        XCTAssertEqual(GroupEvent(verb: .description, actor: "Аня").sentence(isOwn: false),
                       s("\("Аня") changed the group description"))
        XCTAssertEqual(GroupEvent(verb: .descriptionCleared, actor: "Аня").sentence(isOwn: false),
                       s("\("Аня") removed the group description"))
    }

    /// A group event is service on the wire — no unread, no push — and still
    /// leaves a row, unlike every other service kind.
    func testItIsServiceButNotRowless() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(GroupEvent.kind))
        XCTAssertFalse(SyncEngine.rowlessKinds.contains(GroupEvent.kind))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains("reaction"))
    }
}
