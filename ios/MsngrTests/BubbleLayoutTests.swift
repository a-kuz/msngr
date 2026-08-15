import XCTest
@testable import Msngr
import MsngrCore

/// Проверка трёх случаев размещения времени в баббле (эталон — Telegram).
final class BubbleLayoutTests: XCTestCase {
    private let width: CGFloat = 390 // iPhone логическая ширина

    private func outgoing(_ text: String) -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000, kind: .text, text: text,
                        status: .read, isOutgoing: true)
        m.seq = 1
        m.serverTs = 1_700_000_000
        return m
    }

    private func plan(_ text: String) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: outgoing(text), width: width, tightGap: false,
                          showTail: true, showName: false, authorName: nil)
    }

    /// Случай 1: короткий текст в одну строку — время inline в той же строке.
    func testShortTextTimeInline() {
        let p = plan("Привет")
        let tf = try! XCTUnwrap(p.textFrame)
        // статус на той же строке: его верх примерно на уровне последней строки текста
        XCTAssertLessThan(p.statusFrame.minY, tf.maxY,
                          "короткий текст: время должно быть inline, не ниже текста")
        // и правее текста
        XCTAssertGreaterThan(p.statusFrame.minX, tf.minX)
    }

    /// Случай 2: длинная одиночная строка, занимающая почти всю ширину, —
    /// время выталкивается (pushout) на отдельную строку ниже.
    func testLongLineTimePushedToNewLine() {
        // длинная фраза, которая укладывается в ширину баббла, но без места под время
        let p = plan("Время уже не вместе с первой строкой а на новой строке ниже")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
            "длинная строка без места: время должно уйти на новую строку под текстом")
        // высота ячейки учитывает добавленную строку статуса
        XCTAssertGreaterThan(p.cellHeight, tf.maxY)
    }

    /// Случай 3: многострочный текст, у последней строки есть свободное место —
    /// время садится в конец последней строки, не на новую.
    func testMultilineShortLastLineTimeInline() {
        // длинный текст → несколько строк, последняя короткая («хвост»)
        let p = plan("Время уже не вместе с первой строкой и не на новой строке. А вместе с последней")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThan(tf.height, 30, "ожидается многострочный текст")
        // статус в пределах последней строки, не ниже текста
        XCTAssertLessThan(p.statusFrame.minY, tf.maxY,
            "у короткой последней строки время должно быть inline")
    }

    /// Медиа без подписи — время в капсуле-оверлее поверх изображения.
    func testMediaStatusOverlay() {
        var m = outgoing("")
        m.text = nil
        m.kind = .photo
        var media = MediaInfo(type: "photo", mediaId: "x", key: "k", hash: "h", size: 1, mime: "image/jpeg")
        media.w = 1000; media.h = 800
        m.media = media
        let p = BubbleLayout.plan(for: m, width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil)
        XCTAssertTrue(p.statusOnMedia, "статус на фото без подписи — оверлей-капсула")
        let mf = try! XCTUnwrap(p.mediaFrame)
        // капсула в правом нижнем углу изображения
        XCTAssertGreaterThan(p.statusFrame.maxY, mf.midY)
        XCTAssertGreaterThan(p.statusFrame.minX, mf.midX)
    }

    private func withReactions(_ text: String, _ reactions: [String: [String]]) -> BubbleLayoutPlan {
        var m = outgoing(text)
        m.reactions = reactions
        return BubbleLayout.plan(for: m, width: width, tightGap: false,
                                 showTail: true, showName: false, authorName: nil)
    }

    /// Короткий текст: текст + реакция + время помещаются в одну строку.
    func testShortTextReactionAndTimeOnSameLine() {
        let p = withReactions("Ок", ["👍": ["u1"]])
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        let tf = try! XCTUnwrap(p.textFrame)
        // капсула справа от текста, время справа от капсулы, всё на одной линии
        XCTAssertGreaterThan(chip.frame.minX, tf.minX)
        XCTAssertGreaterThan(p.statusFrame.minX, chip.frame.minX)
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 6,
                          "время и реакция должны быть на одной линии")
    }

    /// Многострочный текст с реакцией: время НЕ на линии последней строки текста,
    /// а на линии реакций.
    func testTimeMovesToReactionRowForMultilineText() {
        let p = withReactions("Довольно длинное сообщение, которое точно занимает несколько строк подряд",
                              ["😂": ["u1", "u2"], "🔥": ["u3"]])
        let tf = try! XCTUnwrap(p.textFrame)
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
            "время не должно оставаться в последней строке текста при наличии реакций")
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 8,
            "время должно стоять на линии реакций")
        XCTAssertGreaterThan(p.statusFrame.minX, chip.frame.maxX,
            "время правее капсул реакций")
    }

    /// Много реакций — переносятся на несколько рядов, все внутри баббла.
    func testManyReactionsWrapToMultipleRows() {
        let emojis = ["😂", "🔥", "❤️", "👍", "😮", "😢", "🎉", "🙏", "👏", "💯"]
        var reactions: [String: [String]] = [:]
        for (i, e) in emojis.enumerated() { reactions[e] = ["u\(i)"] }
        let p = withReactions("Текст", reactions)
        XCTAssertEqual(p.reactionsFrames.count, emojis.count)
        let rows = Set(p.reactionsFrames.map { Int($0.frame.minY.rounded()) })
        XCTAssertGreaterThan(rows.count, 1, "капсулы должны переноситься на новые ряды")
        for r in p.reactionsFrames {
            XCTAssertLessThanOrEqual(r.frame.maxX, p.bubbleFrame.width,
                                     "капсула не должна вылезать за баббл")
        }
        XCTAssertLessThanOrEqual(p.statusFrame.maxX, p.bubbleFrame.width)
    }

    /// Реакция не должна смещать время и галочки: отступы статуса от правого
    /// и нижнего края баббла те же, что и у баббла без реакций.
    func testReactionKeepsStatusInsetsOfPlainBubble() {
        let cases: [(name: String, text: String, reactions: [String: [String]])] = [
            ("короткий текст, одна реакция", "Ок", ["👍": ["u1"]]),
            ("многострочный текст, две реакции",
             "Довольно длинное сообщение, которое точно занимает несколько строк подряд",
             ["😂": ["u1", "u2"], "🔥": ["u3"]]),
            ("реакции в несколько рядов", "Текст",
             ["😂": ["u1"], "🔥": ["u2"], "❤️": ["u3"], "👍": ["u4"], "😮": ["u5"],
              "😢": ["u6"], "🎉": ["u7"], "🙏": ["u8"], "👏": ["u9"], "💯": ["u10"]]),
        ]
        for c in cases {
            let plain = plan(c.text)
            let withR = withReactions(c.text, c.reactions)
            XCTAssertEqual(rightInset(plain), rightInset(withR), accuracy: 0.5,
                           "\(c.name): отступ времени справа")
            XCTAssertEqual(bottomInset(plain), bottomInset(withR), accuracy: 0.5,
                           "\(c.name): отступ времени снизу")
            XCTAssertEqual(bottomInset(withR), BubbleLayout.vPadding, accuracy: 0.5,
                           "\(c.name): время стоит на нижнем паддинге баббла")
        }
    }

    private func rightInset(_ p: BubbleLayoutPlan) -> CGFloat { p.bubbleFrame.width - p.statusFrame.maxX }
    private func bottomInset(_ p: BubbleLayoutPlan) -> CGFloat { p.bubbleFrame.height - p.statusFrame.maxY }

    /// Исходящее видимо шире статуса; ширина баббла не схлопывается уже времени.
    func testBubbleNotNarrowerThanStatus() {
        let p = plan("!")
        XCTAssertGreaterThanOrEqual(p.bubbleFrame.width, p.statusWidth)
    }

    /// Обычное текстовое сообщение без реакций даёт видимый баббл:
    /// высота положительная и не меньше строки текста с вертикальными паддингами.
    func testPlainTextWithoutReactionsHasVisibleBubble() {
        let p = plan("Test message 1")
        XCTAssertGreaterThan(p.bubbleFrame.height, 0)
        XCTAssertGreaterThanOrEqual(
            p.bubbleFrame.height,
            ceil(BubbleLayout.textFont.lineHeight) + 2 * BubbleLayout.vPadding,
            "баббл не ниже строки текста с паддингами")
        XCTAssertGreaterThan(p.cellHeight, p.bubbleFrame.height - 1)
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThan(tf.width, 0)
        XCTAssertGreaterThan(tf.height, 0)
    }

    /// Короткий текст: зазор между текстом и временем фиксированный,
    /// время прижато к правому краю баббла.
    func testShortTextStatusPinnedToBubbleRightEdge() {
        let p = plan("Высев")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertEqual(p.statusFrame.maxX, p.bubbleFrame.width - BubbleLayout.hPadding,
                       accuracy: 0.5, "время прижато к правому краю баббла")
        XCTAssertEqual(p.statusFrame.minX - tf.maxX, 6, accuracy: 1.5,
                       "зазор между текстом и временем фиксированный")
    }

    // MARK: - Зазор между бабблами

    private func gapPlan(tightGap: Bool) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: outgoing("Привет"), width: width, tightGap: tightGap,
                          showTail: true, showName: false, authorName: nil)
    }

    /// Продолжение серии — зазор groupGap, разрыв серии — normalGap;
    /// сам баббл при этом одинаковой высоты.
    func testCellHeightTightVersusNormalGap() {
        let tight = gapPlan(tightGap: true)
        let normal = gapPlan(tightGap: false)
        XCTAssertEqual(tight.bubbleFrame.height, normal.bubbleFrame.height,
                       "зазор не должен менять высоту самого баббла")
        XCTAssertEqual(tight.cellHeight - tight.bubbleFrame.height, BubbleLayout.groupGap, accuracy: 0.01)
        XCTAssertEqual(normal.cellHeight - normal.bubbleFrame.height, BubbleLayout.normalGap, accuracy: 0.01)
        XCTAssertEqual(normal.cellHeight - tight.cellHeight,
                       BubbleLayout.normalGap - BubbleLayout.groupGap, accuracy: 0.01)
    }

    /// Зазор лежит над бабблом: ячейка перевёрнута, её верх на экране —
    /// граница с сообщением выше, о котором и говорит tightGap.
    func testGapSitsAboveBubble() {
        XCTAssertEqual(gapPlan(tightGap: true).bubbleFrame.minY, BubbleLayout.groupGap, accuracy: 0.01)
        XCTAssertEqual(gapPlan(tightGap: false).bubbleFrame.minY, BubbleLayout.normalGap, accuracy: 0.01)
        // баббл прижат к низу ячейки: под ним пустого места не остаётся
        for tight in [true, false] {
            let p = gapPlan(tightGap: tight)
            XCTAssertEqual(p.bubbleFrame.maxY, p.cellHeight, accuracy: 0.01)
        }
    }

    // MARK: - Мини-маркдаун

    /// Блок кода занимает больше места, чем тот же текст без разметки:
    /// подложка с отступами плюс время на своей строке.
    func testCodeBlockBubbleIsTallerThanPlainText() {
        let plain = plan("let a = 1")
        let code = plan("```\nlet a = 1\n```")
        XCTAssertGreaterThan(code.bubbleFrame.height, plain.bubbleFrame.height,
                             "баббл с блоком кода обязан быть выше")
        XCTAssertGreaterThan(code.cellHeight, plain.cellHeight)
    }

    /// Многострочный блок кода выше однострочного минимум на строку.
    func testMultilineCodeBlockGrowsWithLines() {
        let one = plan("```\nlet a = 1\n```")
        let three = plan("```\nlet a = 1\nlet b = 2\nlet c = 3\n```")
        XCTAssertGreaterThan(three.bubbleFrame.height - one.bubbleFrame.height,
                             2 * BubbleLayout.textFont.lineHeight - 6)
    }

    /// После блока кода время не садится в последнюю строку.
    func testStatusBelowCodeBlock() {
        let p = plan("```\nx\n```")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
                                    "время должно уйти под подложку кода")
    }

    /// Маркеры разметки в баббл не попадают, начертания применены.
    func testMarkersAreNotRendered() {
        let p = plan("**жирный** и `код`")
        let attr = try! XCTUnwrap(p.text)
        XCTAssertEqual(attr.string, "жирный и код")
        let boldFont = attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        let codeFont = attr.attribute(.font, at: attr.length - 1, effectiveRange: nil) as? UIFont
        XCTAssertEqual(codeFont, MessageMarkdownRenderer.codeFont)
    }

    /// Ссылка получает атрибут .msngrLink — по нему ячейка открывает браузер.
    func testLinkAttributePresent() {
        let attr = try! XCTUnwrap(plan("жми https://example.com сюда").text)
        var found: URL?
        attr.enumerateAttribute(.msngrLink, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if let url = value as? URL { found = url }
        }
        XCTAssertEqual(found, URL(string: "https://example.com"))
    }

    /// Замер в плане совпадает с замером того же attributed-текста:
    /// рисуется ровно то, что померено.
    func testTextFrameMatchesMeasuredSize() {
        for source in ["Привет", "**жирный** текст", "```\nlet a = 1\nlet b = 22\n```",
                       "текст\n```\ncode\n```\nхвост"] {
            let p = plan(source)
            let tf = try! XCTUnwrap(p.textFrame)
            let attr = try! XCTUnwrap(p.text)
            let maxContent = floor(width * Theme.bubbleMaxWidthRatio) - 2 * BubbleLayout.hPadding
            let size = BubbleLayout.textSize(attr, maxWidth: maxContent)
            XCTAssertEqual(tf.width, size.width, accuracy: 0.01, source)
            XCTAssertEqual(tf.height, size.height, accuracy: 0.01, source)
        }
    }

    // MARK: - Реакции на voice/file

    private func mediaMessage(_ kind: MessageKind, reactions: [String: [String]]) -> Message {
        var m = outgoing("")
        m.text = nil
        m.kind = kind
        var media = MediaInfo(type: kind == .voice ? "voice" : "file", mediaId: "x",
                              key: "k", hash: "h", size: 1,
                              mime: kind == .voice ? "audio/mp4" : "application/octet-stream")
        media.dur = 3
        m.media = media
        m.reactions = reactions
        return m
    }

    private func mediaPlan(_ kind: MessageKind, _ reactions: [String: [String]]) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: mediaMessage(kind, reactions: reactions), width: width,
                          tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    /// Внутри баббла: ни одна капсула и статус не выходят за его край.
    private func assertReactionsInsideBubble(_ p: BubbleLayoutPlan,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for r in p.reactionsFrames {
            XCTAssertLessThanOrEqual(r.frame.maxY, p.bubbleFrame.height,
                                     "капсула не должна вылезать за низ баббла", file: file, line: line)
            XCTAssertLessThanOrEqual(r.frame.maxX, p.bubbleFrame.width,
                                     "капсула не должна вылезать за правый край", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(p.statusFrame.maxY, p.bubbleFrame.height, file: file, line: line)
    }

    /// Голосовое с одной реакцией: баббл выше, чем без реакций, капсула — рядом
    /// под волной, время на линии ряда, всё внутри баббла.
    func testVoiceBubbleGrowsForOneReaction() {
        let base = mediaPlan(.voice, [:])
        let p = mediaPlan(.voice, ["👍": ["u1", "u2"]])
        XCTAssertGreaterThan(p.bubbleFrame.height, base.bubbleFrame.height,
                             "баббл с реакцией обязан быть выше")
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        let vf = try! XCTUnwrap(p.voiceFrame)
        XCTAssertGreaterThanOrEqual(chip.frame.minY, vf.maxY, "капсула под волной")
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 8,
                          "время на линии ряда реакций")
        assertReactionsInsideBubble(p)
    }

    /// Голосовое с пятью реакциями: баббл выше минимум на ряд капсул, все внутри.
    func testVoiceBubbleGrowsForFiveReactions() {
        let base = mediaPlan(.voice, [:])
        let reactions = ["😂": ["u1", "u2"], "🔥": ["u3", "u4"], "❤️": ["u5", "u6"],
                         "👍": ["u7", "u8"], "💯": ["u9", "u10"]]
        let p = mediaPlan(.voice, reactions)
        XCTAssertEqual(p.reactionsFrames.count, 5)
        XCTAssertGreaterThanOrEqual(p.bubbleFrame.height - base.bubbleFrame.height, 26,
                                    "рост баббла не меньше высоты ряда капсул")
        let vf = try! XCTUnwrap(p.voiceFrame)
        for r in p.reactionsFrames {
            XCTAssertGreaterThanOrEqual(r.frame.minY, vf.maxY, "капсулы под волной")
        }
        assertReactionsInsideBubble(p)
    }

    // MARK: - Цитата ответа (reply-плашка)

    private func replyPlan(replyTo: ReplyPreview, replyAuthorName: String?) -> BubbleLayoutPlan {
        var m = outgoing("Текст ответа")
        m.replyTo = replyTo
        return BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                 showName: false, authorName: nil, replyAuthorName: replyAuthorName)
    }

    /// Автор цитаты — переданное имя (резолвится вызывающей стороной из user/participants),
    /// а не сырой userId из replyTo.authorId.
    func testReplyAuthorUsesResolvedName() {
        let reply = ReplyPreview(msgId: "m1", authorId: "01KZXED9XMFKTKYDBVH30C", text: "привет", kind: "text")
        let p = replyPlan(replyTo: reply, replyAuthorName: "Аня")
        XCTAssertEqual(p.replyAuthor, "Аня")
        XCTAssertNotEqual(p.replyAuthor, reply.authorId, "в цитате не должен показываться сырой userId")
    }

    /// Ответ на своё сообщение — автор цитаты «Вы».
    func testReplyAuthorShowsYouForOwnMessage() {
        let reply = ReplyPreview(msgId: "m1", authorId: "me", text: "моё сообщение", kind: "text")
        let p = replyPlan(replyTo: reply, replyAuthorName: "Вы")
        XCTAssertEqual(p.replyAuthor, "Вы")
    }

    /// Без цитаты replyAuthor не выставляется, даже если имя было бы известно.
    func testReplyAuthorNilWithoutReplyTo() {
        let p = BubbleLayout.plan(for: outgoing("без ответа"), width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil,
                                  replyAuthorName: "Аня")
        XCTAssertNil(p.replyAuthor)
    }

    /// Превью цитаты для нетекстовых сообщений — иконка и подпись, не пустая строка.
    func testReplyPreviewTextForEachKind() {
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "Фото", kind: "photo")), "📷 Фото")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "Видео", kind: "video")), "🎥 Видео")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "Голосовое сообщение", kind: "voice")),
            "🎤 Голосовое сообщение")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "Договор.pdf", kind: "file")), "📎 Договор.pdf")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "", kind: "album")), "🖼 Альбом")
    }

    /// Пустой сохранённый текст (файл без имени, отсутствующее превью) — заглушка,
    /// а не пустая строка в баббле.
    func testReplyPreviewTextFallsBackWhenEmpty() {
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "", kind: "file")), "📎 Файл")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(msgId: "1", authorId: "u", text: "", kind: "text")), "Сообщение")
    }

    /// План собирает итоговую строку превью через replyPreviewText, а не сырой replyTo.text.
    func testPlanReplyTextUsesPreviewMapping() {
        let reply = ReplyPreview(msgId: "1", authorId: "peer", text: "Видео", kind: "video")
        let p = replyPlan(replyTo: reply, replyAuthorName: "Петя")
        XCTAssertEqual(p.replyText, "🎥 Видео")
    }

    /// Файл с реакциями: те же гарантии, что и для голосового.
    func testFileBubbleGrowsForReactions() {
        let base = mediaPlan(.file, [:])
        let one = mediaPlan(.file, ["👍": ["u1", "u2"]])
        let five = mediaPlan(.file, ["😂": ["u1", "u2"], "🔥": ["u3", "u4"], "❤️": ["u5", "u6"],
                                     "👍": ["u7", "u8"], "💯": ["u9", "u10"]])
        XCTAssertGreaterThan(one.bubbleFrame.height, base.bubbleFrame.height)
        XCTAssertGreaterThanOrEqual(five.bubbleFrame.height - base.bubbleFrame.height, 26)
        for p in [one, five] {
            let vf = try! XCTUnwrap(p.voiceFrame)
            for r in p.reactionsFrames {
                XCTAssertGreaterThanOrEqual(r.frame.minY, vf.maxY, "капсулы под плашкой файла")
            }
            assertReactionsInsideBubble(p)
        }
    }
}
