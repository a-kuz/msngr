import XCTest
@testable import MsngrCore

/// The mention token `[@Name](user:<id>)`: parsing, the visible strip for
/// previews, and how it coexists with the rest of the dialect.
final class MentionMarkdownTests: XCTestCase {

    private func spans(_ source: String) -> [MarkdownSpan] {
        guard case .paragraph(let spans)? = MessageMarkdown.parse(source).first else { return [] }
        return spans
    }

    func testATokenBecomesAMentionSpan() {
        let s = spans("привет [@Bravo Service](user:01M0JWM3) как дела")
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s[1].text, "@Bravo Service")
        XCTAssertTrue(s[1].style.contains(.mention))
        XCTAssertEqual(s[1].link, "user:01M0JWM3")
        XCTAssertEqual(s[0].text, "привет ")
        XCTAssertEqual(s[2].text, " как дела")
    }

    func testAMentionInsideBoldKeepsBothStyles() {
        let s = spans("**зови [@Анна](user:u1)**")
        let mention = s.first { $0.style.contains(.mention) }
        XCTAssertNotNil(mention)
        XCTAssertTrue(mention?.style.contains(.bold) ?? false)
    }

    func testABrokenTokenStaysPlainText() {
        XCTAssertEqual(spans("[@Анна](user:").map(\.text).joined(), "[@Анна](user:")
        XCTAssertEqual(spans("[Анна](user:u1)").map(\.text).joined(), "[Анна](user:u1)")
        XCTAssertEqual(spans("[@Анна](http://x.com)").first { $0.style.contains(.mention) }, nil)
        XCTAssertNil(spans("[@](user:u1)").first { $0.style.contains(.mention) })
    }

    func testAMentionIsNotLinkifiedFurther() {
        let s = spans("[@example.com](user:u1)")
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].link, "user:u1")
    }

    func testStrippingLeavesTheVisibleName() {
        XCTAssertEqual(MessageMarkdown.mentionsStripped("эй [@Bravo](user:u1), глянь"),
                       "эй @Bravo, глянь")
        XCTAssertEqual(MessageMarkdown.mentionsStripped("без упоминаний"), "без упоминаний")
        XCTAssertEqual(MessageMarkdown.mentionsStripped("[@a](user:"), "[@a](user:")
    }
}
