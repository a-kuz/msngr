import XCTest
@testable import MsngrCore

/// Hiding the contents of a request chat until it is accepted.
final class ChatPrivacyTests: XCTestCase {
    private func chat(isRequest: Bool, iAccepted: Bool, unread: Int = 0) -> Chat {
        var c = Chat(id: "direct:A:B", kind: .direct, title: nil, createdBy: "A", createdAt: 0)
        c.isRequest = isRequest
        c.iAccepted = iAccepted
        c.unreadCount = unread
        return c
    }

    func testRequestHidesContent() {
        XCTAssertTrue(ChatPrivacy.hidesContent(isRequest: true, iAccepted: false))
        XCTAssertTrue(ChatPrivacy.hidesContent(chat(isRequest: true, iAccepted: false)))
    }

    func testAcceptedChatShowsContent() {
        XCTAssertFalse(ChatPrivacy.hidesContent(isRequest: false, iAccepted: true))
        XCTAssertFalse(ChatPrivacy.hidesContent(chat(isRequest: false, iAccepted: true)))
        XCTAssertFalse(ChatPrivacy.hidesContent(nil))
    }

    /// The core rule: the preview carries no text before accept and the real text after it.
    func testPreviewHiddenUntilAccept() {
        XCTAssertEqual(ChatPrivacy.preview(isRequest: true, iAccepted: false, content: "Hi, it's me"),
                       ChatPrivacy.requestPlaceholder)
        XCTAssertEqual(ChatPrivacy.preview(isRequest: false, iAccepted: true, content: "Hi, it's me"),
                       "Hi, it's me")
    }

    /// A hidden chat with no text must not read as a chat with no messages.
    func testPreviewOfEmptyContent() {
        XCTAssertEqual(ChatPrivacy.preview(isRequest: true, iAccepted: false, content: nil),
                       ChatPrivacy.requestPlaceholder)
        XCTAssertNil(ChatPrivacy.preview(isRequest: false, iAccepted: true, content: nil))
    }

    func testUnreadHiddenUntilAccept() {
        XCTAssertEqual(ChatPrivacy.visibleUnread(isRequest: true, iAccepted: false, unreadCount: 3), 0)
        XCTAssertEqual(ChatPrivacy.visibleUnread(isRequest: false, iAccepted: true, unreadCount: 3), 3)
    }
}
