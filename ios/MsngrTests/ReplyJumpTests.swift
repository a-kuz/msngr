import XCTest
@testable import Msngr
import MsngrCore

/// Finding the original when jumping from a quote: the quote points at the server
/// msgId, while your own message sits in the feed under its clientMsgId.
final class ReplyJumpTests: XCTestCase {
    private func item(id: String, msgId: String?, outgoing: Bool) -> ChatFeedItem {
        var m = Message(id: id, chatId: "c", fromUserId: outgoing ? "me" : "peer",
                        sentAt: 1_700_000_000, kind: .text, text: id,
                        status: .sent, isOutgoing: outgoing)
        m.msgId = msgId
        m.clientMsgId = outgoing ? id : nil
        return .message(m, tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    private var feed: [ChatFeedItem] {
        [
            item(id: "local-1", msgId: "srv-9", outgoing: true),
            .dateSeparator(id: "date:x", label: "Сегодня"),
            item(id: "srv-4", msgId: "srv-4", outgoing: false),
        ]
    }

    func testFindsOwnMessageByServerId() {
        XCTAssertEqual(MessagesViewController.index(ofMsgId: "srv-9", in: feed), 0)
    }

    func testFindsOwnMessageByLocalId() {
        XCTAssertEqual(MessagesViewController.index(ofMsgId: "local-1", in: feed), 0)
    }

    func testFindsIncomingMessage() {
        XCTAssertEqual(MessagesViewController.index(ofMsgId: "srv-4", in: feed), 2)
    }

    func testMissingMessageMeansHistoryNotLoaded() {
        XCTAssertNil(MessagesViewController.index(ofMsgId: "srv-100", in: feed))
    }

    func testSeparatorIdIsNotAMessage() {
        XCTAssertNil(MessagesViewController.index(ofMsgId: "date:x", in: feed))
    }
}

/// The file name handed to QuickLook: the extension decides the type.
final class FilePreviewNameTests: XCTestCase {
    func testKeepsOriginalNameWithExtension() {
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "Договор.pdf", mime: "application/octet-stream",
                                            mediaId: "m1"),
            "Договор.pdf")
    }

    func testAddsExtensionFromMimeWhenNameHasNone() {
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "readme", mime: "text/plain", mediaId: "m1"),
            "readme.txt")
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "invoice", mime: "application/pdf", mediaId: "m1"),
            "invoice.pdf")
    }

    func testFallsBackToMediaId() {
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: nil, mime: "application/pdf", mediaId: "abc"),
            "abc.pdf")
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "  ", mime: nil, mediaId: ""),
            "file")
    }

    func testStripsPathSeparators() {
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "../../etc/passwd.txt", mime: nil, mediaId: "m1"),
            ".._.._etc_passwd.txt")
    }

    func testUnknownMimeLeavesNameAsIs() {
        XCTAssertEqual(
            FilePreviewName.previewFileName(name: "dump", mime: "application/x-nonexistent-xyz",
                                            mediaId: "m1"),
            "dump")
    }
}
