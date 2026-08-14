import XCTest
@testable import MsngrCore

/// Скрытие содержимого чата-заявки до принятия.
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

    /// Основное требование: до accept превью не несёт текста, после — несёт.
    func testPreviewHiddenUntilAccept() {
        XCTAssertEqual(ChatPrivacy.preview(isRequest: true, iAccepted: false, content: "Привет, это я"),
                       ChatPrivacy.requestPlaceholder)
        XCTAssertEqual(ChatPrivacy.preview(isRequest: false, iAccepted: true, content: "Привет, это я"),
                       "Привет, это я")
    }

    /// Пустой текст у скрытого чата не должен «просвечивать» как отсутствие сообщений.
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
