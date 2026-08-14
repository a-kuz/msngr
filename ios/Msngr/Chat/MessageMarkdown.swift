import UIKit
import MsngrCore

extension NSAttributedString.Key {
    /// Диапазон, который рисуется подложкой блока кода.
    static let msngrCodeBlock = NSAttributedString.Key("msngrCodeBlock")
    /// Ссылка (URL). Свой ключ вместо .link: системный красит текст в синий,
    /// нечитаемый на исходящем баббле, — цвет задаёт ячейка.
    static let msngrLink = NSAttributedString.Key("msngrLink")
}

/// Сборка NSAttributedString из мини-маркдауна: шрифты производятся от
/// BubbleLayout.textFont, поэтому замер и отрисовка идут по одной строке.
enum MessageMarkdownRenderer {
    /// Горизонтальные отступы текста кода от края подложки.
    static let codeInset: CGFloat = 8
    /// Вертикальные отступы блока кода (задаются интервалами абзаца и потому
    /// попадают в замер высоты).
    static let codeVerticalInset: CGFloat = 6
    static let codeCorner: CGFloat = 8

    static func attributed(_ source: String) -> NSAttributedString {
        let blocks = MessageMarkdown.parse(source)
        let out = NSMutableAttributedString()
        guard !blocks.isEmpty else {
            return NSAttributedString(string: source, attributes: [.font: BubbleLayout.textFont])
        }
        for (i, block) in blocks.enumerated() {
            let separator = i < blocks.count - 1 ? "\n" : ""
            switch block {
            case .paragraph(let spans):
                for span in spans { out.append(inline(span)) }
                if !separator.isEmpty {
                    out.append(NSAttributedString(string: separator, attributes: [.font: BubbleLayout.textFont]))
                }
            case .code(let text, _):
                let start = out.length
                out.append(NSAttributedString(string: text, attributes: [
                    .font: codeFont,
                    .msngrCodeBlock: true,
                ]))
                let codeRange = NSRange(location: start, length: out.length - start)
                if !separator.isEmpty {
                    out.append(NSAttributedString(string: separator, attributes: [.font: codeFont]))
                }
                // стиль абзаца обязан покрывать и завершающий перевод строки,
                // иначе TextKit считает абзацем следующий блок
                out.addAttribute(.paragraphStyle, value: codeParagraphStyle,
                                 range: NSRange(location: start, length: out.length - start))
                out.addAttribute(.msngrCodeBlock, value: true, range: codeRange)
            }
        }
        return out
    }

    private static func inline(_ span: MarkdownSpan) -> NSAttributedString {
        var attrs: [NSAttributedString.Key: Any] = [.font: font(for: span.style)]
        if span.style.contains(.strikethrough) {
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let link = span.link, let url = url(from: link) {
            attrs[.msngrLink] = url
        }
        return NSAttributedString(string: span.text, attributes: attrs)
    }

    static func url(from string: String) -> URL? {
        if let url = URL(string: string) { return url }
        guard let encoded = string.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else { return nil }
        return URL(string: encoded)
    }

    // MARK: - Шрифты

    static let codeFont = UIFont.monospacedSystemFont(ofSize: BubbleLayout.textFont.pointSize - 2,
                                                      weight: .regular)

    static func font(for style: MarkdownStyle) -> UIFont {
        if style.contains(.code) { return codeFont }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let descriptor = BubbleLayout.textFont.fontDescriptor.withSymbolicTraits(traits) else {
            return BubbleLayout.textFont
        }
        return UIFont(descriptor: descriptor, size: BubbleLayout.textFont.pointSize)
    }

    private static let codeParagraphStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = codeInset
        ps.headIndent = codeInset
        ps.tailIndent = -codeInset
        ps.paragraphSpacingBefore = codeVerticalInset
        ps.paragraphSpacing = codeVerticalInset
        // длинные строки кода переносятся по символам: горизонтального скролла
        // внутри баббла нет
        ps.lineBreakMode = .byCharWrapping
        return ps
    }()
}
