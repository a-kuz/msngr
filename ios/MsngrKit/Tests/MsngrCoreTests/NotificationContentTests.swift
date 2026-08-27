import XCTest
@testable import MsngrCore

/// Notification content matrix: content kind x chat type x privacy setting.
final class NotificationContentTests: XCTestCase {
    /// Bodies are compared through the module's catalog, in whatever language
    /// the host runs.
    private func s(_ key: String.LocalizationValue) -> String { CoreStrings.string(key) }


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

    // MARK: - Reactions

    func testReactionQuotesTheTargetText() {
        let c = NotificationContentBuilder.reactionContent(
            emoji: "❤️", targetText: "see you at five", targetKind: "text",
            chat: direct, sender: sender)
        XCTAssertEqual(c.title, "Anna")
        XCTAssertNil(c.subtitle)
        XCTAssertEqual(c.body, s("Reacted ❤️ to “see you at five”"))
        XCTAssertEqual(c.threadIdentifier, "c1")
    }

    func testReactionToMediaUsesThePlaceholder() {
        let c = NotificationContentBuilder.reactionContent(
            emoji: "👍", targetText: nil, targetKind: "photo",
            chat: group, sender: sender)
        XCTAssertEqual(c.title, "Anna")
        XCTAssertEqual(c.subtitle, "Team")
        XCTAssertEqual(c.body, s("Reacted 👍 to “\(s("📷 Photo"))”"))
    }

    func testReactionHidesTextWhenThePrivacySettingAsks() {
        let c = NotificationContentBuilder.reactionContent(
            emoji: "🔥", targetText: "secret", targetKind: "text",
            chat: direct, sender: sender, showsMessageText: false)
        XCTAssertEqual(c.body, s("Reacted 🔥 to your message"))
        XCTAssertFalse(c.body.contains("secret"))
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
        XCTAssertEqual(build(payload("text", text: nil))?.body, NotificationContentBuilder.hiddenTextBody)
        XCTAssertEqual(build(payload("text", text: "   "))?.body, NotificationContentBuilder.hiddenTextBody)
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
        XCTAssertEqual(build(payload("text", text: "x"), chat: noName)?.subtitle, s("Group"))
    }

    // MARK: - Media

    func testMediaPlaceholders() {
        XCTAssertEqual(build(payload("photo"))?.body, s("📷 Photo"))
        XCTAssertEqual(build(payload("video"))?.body, s("🎥 Video"))
        XCTAssertEqual(build(payload("voice"))?.body, s("🎤 Voice message"))
        XCTAssertEqual(build(payload("album"))?.body, s("🖼 Album"))
        XCTAssertEqual(build(payload("contact"))?.body, s("👤 Contact"))
        XCTAssertEqual(build(payload("file"))?.body, "📎 " + s("File"))
    }

    func testFileUsesItsName() {
        XCTAssertEqual(build(payload("file", fileName: "estimate.pdf"))?.body, "📎 estimate.pdf")
    }

    func testMediaCaptionIsAppended() {
        XCTAssertEqual(build(payload("photo", text: "sunset"))?.body, s("📷 Photo") + ": sunset")
        XCTAssertEqual(build(payload("video", text: "from the sea"))?.body, s("🎥 Video") + ": from the sea")
    }

    func testUnknownKindFallsBackToTextOrPlaceholder() {
        XCTAssertEqual(build(payload("sticker", text: "y"))?.body, "y")
        XCTAssertEqual(build(payload("sticker"))?.body, NotificationContentBuilder.hiddenTextBody)
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
        XCTAssertEqual(c?.body, NotificationContentBuilder.hiddenTextBody)
    }

    func testHiddenTextHidesMediaPlaceholderToo() {
        XCTAssertEqual(build(payload("photo", text: "sunset"), showsText: false)?.body,
                       NotificationContentBuilder.hiddenTextBody)
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
