import XCTest
@testable import Msngr
import MsngrCore

/// Bulk copy: what a multi-select puts on the clipboard.
@MainActor
final class MessageClipboardTests: XCTestCase {
    private func msg(_ id: String, kind: MessageKind = .text, text: String? = nil) -> Message {
        Message(id: id, chatId: "c", fromUserId: "peer",
                sentAt: 1_700_000_000, kind: kind, text: text,
                status: .sent, isOutgoing: false)
    }

    func testOldestOnTop() {
        // the selection arrives in feed order, newest first
        let msgs = [msg("3", text: "third"), msg("2", text: "second"), msg("1", text: "first")]
        XCTAssertEqual(MessageClipboard.bulkText(msgs), "first\nsecond\nthird")
    }

    func testMediaFallsBackToPreviewLine() {
        let msgs = [msg("2", text: "after the photo"), msg("1", kind: .photo)]
        XCTAssertEqual(MessageClipboard.bulkText(msgs),
                       ChatViewModel.previewText(msg("1", kind: .photo)) + "\nafter the photo")
    }

    func testEmptyTextFallsBackToPreviewLine() {
        let msgs = [msg("2", text: "line"), msg("1", kind: .voice, text: "")]
        XCTAssertEqual(MessageClipboard.bulkText(msgs),
                       ChatViewModel.previewText(msg("1", kind: .voice)) + "\nline")
    }

    func testBulkCopyLandsOnThePasteboard() {
        UIPasteboard.general.string = ""
        MessageClipboard.copy([msg("2", text: "b"), msg("1", text: "a")])
        XCTAssertEqual(UIPasteboard.general.string, "a\nb")
    }
}
