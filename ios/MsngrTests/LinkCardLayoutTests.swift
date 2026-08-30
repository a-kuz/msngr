import XCTest
@testable import Msngr
import MsngrCore

/// The link card under a text bubble: where the plan puts it and when it
/// refuses to appear at all.
final class LinkCardLayoutTests: XCTestCase {
    private let width: CGFloat = 390

    private func message(_ text: String, preview: LinkPreview?) -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000, kind: .text, text: text,
                        status: .read, isOutgoing: true)
        m.seq = 1
        m.serverTs = 1_700_000_000
        m.linkPreview = preview
        return m
    }

    private func plan(_ msg: Message) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: msg, width: width, tightGap: false,
                          showTail: true, showName: false, authorName: nil)
    }

    private let card = LinkPreview(url: "https://www.example.com/post",
                                   title: "A page title",
                                   desc: "Two sentences about the page, short enough.")

    func testCardSitsUnderTheTextAndGrowsTheBubble() throws {
        let bare = plan(message("see https://www.example.com/post", preview: nil))
        let m = message("see https://www.example.com/post", preview: card)
        let p = plan(m)
        let lf = try XCTUnwrap(p.linkFrame)
        let tf = try XCTUnwrap(p.textFrame)
        XCTAssertGreaterThanOrEqual(lf.minY, tf.maxY)
        XCTAssertGreaterThan(p.cellHeight, bare.cellHeight)
        XCTAssertEqual(p.linkTitle, "A page title")
        XCTAssertEqual(p.linkHost, "example.com")
        XCTAssertEqual(p.linkURL, "https://www.example.com/post")
        // the bubble is wide enough for the whole card
        XCTAssertLessThanOrEqual(lf.maxX, p.bubbleFrame.width)
    }

    func testTimeMovesUnderTheCard() throws {
        let p = plan(message("hi https://example.com", preview: card))
        let lf = try XCTUnwrap(p.linkFrame)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, lf.maxY,
                                    "the card fills the bubble's bottom, the time goes below it")
    }

    func testTombstoneDropsTheCard() {
        var m = message("https://example.com", preview: card)
        m.deletedForAll = true
        XCTAssertNil(plan(m).linkFrame)
    }

    func testCardWithoutDescriptionIsLower() throws {
        let short = LinkPreview(url: "https://example.com", title: "t")
        let tall = plan(message("x https://example.com", preview: card))
        let low = plan(message("x https://example.com", preview: short))
        let lfTall = try XCTUnwrap(tall.linkFrame)
        let lfLow = try XCTUnwrap(low.linkFrame)
        XCTAssertLessThan(lfLow.height, lfTall.height)
    }

    func testReactionsLandBelowTheCard() throws {
        var m = message("hi https://example.com", preview: card)
        m.reactions = ["👍": ["u1"]]
        let p = plan(m)
        let lf = try XCTUnwrap(p.linkFrame)
        for chip in p.reactionsFrames {
            XCTAssertGreaterThanOrEqual(chip.frame.minY, lf.maxY,
                                        "a capsule may not overlap the card")
        }
    }
}
