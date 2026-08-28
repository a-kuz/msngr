import Foundation

/// Styles a run of message text can carry.
public struct MarkdownStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = MarkdownStyle(rawValue: 1 << 0)
    public static let italic = MarkdownStyle(rawValue: 1 << 1)
    public static let strikethrough = MarkdownStyle(rawValue: 1 << 2)
    public static let code = MarkdownStyle(rawValue: 1 << 3)
    /// A mention of a user: the visible "@Name" with a `user:<id>` link.
    public static let mention = MarkdownStyle(rawValue: 1 << 4)
}

/// A run of text with uniform styling.
public struct MarkdownSpan: Equatable, Sendable {
    public var text: String
    public var style: MarkdownStyle
    /// Absolute URL when the run is a link.
    public var link: String?

    public init(_ text: String, style: MarkdownStyle = [], link: String? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

/// A message block: a paragraph with inline markup, or a code block.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownSpan])
    case code(text: String, language: String?)
}

/// Parses the small markdown dialect of message text. Nothing about the markup is
/// stored: the database keeps the source text with its markers and the parser runs
/// at draw time.
///
/// Supported: `**bold**`, `_italic_`, `*italic*`, `~~strikethrough~~`,
/// `` `monospace` ``, ```` ```code block``` ````, escaping with `\*`, and autolinks
/// (http/https plus bare domains). An unclosed marker stays plain text.
public enum MessageMarkdown {
    public static func parse(_ source: String) -> [MarkdownBlock] {
        guard !source.isEmpty else { return [] }
        var blocks: [MarkdownBlock] = []
        for piece in splitCodeBlocks(source) {
            switch piece {
            case .text(let text):
                guard !text.isEmpty else { continue }
                let spans = linkify(parseInline(Array(text), style: []))
                if !spans.isEmpty { blocks.append(.paragraph(spans)) }
            case .code(let text, let language):
                blocks.append(.code(text: text, language: language))
            }
        }
        return blocks
    }

    /// Absolute URLs the text carries, in the order they are written, each one
    /// once. The same pass the feed draws with, so what the gallery lists and
    /// what the bubble underlines are the same links.
    public static func links(in source: String) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for block in parse(source) {
            guard case .paragraph(let spans) = block else { continue }
            for link in spans.compactMap(\.link) where seen.insert(link).inserted {
                out.append(link)
            }
        }
        return out
    }

    // MARK: - Code blocks

    private enum Piece {
        case text(String)
        case code(String, String?)
    }

    private static let fence: [Character] = ["`", "`", "`"]

    /// Cuts the source into text pieces and code blocks. An opening fence without a
    /// closing one is no block at all and stays plain text.
    private static func splitCodeBlocks(_ source: String) -> [Piece] {
        let s = Array(source)
        var pieces: [Piece] = []
        var plain: [Character] = []
        var i = 0
        while i < s.count {
            guard matches(s, i, fence), !isEscaped(s, i),
                  let close = find(fence, in: s, from: i + 3) else {
                plain.append(s[i])
                i += 1
                continue
            }
            var body = Array(s[(i + 3)..<close])
            var language: String?
            // a first line like ```swift names the language and is not code
            if let nl = body.firstIndex(of: "\n") {
                let head = String(body[0..<nl]).trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, head.count <= 20,
                   head.allSatisfy({ $0.isLetter || $0.isNumber || "+-._#".contains($0) }) {
                    language = head
                }
                if language != nil || String(body[0..<nl]).trimmingCharacters(in: .whitespaces).isEmpty {
                    body = Array(body[(nl + 1)...])
                }
            }
            if body.last == "\n" { body.removeLast() }
            // the newline ahead of a block belongs to the separation between blocks
            if plain.last == "\n" { plain.removeLast() }
            pieces.append(.text(String(plain)))
            plain = []
            pieces.append(.code(String(body), language))
            i = close + 3
            if i < s.count, s[i] == "\n" { i += 1 }
        }
        pieces.append(.text(String(plain)))
        return pieces
    }

    private static func find(_ needle: [Character], in s: [Character], from: Int) -> Int? {
        var i = from
        while i + needle.count <= s.count {
            if matches(s, i, needle), !isEscaped(s, i) { return i }
            i += 1
        }
        return nil
    }

    private static func matches(_ s: [Character], _ i: Int, _ needle: [Character]) -> Bool {
        guard i + needle.count <= s.count else { return false }
        for (k, c) in needle.enumerated() where s[i + k] != c { return false }
        return true
    }

    private static func isEscaped(_ s: [Character], _ i: Int) -> Bool {
        var backslashes = 0
        var j = i - 1
        while j >= 0, s[j] == "\\" {
            backslashes += 1
            j -= 1
        }
        return backslashes % 2 == 1
    }

    // MARK: - Inline markup

    private static let escapable: Set<Character> = ["*", "_", "~", "`", "\\"]

    private struct Delimiter {
        let char: Character
        let count: Int
        let style: MarkdownStyle
    }

    private static let delimiters: [Delimiter] = [
        Delimiter(char: "*", count: 2, style: .bold),
        Delimiter(char: "~", count: 2, style: .strikethrough),
        Delimiter(char: "_", count: 2, style: .bold),
        Delimiter(char: "*", count: 1, style: .italic),
        Delimiter(char: "_", count: 1, style: .italic),
    ]

    private static func parseInline(_ s: [Character], style: MarkdownStyle) -> [MarkdownSpan] {
        var out: [MarkdownSpan] = []
        var buffer = ""
        var i = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(MarkdownSpan(buffer, style: style))
            buffer = ""
        }

        outer: while i < s.count {
            let c = s[i]
            if c == "\\", i + 1 < s.count, escapable.contains(s[i + 1]) {
                buffer.append(s[i + 1])
                i += 2
                continue
            }
            // a mention token: the source carries the userId, the reader sees "@Name"
            if c == "[", let m = mentionToken(s, at: i) {
                flush()
                out.append(MarkdownSpan(m.text, style: style.union(.mention), link: m.link))
                i = m.end
                continue
            }
            // monospace: the contents are literal, nothing nested is parsed inside
            if c == "`", let close = closingIndex(s, from: i + 1, char: "`", count: 1), close > i + 1 {
                flush()
                out.append(MarkdownSpan(String(s[(i + 1)..<close]), style: style.union(.code)))
                i = close + 1
                continue
            }
            for d in delimiters where c == d.char {
                guard runLength(s, at: i) >= d.count,
                      let close = closingIndex(s, from: i + d.count, char: d.char, count: d.count),
                      close > i + d.count else { continue }
                flush()
                out += parseInline(Array(s[(i + d.count)..<close]), style: style.union(d.style))
                i = close + d.count
                continue outer
            }
            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Mentions

    /// The mention token in message source: `[@Name](user:<userId>)`. The name
    /// shows as it was at send time, the id survives any rename.
    static func mentionToken(_ s: [Character], at i: Int)
        -> (text: String, link: String, end: Int)? {
        guard i + 1 < s.count, s[i] == "[", s[i + 1] == "@" else { return nil }
        // the visible part: "@Name" up to "](", no newlines inside
        var j = i + 2
        while j < s.count, s[j] != "]", s[j] != "\n" { j += 1 }
        guard j > i + 2, j + 6 < s.count, s[j] == "]", s[j + 1] == "(",
              matches(s, j + 2, Array("user:")) else { return nil }
        var k = j + 7
        while k < s.count, s[k] != ")", s[k] != "\n", s[k] != " " { k += 1 }
        guard k > j + 7, k < s.count, s[k] == ")" else { return nil }
        return (text: String(s[(i + 1)..<j]),
                link: String(s[(j + 2)..<k]),
                end: k + 1)
    }

    /// Message source with mention tokens replaced by their visible "@Name":
    /// what previews, notifications and quotes show.
    public static func mentionsStripped(_ source: String) -> String {
        guard source.contains("](user:") else { return source }
        let s = Array(source)
        var out = ""
        var i = 0
        while i < s.count {
            if s[i] == "[", let m = mentionToken(s, at: i) {
                out += m.text
                i = m.end
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    /// A user the tokenizer may turn a typed "@username" into a mention of.
    public struct MentionCandidate: Equatable, Sendable {
        public var userId: String
        public var username: String
        public var displayName: String

        public init(userId: String, username: String, displayName: String) {
            self.userId = userId
            self.username = username
            self.displayName = displayName
        }
    }

    /// Replaces every typed "@username" of a known user with the mention token.
    /// The match is case-insensitive and takes the whole handle word; text
    /// inside code spans is left alone by virtue of the token being introduced
    /// only where a bare "@" stood.
    public static func tokenizeMentions(_ text: String, users: [MentionCandidate]) -> String {
        guard text.contains("@"), !users.isEmpty else { return text }
        let byHandle = Dictionary(users.map { ($0.username.lowercased(), $0) },
                                  uniquingKeysWith: { a, _ in a })
        let s = Array(text)
        var out = ""
        var i = 0
        while i < s.count {
            // an existing token passes through untouched
            if s[i] == "[", let m = mentionToken(s, at: i) {
                out += String(s[i..<m.end])
                i = m.end
                continue
            }
            guard s[i] == "@", i == 0 || !isHandleChar(s[i - 1]) else {
                out.append(s[i])
                i += 1
                continue
            }
            var j = i + 1
            while j < s.count, isHandleChar(s[j]) { j += 1 }
            let handle = String(s[(i + 1)..<j]).lowercased()
            if j > i + 1, let user = byHandle[handle] {
                out += "[@\(user.displayName)](user:\(user.userId))"
            } else {
                out += String(s[i..<j])
            }
            i = j
        }
        return out
    }

    private static func isHandleChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    /// Length of the run of identical characters starting at the position.
    private static func runLength(_ s: [Character], at i: Int) -> Int {
        var n = 0
        while i + n < s.count, s[i + n] == s[i] { n += 1 }
        return n
    }

    /// Position of the closing marker of the same length. Escaped characters and the
    /// contents of inline code are skipped over.
    private static func closingIndex(_ s: [Character], from: Int, char: Character, count: Int) -> Int? {
        var j = from
        while j < s.count {
            if s[j] == "\\" {
                j += 2
                continue
            }
            if s[j] == "`", char != "`" {
                if let end = closingIndex(s, from: j + 1, char: "`", count: 1) {
                    j = end + 1
                    continue
                }
            }
            if s[j] == char {
                let run = runLength(s, at: j)
                // a closing run longer than the marker ("***bold italic***"): its tail
                // closes this one, the extra characters go to the nested pass
                if count == 2, run >= 2 { return j + run - count }
                if count == 1, run == 1 { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    // MARK: - Autolinks

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:(https?)://)?(?:[\p{L}0-9](?:[\p{L}0-9_-]*[\p{L}0-9])?\.)+(\p{L}{2,24})(?::\d{1,5})?(?:/[^\s<>"']*)?"#)

    /// A bare domain counts as a link only with a known TLD, otherwise file names like
    /// main.swift and abbreviations written with a dot inside turn into links.
    private static let knownTLDs: Set<String> = [
        "com", "net", "org", "edu", "gov", "int", "mil", "info", "biz", "name", "pro",
        "app", "dev", "io", "ai", "co", "me", "tv", "fm", "gg", "to", "ly", "sh", "is",
        "cc", "xyz", "online", "site", "tech", "store", "shop", "club", "live", "news",
        "blog", "cloud", "space", "website", "wiki", "email", "link", "one", "life",
        "ru", "su", "рф", "ua", "by", "kz", "uk", "de", "fr", "es", "it", "nl", "pl",
        "se", "no", "fi", "dk", "cz", "ch", "at", "be", "pt", "gr", "tr", "cn", "jp",
        "kr", "in", "br", "ca", "au", "nz", "mx", "ar", "za", "il", "ae", "eu",
    ]

    private static let trailingPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "»", "\"", "'"]

    private static func linkify(_ spans: [MarkdownSpan]) -> [MarkdownSpan] {
        var out: [MarkdownSpan] = []
        for span in spans {
            guard !span.style.contains(.code), span.link == nil else {
                out.append(span)
                continue
            }
            out += linkify(span)
        }
        return out
    }

    private static func linkify(_ span: MarkdownSpan) -> [MarkdownSpan] {
        let text = span.text
        let ns = text as NSString
        let matches = linkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [span] }

        var out: [MarkdownSpan] = []
        var cursor = 0
        for m in matches {
            var range = m.range
            let scheme = m.range(at: 1).location != NSNotFound ? ns.substring(with: m.range(at: 1)) : nil
            let tld = ns.substring(with: m.range(at: 2)).lowercased()
            if scheme == nil, !knownTLDs.contains(tld) { continue }

            // trailing punctuation is not part of the link: "go to example.com."
            while range.length > 0,
                  let last = ns.substring(with: range).last,
                  trailingPunctuation.contains(last) {
                if last == ")", ns.substring(with: range).contains("(") { break }
                range.length -= 1
            }
            guard range.length > 0, range.location >= cursor else { continue }

            if range.location > cursor {
                out.append(MarkdownSpan(ns.substring(with: NSRange(location: cursor, length: range.location - cursor)),
                                        style: span.style))
            }
            let raw = ns.substring(with: range)
            out.append(MarkdownSpan(raw, style: span.style,
                                    link: scheme == nil ? "https://" + raw : raw))
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            out.append(MarkdownSpan(ns.substring(from: cursor), style: span.style))
        }
        return out.isEmpty ? [span] : out
    }
}
