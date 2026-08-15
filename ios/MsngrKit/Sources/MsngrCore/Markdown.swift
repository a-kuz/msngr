import Foundation

/// Начертания, которые может нести кусок текста сообщения.
public struct MarkdownStyle: OptionSet, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let bold = MarkdownStyle(rawValue: 1 << 0)
    public static let italic = MarkdownStyle(rawValue: 1 << 1)
    public static let strikethrough = MarkdownStyle(rawValue: 1 << 2)
    public static let code = MarkdownStyle(rawValue: 1 << 3)
}

/// Отрезок текста с одинаковым оформлением.
public struct MarkdownSpan: Equatable, Sendable {
    public var text: String
    public var style: MarkdownStyle
    /// Абсолютный URL, если отрезок — ссылка.
    public var link: String?

    public init(_ text: String, style: MarkdownStyle = [], link: String? = nil) {
        self.text = text
        self.style = style
        self.link = link
    }
}

/// Блок сообщения: обычный абзац с инлайн-разметкой либо блок кода.
public enum MarkdownBlock: Equatable, Sendable {
    case paragraph([MarkdownSpan])
    case code(text: String, language: String?)
}

/// Разбор мини-маркдауна в тексте сообщения. Разметка нигде не хранится:
/// в БД лежит исходный текст с маркерами, парсер вызывается при отрисовке.
///
/// Поддержано: `**жирный**`, `_курсив_`, `*курсив*`, `~~зачёркнутый~~`,
/// `` `моноширинный` ``, ```` ```блок кода``` ````, экранирование `\*`,
/// автолинки (http/https и голые домены). Незакрытый маркер остаётся текстом.
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

    // MARK: - Блоки кода

    private enum Piece {
        case text(String)
        case code(String, String?)
    }

    private static let fence: [Character] = ["`", "`", "`"]

    /// Режет исходник на текстовые куски и блоки кода. Открывающий ограничитель
    /// без закрывающего блоком не считается и остаётся обычным текстом.
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
            // первая строка вида ```swift — язык, а не первая строка кода
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
            // перевод строки перед блоком принадлежит разделению блоков
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

    // MARK: - Инлайн-разметка

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
            // моноширинный: содержимое буквальное, вложенной разметки нет
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

    /// Длина цепочки одинаковых символов, начиная с позиции.
    private static func runLength(_ s: [Character], at i: Int) -> Int {
        var n = 0
        while i + n < s.count, s[i + n] == s[i] { n += 1 }
        return n
    }

    /// Позиция закрывающего маркера той же длины. Экранированные символы
    /// и содержимое инлайн-кода пропускаются.
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
                // закрывающая цепочка длиннее маркера («***жирный курсив***»):
                // берём её хвост, лишние символы достаются вложенному разбору
                if count == 2, run >= 2 { return j + run - count }
                if count == 1, run == 1 { return j }
                j += run
                continue
            }
            j += 1
        }
        return nil
    }

    // MARK: - Автолинки

    private static let linkRegex = try! NSRegularExpression(
        pattern: #"(?i)\b(?:(https?)://)?(?:[\p{L}0-9](?:[\p{L}0-9_-]*[\p{L}0-9])?\.)+(\p{L}{2,24})(?::\d{1,5})?(?:/[^\s<>"']*)?"#)

    /// Голый домен считается ссылкой только с известным TLD: иначе в ссылки
    /// уезжают имена файлов вроде main.swift и сокращения «т.к.».
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

            // хвостовая пунктуация к ссылке не относится: «зайди на example.com.»
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
