import XCTest
@testable import MsngrCore

final class LinkPreviewTests: XCTestCase {
    // MARK: - The card out of HTML

    func testCardReadsOpenGraphTags() throws {
        let html = """
        <html><head>
        <meta property="og:title" content="Msngr &amp; friends" />
        <meta property="og:description" content="An E2EE messenger">
        <meta property="og:image" content="https://cdn.example.com/pic.jpg">
        <title>fallback title</title>
        </head></html>
        """
        let got = try XCTUnwrap(LinkPreviewFetcher.card(from: html, url: URL(string: "https://example.com/post")!))
        XCTAssertEqual(got.preview.title, "Msngr & friends")
        XCTAssertEqual(got.preview.desc, "An E2EE messenger")
        XCTAssertEqual(got.preview.url, "https://example.com/post")
        XCTAssertEqual(got.imageURL, URL(string: "https://cdn.example.com/pic.jpg"))
    }

    func testCardFallsBackToTitleTagAndResolvesRelativeImage() throws {
        let html = """
        <head><TITLE>Plain page</TITLE>
        <meta name="description" content="described">
        <meta content="/img/cover.png" property="og:image">
        </head>
        """
        let got = try XCTUnwrap(LinkPreviewFetcher.card(from: html, url: URL(string: "https://a.example.com/x/y")!))
        XCTAssertEqual(got.preview.title, "Plain page")
        XCTAssertEqual(got.preview.desc, "described")
        XCTAssertEqual(got.imageURL, URL(string: "https://a.example.com/img/cover.png"))
    }

    func testPageWithoutAnyTitleMakesNoCard() {
        XCTAssertNil(LinkPreviewFetcher.card(from: "<html><body>bare</body></html>",
                                             url: URL(string: "https://example.com")!))
    }

    func testNonHttpImageIsDropped() throws {
        let html = "<title>t</title><meta property=\"og:image\" content=\"file:///etc/passwd\">"
        let got = try XCTUnwrap(LinkPreviewFetcher.card(from: html, url: URL(string: "https://example.com")!))
        XCTAssertNil(got.imageURL)
    }

    func testLongFieldsAreCut() throws {
        let html = "<title>\(String(repeating: "t", count: 500))</title>"
        let got = try XCTUnwrap(LinkPreviewFetcher.card(from: html, url: URL(string: "https://example.com")!))
        XCTAssertEqual(got.preview.title.count, 200)
    }

    // MARK: - Which link the card is for

    func testFirstLinkPrefersTheAutolinkerOrder() {
        XCTAssertEqual(LinkPreviewFetcher.firstLink(in: "see https://one.example and https://two.example"),
                       URL(string: "https://one.example"))
        XCTAssertEqual(LinkPreviewFetcher.firstLink(in: "a [named](https://named.example) link"),
                       URL(string: "https://named.example"))
        XCTAssertNil(LinkPreviewFetcher.firstLink(in: "no links at all"))
        XCTAssertNil(LinkPreviewFetcher.firstLink(in: "ftp://old.example/file"))
    }

    // MARK: - The card travels with the message

    func testPreviewSurvivesTheMessageRow() async throws {
        let db = try AppDatabase.openInMemory()
        var msg = Message(id: "m1", chatId: "c1", fromUserId: "u1",
                          sentAt: 1, kind: .text, text: "https://example.com",
                          status: .sending, isOutgoing: true)
        msg.linkPreview = LinkPreview(url: "https://example.com", title: "Example",
                                      desc: "d", image: nil)
        try await db.write { try msg.save($0) }
        let back = try await db.read { try Message.fetchOne($0, key: "m1") }
        XCTAssertEqual(back?.linkPreview, msg.linkPreview)
        XCTAssertEqual(back?.linkPreview?.host, "example.com")
    }

    /// «Send again» without a queue entry rebuilds the payload from the row —
    /// the card must survive that trip too.
    func testRetryContentCarriesThePreview() {
        var msg = Message(id: "m1", chatId: "c1", fromUserId: "u1",
                          sentAt: 1, kind: .text, text: "https://example.com",
                          status: .failed, isOutgoing: true)
        let card = LinkPreview(url: "https://example.com", title: "Example", desc: "d")
        msg.linkPreview = card
        XCTAssertEqual(SyncEngine.contentOf(msg).preview, card)
    }

    func testHostDropsWWW() {
        XCTAssertEqual(LinkPreview(url: "https://www.example.com/a", title: "t").host, "example.com")
    }
}
