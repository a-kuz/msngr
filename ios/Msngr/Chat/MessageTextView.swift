import UIKit

/// Текст сообщения: собственный стек TextKit вместо UILabel. Он же используется
/// для замера в BubbleLayout, поэтому нарисованное совпадает с посчитанным —
/// подложки блоков кода и попадание по ссылке считаются по тем же фрагментам строк.
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
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Цвета накладываются здесь: раскладка от них не зависит, поэтому план
    /// раскладки хранит текст без цвета и переживает смену палитры и темы.
    func configure(_ attr: NSAttributedString, color: UIColor, linkColor: UIColor,
                   codeBackground: UIColor) {
        let mutable = NSMutableAttributedString(attributedString: attr)
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttribute(.foregroundColor, value: color, range: full)
        mutable.enumerateAttribute(.msngrLink, in: full) { value, range, _ in
            guard value != nil else { return }
            mutable.addAttributes([.foregroundColor: linkColor,
                                   .underlineStyle: NSUnderlineStyle.single.rawValue], range: range)
        }
        self.codeBackground = codeBackground
        storage.setAttributedString(mutable)
        applyContainerWidth()
        setNeedsDisplay()
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

    /// Ссылка под точкой в координатах вью; nil — попали мимо ссылки.
    func url(at point: CGPoint) -> URL? {
        guard storage.length > 0 else { return nil }
        let glyph = manager.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: nil)
        // glyphIndex возвращает ближайший глиф даже при промахе — проверяем попадание
        let box = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        let index = manager.characterIndexForGlyph(at: glyph)
        guard index < storage.length else { return nil }
        return storage.attribute(.msngrLink, at: index, effectiveRange: nil) as? URL
    }
}
