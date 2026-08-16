import XCTest
@testable import MsngrCore

/// Notification content matrix: content kind x chat type x privacy setting.
final class NotificationContentTests: XCTestCase {

    private let direct = NotificationContentBuilder.ChatInfo(chatId: "c1", isGroup: false, title: nil)
    private let group = NotificationContentBuilder.ChatInfo(chatId: "c2", isGroup: true, title: "Team")
    private let sender = NotificationContentBuilder.SenderInfo(userId: "u1", displayName: "Anna", avatarId: "av1")

    private func payload(_ kind: String, text: String? = nil, fileName: String? = nil) -> ContentPayload {
        var c = ContentPayload(kind: kind)
        c.text = text
        if let fileName {
            var m = MediaInfo(type: "file", mediaId: "m1", key: "k", hash: "h", size: 10, mime: "application/pdf")
            m.name = fileName
            c.media = m
        }
        return c
    }

    private func build(_ p: ContentPayload, chat: NotificationContentBuilder.ChatInfo? = nil,
                       showsText: Bool = true, isDeleted: Bool = false) -> NotificationContent? {
        NotificationContentBuilder.build(payload: p, chat: chat ?? direct, sender: sender,
                                         showsMessageText: showsText, isDeleted: isDeleted)
    }

    // MARK: - 1:1

    func testDirectTextUsesSenderNameAndText() {
        let c = build(payload("text", text: "hello"))
        XCTAssertEqual(c?.title, "Anna")
        XCTAssertNil(c?.subtitle)
        XCTAssertEqual(c?.body, "hello")
        XCTAssertEqual(c?.threadIdentifier, "c1")
    }

    func testEmptyTextFallsBackToPlaceholder() {
        XCTAssertEqual(build(payload("text", text: nil))?.body, "Новое сообщение")
        XCTAssertEqual(build(payload("text", text: "   "))?.body, "Новое сообщение")
    }

    func testSenderWithoutNameFallsBackToAppName() {
        let anon = NotificationContentBuilder.SenderInfo(userId: "u9", displayName: " ")
        let c = NotificationContentBuilder.build(payload: payload("text", text: "knock"), chat: direct, sender: anon)
        XCTAssertEqual(c?.title, "Msngr")
    }

    // MARK: - Group

    func testGroupKeepsSenderInTitleAndGroupInSubtitle() {
        let c = build(payload("text", text: "hello everyone"), chat: group)
        XCTAssertEqual(c?.title, "Anna")
        XCTAssertEqual(c?.subtitle, "Team")
        XCTAssertEqual(c?.body, "hello everyone")
        XCTAssertEqual(c?.threadIdentifier, "c2")
    }

    func testGroupWithoutTitleGetsFallbackSubtitle() {
        let noName = NotificationContentBuilder.ChatInfo(chatId: "c3", isGroup: true, title: nil)
        XCTAssertEqual(build(payload("text", text: "x"), chat: noName)?.subtitle, "Группа")
    }

    // MARK: - Media

    func testMediaPlaceholders() {
        XCTAssertEqual(build(payload("photo"))?.body, "📷 Фото")
        XCTAssertEqual(build(payload("video"))?.body, "🎥 Видео")
        XCTAssertEqual(build(payload("voice"))?.body, "🎤 Голосовое сообщение")
        XCTAssertEqual(build(payload("album"))?.body, "🖼 Альбом")
        XCTAssertEqual(build(payload("contact"))?.body, "👤 Контакт")
        XCTAssertEqual(build(payload("file"))?.body, "📎 Файл")
    }

    func testFileUsesItsName() {
        XCTAssertEqual(build(payload("file", fileName: "estimate.pdf"))?.body, "📎 estimate.pdf")
    }

    func testMediaCaptionIsAppended() {
        XCTAssertEqual(build(payload("photo", text: "sunset"))?.body, "📷 Фото: sunset")
        XCTAssertEqual(build(payload("video", text: "from the sea"))?.body, "🎥 Видео: from the sea")
    }

    func testUnknownKindFallsBackToTextOrPlaceholder() {
        XCTAssertEqual(build(payload("sticker", text: "y"))?.body, "y")
        XCTAssertEqual(build(payload("sticker"))?.body, "Новое сообщение")
    }

    // MARK: - Silent kinds

    func testServiceKindsProduceNoNotification() {
        for kind in ["edit", "reaction", "disappearing", "system", "deleted"] {
            XCTAssertNil(build(payload(kind, text: "something")), "expected silence for \(kind)")
        }
    }

    func testDeletedMessageProducesNoNotification() {
        XCTAssertNil(build(payload("text", text: "there it was"), isDeleted: true))
    }

    // MARK: - Privacy

    func testHiddenTextKeepsNamesAndDropsContent() {
        let c = build(payload("text", text: "a secret"), chat: group, showsText: false)
        XCTAssertEqual(c?.title, "Anna")
        XCTAssertEqual(c?.subtitle, "Team")
        XCTAssertEqual(c?.body, "Новое сообщение")
    }

    func testHiddenTextHidesMediaPlaceholderToo() {
        XCTAssertEqual(build(payload("photo", text: "sunset"), showsText: false)?.body, "Новое сообщение")
    }

    func testPreferenceDefaultsToShowingText() {
        let defaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        XCTAssertTrue(NotificationPreferences.showsMessageText(in: defaults))
        NotificationPreferences.setShowsMessageText(false, in: defaults)
        XCTAssertFalse(NotificationPreferences.showsMessageText(in: defaults))
        NotificationPreferences.setShowsMessageText(true, in: defaults)
        XCTAssertTrue(NotificationPreferences.showsMessageText(in: defaults))
    }

    // MARK: - Truncation

    func testShortTextIsUntouched() {
        XCTAssertEqual(NotificationContentBuilder.truncate("short"), "short")
    }

    func testNewlinesCollapseToSpaces() {
        XCTAssertEqual(NotificationContentBuilder.truncate("two\nlines\n\nand more"), "two lines and more")
    }

    func testLongTextCutsOnWordBoundary() {
        let text = String(repeating: "word ", count: 60).trimmingCharacters(in: .whitespaces)
        let cut = NotificationContentBuilder.truncate(text)
        XCTAssertTrue(cut.hasSuffix("…"))
        XCTAssertLessThanOrEqual(cut.count, NotificationContentBuilder.textLimit + 1)
        XCTAssertTrue(cut.dropLast().hasSuffix("word"), "cut in the middle of a word: \(cut)")
        XCTAssertTrue(text.hasPrefix(String(cut.dropLast())))
    }

    func testTrailingPunctuationIsTrimmedBeforeEllipsis() {
        let text = String(repeating: "ab, ", count: 80)
        let cut = NotificationContentBuilder.truncate(text)
        XCTAssertTrue(cut.hasSuffix("ab…"), cut)
    }

    func testSingleLongWordCutsByLimit() {
        let word = String(repeating: "y", count: 400)
        let cut = NotificationContentBuilder.truncate(word)
        XCTAssertEqual(cut.count, NotificationContentBuilder.textLimit + 1)
        XCTAssertTrue(cut.hasSuffix("…"))
    }

    func testBodyOfLongMessageIsTruncated() {
        let text = String(repeating: "word ", count: 100)
        let body = build(payload("text", text: text))?.body ?? ""
        XCTAssertLessThanOrEqual(body.count, NotificationContentBuilder.textLimit + 1)
    }
}
