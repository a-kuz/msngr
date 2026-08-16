import UIKit

/// Message text: its own TextKit stack instead of a UILabel. BubbleLayout measures with
/// the same stack, so what is drawn matches what was computed, and code block backdrops
/// and link hit-testing are derived from the very same line fragments.
final class MessageTextView: UIView {
    private let storage = NSTextStorage()
    private let manager = NSLayoutManager()
    private let container = NSTextContainer(size: .zero)
    private var codeBackground: UIColor = .clear

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        // TextKit draws the glyphs directly in draw(_:), so without this the
        // message body is invisible to VoiceOver and UI testing
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Colours are applied here: the layout does not depend on them, so the layout plan
    /// keeps the text colourless and survives a change of palette or theme.
    func configure(_ attr: NSAttributedString, color: UIColor, linkColor: UIColor,
                   codeBackground: UIColor) {
        let mutable = Self.coloured(attr, color: color, linkColor: linkColor)
        self.codeBackground = codeBackground
        storage.setAttributedString(mutable)
        accessibilityLabel = mutable.string
        applyContainerWidth()
        setNeedsDisplay()
    }

    /// Цвета текста и ссылок поверх плана раскладки. Тем же текстом рисует
    /// приподнятый баббл контекстного меню, поэтому раскраска общая.
    static func coloured(_ attr: NSAttributedString, color: UIColor,
                         linkColor: UIColor) -> NSMutableAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: full)
        mutable.enumerateAttribute(.msngrLink, in: full) { value, range, _ in
            guard value != nil else { return }
            mutable.addAttributes([.foregroundColor: linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        return mutable
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyContainerWidth()
    }

    private func applyContainerWidth() {
        guard container.size.width != bounds.width else { return }
        container.size = CGSize(width: bounds.width, height: .greatestFiniteMagnitude)
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        guard storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        storage.enumerateAttribute(.msngrCodeBlock, in: full) { value, range, _ in
            guard value != nil else { return }
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var box = manager.boundingRect(forGlyphRange: glyphs, in: container)
            box.origin.x = 0
            box.size.width = bounds.width
            codeBackground.setFill()
            UIBezierPath(roundedRect: box, cornerRadius: MessageMarkdownRenderer.codeCorner).fill()
        }
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: .zero)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { setNeedsDisplay() }
    }

    /// The link under a point in view coordinates; nil when the touch missed one.
    func url(at point: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        // glyphIndex returns the nearest glyph even on a miss, so the hit is verified
        let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.msngrLink, at: index, effectiveRange: nil) as? URL
    }
}
