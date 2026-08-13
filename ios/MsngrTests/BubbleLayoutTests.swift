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
