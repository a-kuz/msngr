import XCTest
@testable import Msngr
import MsngrCore

/// Мультивыбор: состав выбора, счётчик и доступность «удалить у всех».
final class MessageSelectionTests: XCTestCase {
    private func msg(_ id: String, outgoing: Bool) -> Message {
        Message(id: id, chatId: "c", fromUserId: outgoing ? "me" : "peer",
                sentAt: 1_700_000_000, kind: .text, text: id,
                status: .sent, isOutgoing: outgoing)
    }

    func testToggleAddsAndRemoves() {
        let a = msg("a", outgoing: true)
        var selection = MessageSelection()

        selection.toggle(a)
        XCTAssertTrue(selection.contains(a))
        XCTAssertEqual(selection.count, 1)

        selection.toggle(a)
        XCTAssertFalse(selection.contains(a))
        XCTAssertTrue(selection.isEmpty)
    }

    func testMessagesKeepFeedOrder() {
        let msgs = [msg("c", outgoing: true), msg("b", outgoing: false), msg("a", outgoing: true)]
        var selection = MessageSelection()
        selection.select(msgs[2])
        selection.select(msgs[0])

        XCTAssertEqual(selection.messages(in: msgs).map(\.id), ["c", "a"])
    }

    func testDeleteForAllOnlyWhenEveryMessageIsMine() {
        let mine = msg("m1", outgoing: true)
        let mine2 = msg("m2", outgoing: true)
        let theirs = msg("p1", outgoing: false)

        XCTAssertTrue(MessageSelection.canDeleteForAll([mine, mine2]))
        XCTAssertFalse(MessageSelection.canDeleteForAll([mine, theirs]))
        XCTAssertFalse(MessageSelection.canDeleteForAll([theirs]))
        XCTAssertFalse(MessageSelection.canDeleteForAll([]), "пустой выбор нечего удалять")
    }

    /// «Удалить» из меню сообщения открывает выбор с этим сообщением и
    /// подтверждением внизу; снятие выбора подтверждать больше нечего.
    @MainActor
    func testDeleteFromMenuOpensSelectionWithConfirmation() {
        let model = ChatViewModel(chatId: "c")
        let a = msg("a", outgoing: true)

        model.beginSelection(with: a, confirmingDelete: true)
        XCTAssertTrue(model.selecting)
        XCTAssertTrue(model.confirmingDelete)
        XCTAssertTrue(model.selection.contains(a))

        model.toggleSelection(a)
        XCTAssertTrue(model.selecting, "режим выбора остаётся")
        XCTAssertFalse(model.confirmingDelete)

        model.endSelection()
        XCTAssertFalse(model.selecting)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testCounterTitle() {
        XCTAssertEqual(MessageSelection.title(count: 1), "1 сообщение")
        XCTAssertEqual(MessageSelection.title(count: 2), "2 сообщения")
        XCTAssertEqual(MessageSelection.title(count: 4), "4 сообщения")
        XCTAssertEqual(MessageSelection.title(count: 5), "5 сообщений")
        XCTAssertEqual(MessageSelection.title(count: 11), "11 сообщений")
        XCTAssertEqual(MessageSelection.title(count: 12), "12 сообщений")
        XCTAssertEqual(MessageSelection.title(count: 21), "21 сообщение")
        XCTAssertEqual(MessageSelection.title(count: 22), "22 сообщения")
        XCTAssertEqual(MessageSelection.title(count: 25), "25 сообщений")
        XCTAssertEqual(MessageSelection.title(count: 111), "111 сообщений")
    }
}
