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

    /// Исходящее видимо шире статуса; ширина баббла не схлопывается уже времени.
    func testBubbleNotNarrowerThanStatus() {
        let p = plan("!")
        XCTAssertGreaterThanOrEqual(p.bubbleFrame.width, p.statusWidth)
    }
}
