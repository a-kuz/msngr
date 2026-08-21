import XCTest
import MsngrCore
@testable import Msngr

/// What a forwarded message carries into the target chat: the content, the
/// quote preview, and the original author. Reactions stay in the source chat.
final class ForwardPayloadTests: XCTestCase {
    private func message() -> Message {
        var msg = Message(id: "m1", chatId: "c1", fromUserId: "author", sentAt: 100,
                          kind: .text, text: "hello", status: .sent, isOutgoing: false)
        msg.seq = 1
        msg.reactions = ["❤️": ["author", "me"]]
        return msg
    }

    func testCarriesContentAndAuthor() {
        let c = ChatViewModel.forwardPayload(message(), authorName: "Alice")
        XCTAssertEqual(c.kind, "text")
        XCTAssertEqual(c.text, "hello")
        XCTAssertEqual(c.fwd, ForwardInfo(fromUserId: "author", fromName: "Alice"))
    }

    /// The quote goes along as the preview it already is: the original may not
    /// exist in the target chat, and the preview needs nothing from it.
    func testCarriesTheQuotePreview() {
        var msg = message()
        msg.replyTo = ReplyPreview(seq: 5, authorId: "peer", text: "quoted", kind: "text")
        let c = ChatViewModel.forwardPayload(msg, authorName: "Alice")
        XCTAssertEqual(c.replyTo, msg.replyTo)
    }

    /// Forwarding a forward keeps the original author, not the middleman.
    func testReforwardKeepsTheOriginalAuthor() {
        var msg = message()
        msg.forward = ForwardInfo(fromUserId: "origin", fromName: "Bob")
        let c = ChatViewModel.forwardPayload(msg, authorName: "Alice")
        XCTAssertEqual(c.fwd, ForwardInfo(fromUserId: "origin", fromName: "Bob"))
    }

    func testCarriesMediaAndAlbum() {
        var msg = message()
        msg.kind = .album
        let item = MediaInfo(type: "photo", mediaId: "b1", key: "k", hash: "h", size: 1, mime: "image/jpeg")
        msg.album = [item, item]
        let c = ChatViewModel.forwardPayload(msg, authorName: "Alice")
        XCTAssertEqual(c.kind, "album")
        XCTAssertEqual(c.album?.count, 2)
    }
}
