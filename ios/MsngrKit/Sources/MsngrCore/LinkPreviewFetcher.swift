import Foundation

/// Builds the link card on the sender's device: fetches the page, reads its
/// Open Graph tags (falling back to <title>), and, when the page names a
/// picture, downloads that too. Nothing here runs on the receiver — the card
/// travels inside the encrypted payload, so the server and the peer never
/// touch the page.
public enum LinkPreviewFetcher {
    /// Pages larger than this are cut off; a title lives in the first bytes.
    static let pageByteCeiling = 512 * 1024
    static let imageByteCeiling = 5 * 1024 * 1024
    static let timeout: TimeInterval = 10

    /// The first http(s) URL of a message text, the one the card is built for.
    /// Markdown link targets count the same as bare URLs — whatever the
    /// autolinker makes tappable first.
    public static func firstLink(in text: String) -> URL? {
        for link in MessageMarkdown.links(in: text) {
            if let url = URL(string: link), url.scheme == "http" || url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    /// The card without its picture, and the picture's URL when the page names
    /// one — downloading and encrypting it is the caller's send pipeline.
    public static func fetchCard(for url: URL) async -> (preview: LinkPreview, imageURL: URL?)? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              (http.mimeType ?? "text/html").contains("html")
        else { return nil }
        let html = String(decoding: data.prefix(pageByteCeiling), as: UTF8.self)
        return card(from: html, url: response.url ?? url)
    }

    /// Parses the card out of the page. Split from the fetch so tests feed it
    /// HTML directly.
    public static func card(from html: String, url: URL) -> (preview: LinkPreview, imageURL: URL?)? {
        let og = metaContent(html)
        let title = (og["og:title"] ?? og["twitter:title"] ?? htmlTitle(html))
            .map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else { return nil }
        let desc = (og["og:description"] ?? og["description"] ?? og["twitter:description"])
            .map(decodeEntities)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var preview = LinkPreview(url: url.absoluteString, title: String(title.prefix(200)))
        preview.desc = desc.flatMap { $0.isEmpty ? nil : String($0.prefix(300)) }
        let image = (og["og:image"] ?? og["twitter:image"])
            .flatMap { URL(string: decodeEntities($0), relativeTo: url)?.absoluteURL }
            .flatMap { $0.scheme == "http" || $0.scheme == "https" ? $0 : nil }
        return (preview, image)
    }

    /// Downloads the card's picture; the caller encrypts and uploads it the way
    /// any photo goes.
    public static func fetchImage(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= imageByteCeiling, !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: - HTML

    /// `<meta property="og:title" content="…">` in either attribute order,
    /// `name=` accepted alongside `property=`.
    static func metaContent(_ html: String) -> [String: String] {
        var found: [String: String] = [:]
        for match in metaTag.matches(in: html, range: NSRange(html.startIndex..., in: html)) {
            guard let tagRange = Range(match.range, in: html) else { continue }
            let tag = String(html[tagRange])
            guard let key = attribute("property", in: tag) ?? attribute("name", in: tag),
                  let content = attribute("content", in: tag),
                  found[key.lowercased()] == nil
            else { continue }
            found[key.lowercased()] = content
        }
        return found
    }

    static func htmlTitle(_ html: String) -> String? {
        guard let match = titleTag.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[range])
    }

    private static let metaTag = try! NSRegularExpression(pattern: "<meta\\s[^>]*>",
                                                          options: [.caseInsensitive])
    private static let titleTag = try! NSRegularExpression(pattern: "<title[^>]*>([^<]*)</title>",
                                                           options: [.caseInsensitive])

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\(name)\\s*=\\s*[\"']([^\"']*)[\"']",
                                                options: [.caseInsensitive]),
              let match = re.firstMatch(in: tag, range: NSRange(tag.startIndex..., in: tag)),
              let range = Range(match.range(at: 1), in: tag)
        else { return nil }
        return String(tag[range])
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
                               ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                               ("&nbsp;", " ")] {
            out = out.replacingOccurrences(of: entity, with: char)
        }
        return out
    }
}
