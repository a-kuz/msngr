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
        XCTAssertEqual(MessageMarkdown.parse("Просто текст"),
                       [.paragraph([MarkdownSpan("Просто текст")])])
    }

    func testEmptyString() {
        XCTAssertEqual(MessageMarkdown.parse(""), [])
    }

    func testBold() {
        XCTAssertEqual(spans("a **жирный** b"), [
            MarkdownSpan("a "),
            MarkdownSpan("жирный", style: .bold),
            MarkdownSpan(" b"),
        ])
    }

    func testItalicBothMarkers() {
        XCTAssertEqual(spans("_курсив_"), [MarkdownSpan("курсив", style: .italic)])
        XCTAssertEqual(spans("*курсив*"), [MarkdownSpan("курсив", style: .italic)])
    }

    func testStrikethrough() {
        XCTAssertEqual(spans("~~нет~~"), [MarkdownSpan("нет", style: .strikethrough)])
    }

    func testInlineCode() {
        XCTAssertEqual(spans("вызов `let x = 1` тут"), [
            MarkdownSpan("вызов "),
            MarkdownSpan("let x = 1", style: .code),
            MarkdownSpan(" тут"),
        ])
    }

    func testInlineCodeKeepsMarkersLiteral() {
        XCTAssertEqual(spans("`a **b** c`"), [MarkdownSpan("a **b** c", style: .code)])
    }

    // MARK: - Nesting

    func testBoldWithItalicInside() {
        XCTAssertEqual(spans("**жирный _и курсив_**"), [
            MarkdownSpan("жирный ", style: .bold),
            MarkdownSpan("и курсив", style: [.bold, .italic]),
        ])
    }

    func testTripleMarkerIsBoldItalic() {
        XCTAssertEqual(spans("***оба***"), [MarkdownSpan("оба", style: [.bold, .italic])])
    }

    func testStrikethroughWithBoldInside() {
        XCTAssertEqual(spans("~~вычеркнут **и жирный**~~"), [
            MarkdownSpan("вычеркнут ", style: .strikethrough),
            MarkdownSpan("и жирный", style: [.strikethrough, .bold]),
        ])
    }

    // MARK: - Escaping

    func testEscapedMarkersStayLiteral() {
        XCTAssertEqual(spans(#"\*не курсив\*"#), [MarkdownSpan("*не курсив*")])
        XCTAssertEqual(spans(#"\*\*не жирный\*\*"#), [MarkdownSpan("**не жирный**")])
    }

    func testEscapedBackslashKeepsFormatting() {
        XCTAssertEqual(spans(#"\\ *курсив*"#), [
            MarkdownSpan("\\ "),
            MarkdownSpan("курсив", style: .italic),
        ])
    }

    /// A backslash before an ordinary character stays a backslash.
    func testBackslashBeforeOrdinaryCharacter() {
        XCTAssertEqual(spans(#"C:\path\to"#), [MarkdownSpan(#"C:\path\to"#)])
    }

    // MARK: - Unclosed markers

    func testUnclosedMarkersStayPlain() {
        XCTAssertEqual(spans("**без закрытия"), [MarkdownSpan("**без закрытия")])
        XCTAssertEqual(spans("текст с * звёздочкой"), [MarkdownSpan("текст с * звёздочкой")])
        XCTAssertEqual(spans("`код без конца"), [MarkdownSpan("`код без конца")])
        XCTAssertEqual(spans("~~почти"), [MarkdownSpan("~~почти")])
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
        let source = "смотри:\n```\nlet a = 1\nlet b = 2\n```\nвот"
        XCTAssertEqual(MessageMarkdown.parse(source), [
            .paragraph([MarkdownSpan("смотри:")]),
            .code(text: "let a = 1\nlet b = 2", language: nil),
            .paragraph([MarkdownSpan("вот")]),
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
        let blocks = MessageMarkdown.parse("```\na\n```\nмежду\n```\nb\n```")
        XCTAssertEqual(blocks, [
            .code(text: "a", language: nil),
            .paragraph([MarkdownSpan("между")]),
            .code(text: "b", language: nil),
        ])
    }

    // MARK: - Autolinks

    func testHttpLink() {
        XCTAssertEqual(spans("см. https://example.com/page?a=1 дальше"), [
            MarkdownSpan("см. "),
            MarkdownSpan("https://example.com/page?a=1", link: "https://example.com/page?a=1"),
            MarkdownSpan(" дальше"),
        ])
    }

    func testBareDomainBecomesLink() {
        XCTAssertEqual(spans("зайди на example.com."), [
            MarkdownSpan("зайди на "),
            MarkdownSpan("example.com", link: "https://example.com"),
            MarkdownSpan("."),
        ])
    }

    /// A file name does not become a link: its extension is not a known TLD.
    func testFileNameIsNotLink() {
        XCTAssertEqual(spans("правь main.swift"), [MarkdownSpan("правь main.swift")])
    }

    func testLinkInsideFormatting() {
        XCTAssertEqual(spans("**жми https://ya.ru сюда**"), [
            MarkdownSpan("жми ", style: .bold),
            MarkdownSpan("https://ya.ru", style: .bold, link: "https://ya.ru"),
            MarkdownSpan(" сюда", style: .bold),
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
        XCTAssertEqual(spans("первая\nвторая"), [MarkdownSpan("первая\nвторая")])
    }
}
