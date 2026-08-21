import XCTest
@testable import Msngr
import MsngrCore

/// Multi-select: what is in the selection, the counter, and whether "delete for
/// everyone" is available.
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
        XCTAssertFalse(MessageSelection.canDeleteForAll([]), "an empty selection has nothing to delete")
    }

    @MainActor
    func testDeleteFromMenuOpensSelectionWithConfirmation() {
        let model = ChatViewModel(chatId: "c")
        let a = msg("a", outgoing: true)

        model.beginSelection(with: a, confirmingDelete: true)
        XCTAssertTrue(model.selecting)
        XCTAssertTrue(model.confirmingDelete)
        XCTAssertTrue(model.selection.contains(a))

        model.toggleSelection(a)
        XCTAssertTrue(model.selecting, "selection mode remains")
        XCTAssertFalse(model.confirmingDelete)

        model.endSelection()
        XCTAssertFalse(model.selecting)
        XCTAssertTrue(model.selection.isEmpty)
    }

    func testCounterTitle() {
        XCTAssertEqual(MessageSelection.title(count: 1), NSString(format: String(localized: "%lld messages") as NSString, 1) as String)
        XCTAssertEqual(MessageSelection.title(count: 2), NSString(format: String(localized: "%lld messages") as NSString, 2) as String)
        XCTAssertEqual(MessageSelection.title(count: 4), NSString(format: String(localized: "%lld messages") as NSString, 4) as String)
        XCTAssertEqual(MessageSelection.title(count: 5), NSString(format: String(localized: "%lld messages") as NSString, 5) as String)
        XCTAssertEqual(MessageSelection.title(count: 11), NSString(format: String(localized: "%lld messages") as NSString, 11) as String)
        XCTAssertEqual(MessageSelection.title(count: 12), NSString(format: String(localized: "%lld messages") as NSString, 12) as String)
        XCTAssertEqual(MessageSelection.title(count: 21), NSString(format: String(localized: "%lld messages") as NSString, 21) as String)
        XCTAssertEqual(MessageSelection.title(count: 22), NSString(format: String(localized: "%lld messages") as NSString, 22) as String)
        XCTAssertEqual(MessageSelection.title(count: 25), NSString(format: String(localized: "%lld messages") as NSString, 25) as String)
        XCTAssertEqual(MessageSelection.title(count: 111), NSString(format: String(localized: "%lld messages") as NSString, 111) as String)
    }
}
