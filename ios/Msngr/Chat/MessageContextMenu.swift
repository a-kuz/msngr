import UIKit
import SwiftUI
import MsngrCore

/// Message context menu: the background blurs, the bubble lifts, a horizontal row of
/// quick reactions sits above it and a card of actions below.
final class MessageContextOverlay: UIView {
    struct Item {
        let title: String
        let icon: String
        var destructive = false
        var submenu: [Item] = []
        var handler: (() -> Void)?
    }

    /// Текст сообщения, который в приподнятом состоянии выделяется протяжкой.
    /// Снимок баббла рендерится без него, а сверху ложится живой текст той же
    /// раскладки — иначе выделение закрасило бы картинку с текстом.
    struct SelectableText {
        let attributed: NSAttributedString
        /// фрейм текста в координатах баббла
        let frame: CGRect
        let color: UIColor
        let linkColor: UIColor
        let codeBackground: UIColor
    }

    static let quickReactions = ["❤️", "👍", "🔥", "😂", "😮", "😢"]

    private let blurView = UIVisualEffectView(effect: nil)
    /// A wash of background colour over the blur: it kills the bubbles showing through and
    /// fades out towards the selected message through a gradient mask.
    private let scrim = UIView()
    private let scrimMask = CAGradientLayer()
    private let snapshot: UIView
    private let originFrame: CGRect
    private let isOutgoing: Bool
    private let myReaction: String?
    private let onReact: (String) -> Void
    private var items: [Item]

    private let reactionBar = UIView()
    private var emojiButtons: [UIButton] = []
    private let menuCard = UIView()
    private let menuStack = UIStackView()
    /// живой текст поверх снимка, когда сообщение текстовое
    private var textView: UITextView?
    /// точка, от которой тянут выделение
    private var dragAnchor: UITextPosition?
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    private static var menuWidth: CGFloat { TypeScale.scaled(252, max: 340) }
    private static var rowHeight: CGFloat {
        max(44, ceil(Theme.Text.menuItem.uiFont.lineHeight) + 18)
    }
    private static var barHeight: CGFloat {
        max(44, ceil(Theme.Text.largeControl.uiFont.lineHeight) + 8)
    }
    private static let gap: CGFloat = 8

    // MARK: - Presentation

    static func present(over bubble: UIView, in window: UIWindow, isOutgoing: Bool,
                        myReaction: String?, items: [Item], selectableText: SelectableText? = nil,
                        onReact: @escaping (String) -> Void) {
        // rendered into an image, because snapshotView returns nil or nothing for bubbles
        // taller than the screen; only the top is rendered, more than a screen cannot be shown
        let renderH = min(bubble.bounds.height, window.bounds.height * 1.2)
        let renderer = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: bubble.bounds.width, height: renderH))
        let image = renderer.image { ctx in bubble.layer.render(in: ctx.cgContext) }
        let snap = UIImageView(image: image)
        snap.contentMode = .scaleToFill
        // the bubble arrives still carrying the press dip: the lift starts from that
        // very scale so the finger-down state flows into the menu without a cut. The
        // resting frame is taken with the transform zeroed out
        let lift = bubble.layer.presentation()?.affineTransform().a ?? 1
        let t = bubble.transform
        bubble.transform = .identity
        let frame = bubble.convert(bubble.bounds, to: window)
        bubble.transform = t
        let overlay = MessageContextOverlay(snapshot: snap, originFrame: frame, isOutgoing: isOutgoing,
                                            myReaction: myReaction, items: items,
                                            selectableText: selectableText,
                                            pressScale: min(max(lift, 0.8), 1), onReact: onReact)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        overlay.animateIn()
    }

    private init(snapshot: UIView, originFrame: CGRect, isOutgoing: Bool,
                 myReaction: String?, items: [Item], selectableText: SelectableText?,
                 pressScale: CGFloat, onReact: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.originFrame = originFrame
        self.isOutgoing = isOutgoing
        self.myReaction = myReaction
        self.items = items
        self.onReact = onReact
        super.init(frame: .zero)

        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)
        // a blur alone is not enough: the feed is dark bubbles on a light background and
        // they stay legible as blobs. The wash on top flattens them into an even field and
        // fades out towards the selected message so it keeps the focus
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.backgroundColor = UIColor(Theme.palette.chatBackground)
        scrim.alpha = 0
        addSubview(scrim)
        let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTap(_:)))
        // otherwise the gesture cancels touches on the menu and reaction buttons and none of them press
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)

        snapshot.frame = originFrame
        // starts at the press dip the finger is holding; animateIn springs it to identity
        if pressScale < 1 {
            snapshot.transform = CGAffineTransform(scaleX: pressScale, y: pressScale)
        }
        addSubview(snapshot)
        if let selectableText { buildSelectableText(selectableText) }

        buildReactionBar()
        buildMenuCard(items: items)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
        scrim.frame = bounds
        // the gradient is built around the message: transparent at the message, full
        // density towards the edges of the screen
        let focus = snapshot.frame.midY / max(bounds.height, 1)
        scrimMask.frame = bounds
        scrimMask.colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0).cgColor,
                            UIColor.white.cgColor]
        scrimMask.locations = [0,
                               NSNumber(value: Float(min(max(focus, 0.05), 0.95))),
                               1]
        scrim.layer.mask = scrimMask
    }

    // MARK: - Geometry

    /// Target position of the bubble: it moves vertically until the reactions above and
    /// the menu below both fit inside the safe area. A bubble taller than the free space
    /// is trimmed (the way TG does it) while staying pinned to its own side.
    private func targetBubbleFrame() -> CGRect {
        let safe = safeAreaInsets
        let menuH = menuHeight(for: items)
        let topNeeded = Self.barHeight + Self.gap
        let bottomNeeded = Self.gap + menuH
        let minY = safe.top + 8 + topNeeded
        let availH = bounds.height - safe.bottom - 8 - bottomNeeded - minY
        var f = originFrame
        if f.height > availH {
            // a giant bubble is cropped rather than scaled, which would turn it into a
            // thread: the top part is shown 1:1, and animateIn sets contentMode .top
            f.size.height = availH
            f.origin.y = minY
            return f
        }
        let maxY = bounds.height - safe.bottom - 8 - bottomNeeded - f.height
        f.origin.y = min(max(f.origin.y, minY), max(maxY, minY))
        return f
    }

    private func menuHeight(for items: [Item]) -> CGFloat {
        // a thick separator precedes the first destructive group
        let hasDestructive = items.contains { $0.destructive }
        return CGFloat(items.count) * Self.rowHeight + (hasDestructive ? 6 : 0)
    }

    /// The edge the reactions and the menu are pinned to: the bubble's own side.
    private func alignedX(width: CGFloat, bubble: CGRect) -> CGFloat {
        let x = isOutgoing ? bubble.maxX - width : bubble.minX
        return min(max(x, 8), bounds.width - width - 8)
    }

    // MARK: - Text selection

    /// Live text over the snapshot: dragging across it selects right here.
    private func buildSelectableText(_ spec: SelectableText) {
        // TextKit 1: the same stack the feed measured and drew the text with,
        // so the lines land exactly on the snapshot
        let tv = UITextView(usingTextLayoutManager: false)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.maximumNumberOfLines = 0
        tv.tintColor = UIColor(Theme.accent)
        let coloured = MessageTextView.coloured(spec.attributed, color: spec.color,
                                                linkColor: spec.linkColor)
        // the code block backdrop: the feed draws it in MessageTextView, here it comes
        // as an attribute — the snapshot under the text no longer carries it
        coloured.enumerateAttribute(.msngrCodeBlock,
                                    in: NSRange(location: 0, length: coloured.length)) { value, range, _ in
            guard value != nil else { return }
            coloured.addAttribute(.backgroundColor, value: spec.codeBackground, range: range)
        }
        tv.attributedText = coloured
        tv.frame = spec.frame
        tv.accessibilityIdentifier = "chat.liftedText"
        // the overlay's gesture drives the selection, so the text view's own recognisers
        // get no touches: otherwise they take them and the drag stops working
        tv.isUserInteractionEnabled = false
        // the snapshot is an image and images take no touches — the text over it
        // would get none either
        snapshot.isUserInteractionEnabled = true
        snapshot.addSubview(tv)
        textView = tv

        // the gesture lives on the overlay: a non-editable non-scrolling UITextView
        // passes touches through and receives none itself
        let drag = UIPanGestureRecognizer(target: self, action: #selector(textDrag(_:)))
        addGestureRecognizer(drag)
        snapshot.addInteraction(editMenu)
    }

    @objc private func textDrag(_ g: UIPanGestureRecognizer) {
        guard let tv = textView else { return }
        let point = g.location(in: tv)
        switch g.state {
        case .began:
            // the drag is not over the text: nothing to select, the gesture goes to the backdrop
            guard tv.bounds.insetBy(dx: -8, dy: -8).contains(point) else {
                dragAnchor = nil
                return
            }
            tv.becomeFirstResponder()
            dragAnchor = tv.closestPosition(to: point)
            Haptics.light()
        case .changed:
            guard let anchor = dragAnchor, let now = tv.closestPosition(to: point) else { return }
            let ordered = tv.compare(anchor, to: now) == .orderedAscending
                ? (anchor, now) : (now, anchor)
            tv.selectedTextRange = tv.textRange(from: ordered.0, to: ordered.1)
        case .ended, .cancelled, .failed:
            dragAnchor = nil
            guard let range = tv.selectedTextRange, !range.isEmpty else { return }
            let source = g.location(in: snapshot)
            editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: source))
        default:
            break
        }
    }

    private func copySelection() {
        guard let tv = textView, let range = tv.selectedTextRange,
              let text = tv.text(in: range), !text.isEmpty else { return }
        UIPasteboard.general.string = text
        Haptics.light()
        dismiss()
    }

    // MARK: - Reactions

    private func buildReactionBar() {
        reactionBar.backgroundColor = .systemBackground
        reactionBar.layer.cornerRadius = Self.barHeight / 2
        reactionBar.layer.shadowColor = UIColor.black.cgColor
        reactionBar.layer.shadowOpacity = 0.12
        reactionBar.layer.shadowRadius = 12
        reactionBar.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(reactionBar)

        for (i, emoji) in Self.quickReactions.enumerated() {
            let btn = UIButton(type: .system)
            btn.setTitle(emoji, for: .normal)
            btn.titleLabel?.font = Theme.Text.largeControl.uiFont
            btn.tag = i
            btn.addTarget(self, action: #selector(reactionTap(_:)), for: .touchUpInside)
            if emoji == myReaction {
                btn.backgroundColor = UIColor(Theme.accent).withAlphaComponent(0.18)
                btn.layer.cornerRadius = 17
            }
            reactionBar.addSubview(btn)
            emojiButtons.append(btn)
        }
    }

    private func layoutReactionBar(bubble: CGRect) {
        let n = CGFloat(Self.quickReactions.count)
        let slot: CGFloat = 38
        let width = n * slot + 10
        reactionBar.frame = CGRect(x: alignedX(width: width, bubble: bubble),
                                   y: bubble.minY - Self.gap - Self.barHeight,
                                   width: width, height: Self.barHeight)
        for (i, btn) in emojiButtons.enumerated() {
            btn.frame = CGRect(x: 5 + CGFloat(i) * slot, y: 5, width: slot, height: 34)
        }
    }

    @objc private func reactionTap(_ sender: UIButton) {
        Haptics.rigid()
        let emoji = Self.quickReactions[sender.tag]
        UIView.animate(withDuration: 0.18, animations: {
            sender.transform = CGAffineTransform(scaleX: 1.6, y: 1.6)
        })
        onReact(emoji)
        dismiss()
    }

    // MARK: - Menu

    private func buildMenuCard(items: [Item]) {
        menuCard.backgroundColor = .clear
        menuCard.layer.cornerRadius = 14
        menuCard.layer.shadowColor = UIColor.black.cgColor
        menuCard.layer.shadowOpacity = 0.14
        menuCard.layer.shadowRadius = 16
        menuCard.layer.shadowOffset = CGSize(width: 0, height: 6)
        addSubview(menuCard)

        let bg = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        bg.layer.cornerRadius = 14
        bg.clipsToBounds = true
        bg.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        bg.frame = menuCard.bounds
        menuCard.addSubview(bg)

        menuStack.axis = .vertical
        menuStack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        menuStack.frame = menuCard.bounds
        bg.contentView.addSubview(menuStack)

        fillMenu(items: items)
    }

    private func fillMenu(items: [Item]) {
        menuStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var destructiveStarted = false
        for (i, item) in items.enumerated() {
            if item.destructive && !destructiveStarted {
                destructiveStarted = true
                let thick = UIView()
                thick.backgroundColor = UIColor.separator.withAlphaComponent(0.2)
                thick.heightAnchor.constraint(equalToConstant: 6).isActive = true
                menuStack.addArrangedSubview(thick)
            } else if i > 0 {
                let hair = UIView()
                hair.backgroundColor = UIColor.separator.withAlphaComponent(0.5)
                hair.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
                menuStack.addArrangedSubview(hair)
            }
            let row = MenuRow(item: item)
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
            row.onTap = { [weak self] in self?.rowTapped(item) }
            menuStack.addArrangedSubview(row)
        }
    }

    private func rowTapped(_ item: Item) {
        if !item.submenu.isEmpty {
            Haptics.light()
            items = item.submenu
            UIView.transition(with: menuCard, duration: 0.2, options: .transitionCrossDissolve) {
                self.fillMenu(items: self.items)
            }
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0) {
                self.layoutMenu(bubble: self.snapshot.frame)
            }
            return
        }
        item.handler?()
        dismiss()
    }

    private func layoutMenu(bubble: CGRect) {
        let h = menuHeight(for: items)
        menuCard.frame = CGRect(x: alignedX(width: Self.menuWidth, bubble: bubble),
                                y: bubble.maxY + Self.gap, width: Self.menuWidth, height: h)
    }

    // MARK: - Animations

    private func animateIn() {
        layoutIfNeeded()
        let target = targetBubbleFrame()
        if target.height < originFrame.height - 0.5, let iv = snapshot as? UIImageView {
            iv.contentMode = .top
            iv.clipsToBounds = true
            iv.layer.cornerRadius = Theme.bubbleCorner
        }
        layoutReactionBar(bubble: target)
        layoutMenu(bubble: target)

        let barAnchor = CGPoint(x: isOutgoing ? 1 : 0, y: 1)
        setAnchor(barAnchor, for: reactionBar)
        setAnchor(CGPoint(x: isOutgoing ? 1 : 0, y: 0), for: menuCard)
        reactionBar.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        reactionBar.alpha = 0
        menuCard.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        menuCard.alpha = 0
        for btn in emojiButtons { btn.transform = CGAffineTransform(scaleX: 0.01, y: 0.01) }

        UIView.animate(withDuration: 0.3) {
            self.blurView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
            self.scrim.alpha = 0.82
        }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
            // the transform goes first: with it back at identity the frame set below
            // lands on the true target geometry
            self.snapshot.transform = .identity
            self.snapshot.frame = target
        }
        UIView.animate(withDuration: 0.4, delay: 0.05, usingSpringWithDamping: 0.75, initialSpringVelocity: 0.4) {
            self.reactionBar.transform = .identity
            self.reactionBar.alpha = 1
            self.menuCard.transform = .identity
            self.menuCard.alpha = 1
        }
        for (i, btn) in emojiButtons.enumerated() {
            UIView.animate(withDuration: 0.35, delay: 0.08 + Double(i) * 0.03,
                           usingSpringWithDamping: 0.6, initialSpringVelocity: 0.5) {
                btn.transform = .identity
            }
        }
    }

    @objc private func backgroundTap(_ g: UITapGestureRecognizer) {
        let p = g.location(in: self)
        if reactionBar.frame.contains(p) || menuCard.frame.contains(p) || snapshot.frame.contains(p) { return }
        dismiss()
    }

    private func dismiss() {
        isUserInteractionEnabled = false
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0) {
            self.snapshot.frame = self.originFrame
            self.reactionBar.alpha = 0
            self.reactionBar.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            self.menuCard.alpha = 0
            self.menuCard.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
        }
        UIView.animate(withDuration: 0.28, delay: 0.05, options: []) {
            self.blurView.effect = nil
            self.scrim.alpha = 0
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    /// Changes the anchorPoint without visually moving the frame.
    private func setAnchor(_ anchor: CGPoint, for view: UIView) {
        let f = view.frame
        view.layer.anchorPoint = anchor
        view.frame = f
    }
}

extension MessageContextOverlay: UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction,
                             menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [UIAction(title: "Скопировать") { [weak self] _ in self?.copySelection() }])
    }
}

/// A menu row: title on the left, SF icon on the right, like the system iOS menu.
private final class MenuRow: UIControl {
    var onTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let iconView = UIImageView()

    init(item: MessageContextOverlay.Item) {
        super.init(frame: .zero)
        titleLabel.text = item.title
        titleLabel.font = Theme.Text.menuItem.uiFont
        titleLabel.textColor = item.destructive ? .systemRed : .label
        iconView.image = UIImage(systemName: item.icon)
        iconView.tintColor = item.destructive ? .systemRed : .label
        iconView.contentMode = .scaleAspectFit
        addSubview(titleLabel)
        addSubview(iconView)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        titleLabel.frame = CGRect(x: 16, y: 0, width: bounds.width - 60, height: bounds.height)
        iconView.frame = CGRect(x: bounds.width - 38, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    override var isHighlighted: Bool {
        didSet { backgroundColor = isHighlighted ? UIColor.separator.withAlphaComponent(0.25) : .clear }
    }

    @objc private func tapped() { onTap?() }
}
