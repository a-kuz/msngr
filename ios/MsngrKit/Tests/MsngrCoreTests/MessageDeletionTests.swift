import XCTest
@testable import MsngrCore

/// Правило «удалить у всех» одно на все клиенты: чужое сообщение сервер
/// тумбстоунит только администратору группы, в переписке — никому.
final class MessageDeletionTests: XCTestCase {
    private func message(id: String, outgoing: Bool) -> Message {
        Message(id: id, chatId: "c1", fromUserId: outgoing ? "me" : "peer", sentAt: 1,
                kind: .text, text: "t", status: .sent, isOutgoing: outgoing)
    }

    func testOwnMessagesCanGo() {
        XCTAssertTrue(MessageDeletion.canDeleteForAll([message(id: "a", outgoing: true)]))
    }

    func testForeignMessageCannot() {
        XCTAssertFalse(MessageDeletion.canDeleteForAll([message(id: "a", outgoing: false)]))
    }

    func testOneForeignInTheSelectionIsEnoughToRefuse() {
        XCTAssertFalse(MessageDeletion.canDeleteForAll([
            message(id: "a", outgoing: true),
            message(id: "b", outgoing: false),
        ]))
    }

    func testEmptySelectionHasNothingToDelete() {
        XCTAssertFalse(MessageDeletion.canDeleteForAll([]))
    }
}
