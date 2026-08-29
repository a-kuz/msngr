import XCTest
@testable import MsngrCore

final class MarkdownTests: XCTestCase {

    private func spans(_ source: String, file: StaticString = #filePath, line: UInt = #line) -> [MarkdownSpan] {
        let blocks = MessageMarkdown.parse(source)
        var out: [MarkdownSpan] = []
        for b in blocks {
            if case .paragraph(let s) = b { out += s }
        }
        return out
    }

    func testPlainText() {
        XCTAssertEqual(MessageMarkdown.parse("Just text"),
                       [.paragraph([MarkdownSpan("Just text")])])
    }

    func testEmptyString() {
        XCTAssertEqual(MessageMarkdown.parse(""), [])
    }

    func testBold() {
        XCTAssertEqual(spans("a **bold** b"), [
            MarkdownSpan("a "),
            MarkdownSpan("bold", style: .bold),
            MarkdownSpan(" b"),
        ])
    }

    func testItalicBothMarkers() {
        XCTAssertEqual(spans("_italic_"), [MarkdownSpan("italic", style: .italic)])
        XCTAssertEqual(spans("*italic*"), [MarkdownSpan("italic", style: .italic)])
    }

    func testStrikethrough() {
        XCTAssertEqual(spans("~~no~~"), [MarkdownSpan("no", style: .strikethrough)])
    }

    func testInlineCode() {
        XCTAssertEqual(spans("the call `let x = 1` here"), [
            MarkdownSpan("the call "),
            MarkdownSpan("let x = 1", style: .code),
            MarkdownSpan(" here"),
        ])
    }

    func testInlineCodeKeepsMarkersLiteral() {
        XCTAssertEqual(spans("`a **b** c`"), [MarkdownSpan("a **b** c", style: .code)])
    }

    // MARK: - Nesting

    func testBoldWithItalicInside() {
        XCTAssertEqual(spans("**bold _and italic_**"), [
            MarkdownSpan("bold ", style: .bold),
            MarkdownSpan("and italic", style: [.bold, .italic]),
        ])
    }

    func testTripleMarkerIsBoldItalic() {
        XCTAssertEqual(spans("***both***"), [MarkdownSpan("both", style: [.bold, .italic])])
    }

    func testStrikethroughWithBoldInside() {
        XCTAssertEqual(spans("~~struck **and bold**~~"), [
            MarkdownSpan("struck ", style: .strikethrough),
            MarkdownSpan("and bold", style: [.strikethrough, .bold]),
        ])
    }

    // MARK: - Escaping

    func testEscapedMarkersStayLiteral() {
        XCTAssertEqual(spans(#"\*not italic\*"#), [MarkdownSpan("*not italic*")])
        XCTAssertEqual(spans(#"\*\*not bold\*\*"#), [MarkdownSpan("**not bold**")])
    }

    func testEscapedBackslashKeepsFormatting() {
        XCTAssertEqual(spans(#"\\ *italic*"#), [
            MarkdownSpan("\\ "),
            MarkdownSpan("italic", style: .italic),
        ])
    }

    /// A backslash before an ordinary character stays a backslash.
    func testBackslashBeforeOrdinaryCharacter() {
        XCTAssertEqual(spans(#"C:\path\to"#), [MarkdownSpan(#"C:\path\to"#)])
    }

    // MARK: - Unclosed markers

    func testUnclosedMarkersStayPlain() {
        XCTAssertEqual(spans("**never closed"), [MarkdownSpan("**never closed")])
        XCTAssertEqual(spans("text with a * star"), [MarkdownSpan("text with a * star")])
        XCTAssertEqual(spans("`code with no end"), [MarkdownSpan("`code with no end")])
        XCTAssertEqual(spans("~~almost"), [MarkdownSpan("~~almost")])
    }

    func testEmptyMarkerPairIsLiteral() {
        XCTAssertEqual(spans("**"), [MarkdownSpan("**")])
        XCTAssertEqual(spans("``"), [MarkdownSpan("``")])
    }

    func testUnclosedCodeFenceIsPlain() {
        XCTAssertEqual(MessageMarkdown.parse("```let x = 1"),
                       [.paragraph([MarkdownSpan("```let x = 1")])])
    }

    // MARK: - Code blocks

    func testMultilineCodeBlock() {
        let source = "look:\n```\nlet a = 1\nlet b = 2\n```\nthere"
        XCTAssertEqual(MessageMarkdown.parse(source), [
            .paragraph([MarkdownSpan("look:")]),
            .code(text: "let a = 1\nlet b = 2", language: nil),
            .paragraph([MarkdownSpan("there")]),
        ])
    }

    func testCodeBlockWithLanguage() {
        XCTAssertEqual(MessageMarkdown.parse("```swift\nlet a = 1\n```"),
                       [.code(text: "let a = 1", language: "swift")])
    }

    func testCodeBlockKeepsMarkersLiteral() {
        XCTAssertEqual(MessageMarkdown.parse("```\n**not bold** _x_\n```"),
                       [.code(text: "**not bold** _x_", language: nil)])
    }

    func testTwoCodeBlocks() {
        let blocks = MessageMarkdown.parse("```\na\n```\nbetween\n```\nb\n```")
        XCTAssertEqual(blocks, [
            .code(text: "a", language: nil),
            .paragraph([MarkdownSpan("between")]),
            .code(text: "b", language: nil),
        ])
    }

    // MARK: - Autolinks

    func testHttpLink() {
        XCTAssertEqual(spans("see https://example.com/page?a=1 further on"), [
            MarkdownSpan("see "),
            MarkdownSpan("https://example.com/page?a=1", link: "https://example.com/page?a=1"),
            MarkdownSpan(" further on"),
        ])
    }

    func testBareDomainBecomesLink() {
        XCTAssertEqual(spans("go to example.com."), [
            MarkdownSpan("go to "),
            MarkdownSpan("example.com", link: "https://example.com"),
            MarkdownSpan("."),
        ])
    }

    /// A file name does not become a link: its extension is not a known TLD.
    func testFileNameIsNotLink() {
        XCTAssertEqual(spans("edit main.swift"), [MarkdownSpan("edit main.swift")])
    }

    func testLinkInsideFormatting() {
        XCTAssertEqual(spans("**tap https://ya.ru right here**"), [
            MarkdownSpan("tap ", style: .bold),
            MarkdownSpan("https://ya.ru", style: .bold, link: "https://ya.ru"),
            MarkdownSpan(" right here", style: .bold),
        ])
    }

    func testNoLinksInsideCode() {
        XCTAssertEqual(spans("`curl https://ya.ru`"),
                       [MarkdownSpan("curl https://ya.ru", style: .code)])
    }

    func testNoLinksInsideCodeBlock() {
        XCTAssertEqual(MessageMarkdown.parse("```\nhttps://ya.ru\n```"),
                       [.code(text: "https://ya.ru", language: nil)])
    }

    // MARK: - Mixed

    func testMixedMessage() {
        let blocks = MessageMarkdown.parse("**bold** _it_ ~~s~~ `c` https://a.io")
        XCTAssertEqual(blocks, [.paragraph([
            MarkdownSpan("bold", style: .bold),
            MarkdownSpan(" "),
            MarkdownSpan("it", style: .italic),
            MarkdownSpan(" "),
            MarkdownSpan("s", style: .strikethrough),
            MarkdownSpan(" "),
            MarkdownSpan("c", style: .code),
            MarkdownSpan(" "),
            MarkdownSpan("https://a.io", link: "https://a.io"),
        ])])
    }

    /// Line breaks inside a paragraph are preserved.
    func testNewlinesInsideParagraph() {
        XCTAssertEqual(spans("first\nsecond"), [MarkdownSpan("first\nsecond")])
    }

    // MARK: - Explicit links

    func testExplicitLink() {
        XCTAssertEqual(spans("see [the docs](https://a.io/x) now"), [
            MarkdownSpan("see "),
            MarkdownSpan("the docs", link: "https://a.io/x"),
            MarkdownSpan(" now"),
        ])
    }

    /// A link whose target is not an absolute http(s) URL is no markup — the
    /// text stays as typed (the autolinker may still pick a URL out of it).
    func testExplicitLinkNeedsHttp() {
        XCTAssertEqual(spans("[x](y z)"), [MarkdownSpan("[x](y z)")])
        XCTAssertEqual(spans("[x](ftp://a.io)").first, MarkdownSpan("[x](ftp://"))
    }

    /// An unclosed bracket is no link markup; the bare URL inside still
    /// autolinks, the same as anywhere else in plain text.
    func testExplicitLinkUnclosed() {
        XCTAssertEqual(spans("[x](https://a.io"), [
            MarkdownSpan("[x]("),
            MarkdownSpan("https://a.io", link: "https://a.io"),
        ])
    }

    /// The explicit target wins over the autolinker for the same span, and
    /// `links(in:)` lists it.
    func testExplicitLinkListed() {
        XCTAssertEqual(MessageMarkdown.links(in: "[a](https://a.io) https://b.io"),
                       ["https://a.io", "https://b.io"])
    }
}
