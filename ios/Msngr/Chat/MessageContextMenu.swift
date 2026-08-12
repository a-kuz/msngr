import UIKit
import SwiftUI

/// Контекстное меню сообщения: блюр фона, баббл приподнимается,
/// над ним горизонтальный ряд быстрых реакций, под ним карточка действий.
final class MessageContextOverlay: UIView {
    struct Item {
        let title: String
        let icon: String
        var destructive = false
        var submenu: [Item] = []
        var handler: (() -> Void)?
    }

    static let quickReactions = ["❤️", "👍", "🔥", "😂", "😮", "😢"]

    private let blurView = UIVisualEffectView(effect: nil)
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

    private static let menuWidth: CGFloat = 252
    private static let rowHeight: CGFloat = 44
    private static let barHeight: CGFloat = 44
    private static let gap: CGFloat = 8

    // MARK: - Показ

    static func present(over bubble: UIView, in window: UIWindow, isOutgoing: Bool,
                        myReaction: String?, items: [Item], onReact: @escaping (String) -> Void) {
        guard let snap = bubble.snapshotView(afterScreenUpdates: false) else { return }
        let frame = bubble.convert(bubble.bounds, to: window)
        let overlay = MessageContextOverlay(snapshot: snap, originFrame: frame, isOutgoing: isOutgoing,
                                            myReaction: myReaction, items: items, onReact: onReact)
        overlay.frame = window.bounds
        window.addSubview(overlay)
        overlay.animateIn()
    }

    private init(snapshot: UIView, originFrame: CGRect, isOutgoing: Bool,
                 myReaction: String?, items: [Item], onReact: @escaping (String) -> Void) {
        self.snapshot = snapshot
        self.originFrame = originFrame
        self.isOutgoing = isOutgoing
        self.myReaction = myReaction
        self.items = items
        self.onReact = onReact
        super.init(frame: .zero)

        blurView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(blurView)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(backgroundTap(_:))))

        snapshot.frame = originFrame
        addSubview(snapshot)

        buildReactionBar()
        buildMenuCard(items: items)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        blurView.frame = bounds
    }

    // MARK: - Геометрия

    /// Целевая позиция баббла: сдвигаем по вертикали так, чтобы реакции сверху
    /// и меню снизу поместились в safe area. По горизонтали баббл не трогаем.
    private func targetBubbleFrame() -> CGRect {
        let safe = safeAreaInsets
        let menuH = menuHeight(for: items)
        let topNeeded = Self.barHeight + Self.gap
        let bottomNeeded = Self.gap + menuH
        let minY = safe.top + 8 + topNeeded
        let maxY = bounds.height - safe.bottom - 8 - bottomNeeded - originFrame.height
        var f = originFrame
        f.origin.y = min(max(f.origin.y, minY), max(maxY, minY))
        return f
    }

    private func menuHeight(for items: [Item]) -> CGFloat {
        // толстый разделитель перед первой деструктивной группой
        let hasDestructive = items.contains { $0.destructive }
        return CGFloat(items.count) * Self.rowHeight + (hasDestructive ? 6 : 0)
    }

    /// Край, к которому прижимаем реакции и меню: сторона баббла.
    private func alignedX(width: CGFloat, bubble: CGRect) -> CGFloat {
        let x = isOutgoing ? bubble.maxX - width : bubble.minX
        return min(max(x, 8), bounds.width - width - 8)
    }

    // MARK: - Реакции

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
            btn.titleLabel?.font = .systemFont(ofSize: 28)
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

    // MARK: - Меню

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

    // MARK: - Анимации

    private func animateIn() {
        layoutIfNeeded()
        let target = targetBubbleFrame()
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

        UIView.animate(withDuration: 0.25) {
            self.blurView.effect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.8, initialSpringVelocity: 0.4) {
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
        } completion: { _ in
            self.removeFromSuperview()
        }
    }

    /// Меняет anchorPoint без визуального сдвига фрейма.
    private func setAnchor(_ anchor: CGPoint, for view: UIView) {
        let f = view.frame
        view.layer.anchorPoint = anchor
        view.frame = f
    }
}

/// Строка меню: заголовок слева, SF-иконка справа (как в системном меню iOS).
private final class MenuRow: UIControl {
    var onTap: (() -> Void)?
    private let titleLabel = UILabel()
    private let iconView = UIImageView()

    init(item: MessageContextOverlay.Item) {
        super.init(frame: .zero)
        titleLabel.text = item.title
        titleLabel.font = .systemFont(ofSize: 17)
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
