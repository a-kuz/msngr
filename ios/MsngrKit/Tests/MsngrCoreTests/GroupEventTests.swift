import XCTest
@testable import MsngrCore

final class GroupEventTests: XCTestCase {
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
        XCTAssertEqual(event.sentence(isOwn: true), "Вы изменили название на «Крыша»")
        XCTAssertEqual(event.sentence(isOwn: false), "Аня изменил(а) название на «Крыша»")
    }

    func testTheMemberItHappenedToReadsVas() {
        let event = GroupEvent(verb: .added, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u2"), "Аня добавил(а) вас")
        XCTAssertEqual(event.sentence(isOwn: false, ownUserId: "u3"), "Аня добавил(а): Боря")
        XCTAssertEqual(event.sentence(isOwn: true), "Вы добавили: Боря")
    }

    func testLeavingIsSpokenOfByName() {
        let event = GroupEvent(verb: .left, actor: "Боря")
        XCTAssertEqual(event.sentence(isOwn: false), "Боря покинул(а) группу")
        XCTAssertEqual(event.sentence(isOwn: true), "Вы покинули группу")
    }

    func testAdminRights() {
        let granted = GroupEvent(verb: .adminGranted, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(granted.sentence(isOwn: false, ownUserId: "u2"),
                       "Аня назначил(а) вас администратором")
        let revoked = GroupEvent(verb: .adminRevoked, actor: "Аня", member: "Боря", memberId: "u2")
        XCTAssertEqual(revoked.sentence(isOwn: false, ownUserId: "u3"),
                       "Аня снял(а) права администратора: Боря")
    }

    func testDescriptionClearedReadsDifferently() {
        XCTAssertEqual(GroupEvent(verb: .description, actor: "Аня").sentence(isOwn: false),
                       "Аня изменил(а) описание группы")
        XCTAssertEqual(GroupEvent(verb: .descriptionCleared, actor: "Аня").sentence(isOwn: false),
                       "Аня удалил(а) описание группы")
    }

    /// A group event is service on the wire — no unread, no push — and still
    /// leaves a row, unlike every other service kind.
    func testItIsServiceButNotRowless() {
        XCTAssertTrue(SyncEngine.serviceKinds.contains(GroupEvent.kind))
        XCTAssertFalse(SyncEngine.rowlessKinds.contains(GroupEvent.kind))
        XCTAssertTrue(SyncEngine.rowlessKinds.contains("reaction"))
    }
}
