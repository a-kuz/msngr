import UIKit
import MsngrCore

extension NSAttributedString.Key {
    /// The range drawn with a code block's backdrop.
    static let msngrCodeBlock = NSAttributedString.Key("msngrCodeBlock")
    /// A URL. Its own key instead of .link, because the system one paints the text blue,
    /// which is unreadable on an outgoing bubble; the cell picks the colour.
    static let msngrLink = NSAttributedString.Key("msngrLink")
}

/// Builds an NSAttributedString out of the mini-markdown: the fonts derive from
/// BubbleLayout.textFont, so measurement and drawing work on one and the same string.
enum MessageMarkdownRenderer {
    /// Horizontal inset of the code text from the edge of its backdrop.
    static let codeInset: CGFloat = 8
    /// Vertical inset of a code block, expressed as paragraph spacing and therefore
    /// included in the height measurement.
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
                // the paragraph style has to cover the trailing newline as well, otherwise
                // TextKit treats the next block as part of the paragraph
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

    // MARK: - Fonts

    static var codeFont: UIFont { Theme.Text.bubbleCode.uiFont }

    static func font(for style: MarkdownStyle) -> UIFont {
        if style.contains(.code) { return codeFont }
        let base = BubbleLayout.textFont
        var traits: UIFontDescriptor.SymbolicTraits = []
        if style.contains(.bold) { traits.insert(.traitBold) }
        if style.contains(.italic) { traits.insert(.traitItalic) }
        guard !traits.isEmpty,
              let descriptor = base.fontDescriptor.withSymbolicTraits(traits) else {
            return base
        }
        return UIFont(descriptor: descriptor, size: base.pointSize)
    }

    private static let codeParagraphStyle: NSParagraphStyle = {
        let ps = NSMutableParagraphStyle()
        ps.firstLineHeadIndent = codeInset
        ps.headIndent = codeInset
        ps.tailIndent = -codeInset
        ps.paragraphSpacingBefore = codeVerticalInset
        ps.paragraphSpacing = codeVerticalInset
        // long code lines wrap by character: there is no horizontal scrolling inside a bubble
        ps.lineBreakMode = .byCharWrapping
        return ps
    }()
}
