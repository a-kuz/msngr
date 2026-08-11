import UIKit
import MsngrCore

/// Ячейка сообщения: ручной layout по BubbleLayoutPlan, ноль Auto Layout.
final class MessageCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onContextAction: ((MessageContextAction) -> Void)?
    var onTapMedia: ((Int, UIView) -> Void)?

    private let bubbleView = UIImageView()
    private let textLabel = UILabel()
    private let nameLabel = UILabel()
    private let forwardLabel = UILabel()
    private let replyBar = ReplyStripView()
    private let timeLabel = UILabel()
    private let tickView = UIImageView()
    private let statusBackdrop = UIView()
    private var mediaViews: [UIImageView] = []
    private var reactionViews: [ReactionCapsuleView] = []
    private let voiceView = VoiceMessageView()
    private var msg: Message?
    private var plan: BubbleLayoutPlan?
    private var configuredMsgId: String?

    // swipe-to-reply
    private var panStartX: CGFloat = 0
    private let replyIcon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var replyTriggered = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        bubbleView.isUserInteractionEnabled = true
        contentView.addSubview(bubbleView)

        textLabel.numberOfLines = 0
        textLabel.font = BubbleLayout.textFont
        bubbleView.addSubview(textLabel)

        nameLabel.font = BubbleLayout.nameFont
        bubbleView.addSubview(nameLabel)

        forwardLabel.font = .italicSystemFont(ofSize: 13)
        forwardLabel.textColor = .secondaryLabel
        bubbleView.addSubview(forwardLabel)

        bubbleView.addSubview(replyBar)

        timeLabel.font = BubbleLayout.timeFont
        statusBackdrop.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        statusBackdrop.layer.cornerRadius = 10
        bubbleView.addSubview(statusBackdrop)
        bubbleView.addSubview(timeLabel)
        tickView.contentMode = .scaleAspectFit
        bubbleView.addSubview(tickView)
        bubbleView.addSubview(voiceView)

        replyIcon.tintColor = .secondaryLabel
        replyIcon.alpha = 0
        contentView.addSubview(replyIcon)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        contentView.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        bubbleView.addGestureRecognizer(doubleTap)

        let interaction = UIContextMenuInteraction(delegate: self)
        bubbleView.addInteraction(interaction)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        mediaViews.forEach { $0.removeFromSuperview() }
        mediaViews = []
        reactionViews.forEach { $0.removeFromSuperview() }
        reactionViews = []
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        // сброс незавершённого свайпа-reply
        bubbleView.transform = .identity
        replyIcon.alpha = 0
        replyTriggered = false
    }

    func configure(msg: Message, plan: BubbleLayoutPlan) {
        self.msg = msg
        self.plan = plan

        bubbleView.frame = plan.bubbleFrame
        bubbleView.image = BubbleBackground.image(outgoing: plan.isOutgoing, tail: plan.showTail,
                                                  mediaOnly: plan.statusOnMedia)

        // текст
        if let tf = plan.textFrame, let text = plan.text {
            textLabel.isHidden = false
            textLabel.attributedText = text
            textLabel.textColor = msg.deletedForAll ? .secondaryLabel : .label
            textLabel.frame = tf
        } else {
            textLabel.isHidden = true
        }

        // имя автора
        if let nf = plan.authorNameFrame {
            nameLabel.isHidden = false
            nameLabel.text = plan.authorName
            nameLabel.textColor = NameColor.color(for: msg.fromUserId)
            nameLabel.frame = nf
        } else {
            nameLabel.isHidden = true
        }

        // форвард
        if let ff = plan.forwardFrame {
            forwardLabel.isHidden = false
            forwardLabel.text = plan.forwardText
            forwardLabel.frame = ff
        } else {
            forwardLabel.isHidden = true
        }

        // reply
        if let rf = plan.replyFrame {
            replyBar.isHidden = false
            replyBar.configure(author: plan.replyAuthor ?? "", text: plan.replyText ?? "")
            replyBar.frame = rf
        } else {
            replyBar.isHidden = true
        }

        // медиа
        configureMedia(msg: msg, plan: plan)

        // voice / file
        if let vf = plan.voiceFrame {
            voiceView.isHidden = false
            voiceView.frame = vf
            voiceView.configure(msg: msg)
        } else {
            voiceView.isHidden = true
        }

        // статус: время + галочки
        timeLabel.text = (plan.edited ? "изм. " : "") + plan.timeString
        timeLabel.textColor = plan.statusOnMedia ? .white
            : (plan.isOutgoing ? UIColor(Theme.readTick).withAlphaComponent(0.9) : .secondaryLabel)
        statusBackdrop.isHidden = !plan.statusOnMedia
        if plan.statusOnMedia {
            statusBackdrop.frame = plan.statusFrame.insetBy(dx: -6, dy: -1)
        }
        var timeFrame = plan.statusFrame
        if plan.isOutgoing {
            timeFrame.size.width -= 20
            tickView.isHidden = false
            tickView.frame = CGRect(x: plan.statusFrame.maxX - 19, y: plan.statusFrame.minY + 1,
                                    width: 18, height: 13)
            tickView.image = Self.tickImage(msg.status)
            tickView.tintColor = plan.statusOnMedia ? .white
                : (msg.status == .read ? UIColor(Theme.readTick) : .secondaryLabel)
        } else {
            tickView.isHidden = true
        }
        timeLabel.frame = timeFrame

        // реакции: анимируем появление только реально новой реакции при обновлении той же
        // ячейки; при переиспользовании на скролле — без анимации
        let sameCell = configuredMsgId == msg.id
        let previousKeys = Set(reactionViews.map { $0.emojiKey })
        reactionViews.forEach { $0.removeFromSuperview() }
        reactionViews = []
        for r in plan.reactionsFrames {
            let capsule = ReactionCapsuleView()
            let animateIn = sameCell && !previousKeys.contains(r.emoji)
            capsule.configure(emoji: r.emoji, count: r.count, mine: r.mine,
                              outgoing: plan.isOutgoing, animateIn: animateIn)
            capsule.frame = r.frame
            capsule.onTap = { [weak self] in self?.onReact?(r.emoji) }
            bubbleView.addSubview(capsule)
            reactionViews.append(capsule)
        }
        configuredMsgId = msg.id
    }

    private func configureMedia(msg: Message, plan: BubbleLayoutPlan) {
        guard let mediaFrame = plan.mediaFrame else { return }
        let rects: [(Int, CGRect)] = plan.albumRects.isEmpty
            ? [(0, mediaFrame)]
            : plan.albumRects.map { ($0.index, $0.frame.offsetBy(dx: mediaFrame.minX, dy: mediaFrame.minY)) }
        let medias: [MediaInfo] = msg.album ?? (msg.media.map { [$0] } ?? [])

        for (index, rect) in rects {
            guard index < medias.count else { continue }
            let media = medias[index]
            let iv = UIImageView()
            iv.frame = rect
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.backgroundColor = .tertiarySystemFill
            iv.isUserInteractionEnabled = true
            iv.layer.cornerRadius = plan.albumRects.isEmpty ? Theme.bubbleCorner : 4
            iv.layer.cornerCurve = .continuous
            iv.tag = index
            let tap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped(_:)))
            iv.addGestureRecognizer(tap)
            bubbleView.addSubview(iv)
            mediaViews.append(iv)

            // blurhash-плейсхолдер мгновенно, потом реальная картинка
            if let bh = media.blurhash, let px = BlurHash.decodePixels(bh, width: 32, height: 32) {
                iv.image = UIImage.fromRGBA(px, width: 32, height: 32)
            }
            let scale = UIScreen.main.scale
            let target = CGSize(width: rect.width * scale, height: rect.height * scale)
            let isVideo = media.type == "video"
            Task { [weak iv] in
                guard let mm = AppState.shared.media else { return }
                let effective: MediaInfo = {
                    if isVideo, media.thumbMediaId != nil {
                        var t = MediaInfo(type: "photo", mediaId: media.thumbMediaId!,
                                          key: media.thumbKey ?? "", hash: media.thumbHash ?? "",
                                          size: 0, mime: "image/jpeg")
                        return t
                    }
                    return media
                }()
                guard let url = try? await mm.fetch(effective) else { return }
                let cg = await ImagePipeline.shared.image(at: url, targetPixelSize: target)
                await MainActor.run {
                    guard let iv, iv.tag == index, let cg else { return }
                    UIView.transition(with: iv, duration: 0.18, options: .transitionCrossDissolve) {
                        iv.image = UIImage(cgImage: cg)
                    }
                }
            }

            if isVideo {
                let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
                play.tintColor = .white.withAlphaComponent(0.9)
                play.frame = CGRect(x: rect.width / 2 - 22, y: rect.height / 2 - 22, width: 44, height: 44)
                play.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                         .flexibleTopMargin, .flexibleBottomMargin]
                iv.addSubview(play)
            }
        }
    }

    @objc private func mediaTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view else { return }
        onTapMedia?(v.tag, v)
    }

    @objc private func handleDoubleTap() {
        Haptics.medium()
        onReact?("❤️")
    }

    // MARK: - Swipe-to-reply с резистенцией

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        let v = pan.velocity(in: contentView)
        return abs(v.x) > abs(v.y) && v.x > 0
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: contentView).x
        switch g.state {
        case .changed:
            let capped = min(max(tx, 0), 90)
            let resisted = 60 * (1 - exp(-capped / 60)) // резистенция
            bubbleView.transform = CGAffineTransform(translationX: resisted, y: 0)
            replyIcon.frame = CGRect(x: bubbleView.frame.minX - 34, y: bubbleView.frame.midY - 11,
                                     width: 22, height: 22)
            replyIcon.alpha = resisted / 60
            if resisted > 44 && !replyTriggered {
                replyTriggered = true
                Haptics.medium()
            }
        case .ended, .cancelled:
            if replyTriggered { onReply?() }
            replyTriggered = false
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0) {
                self.bubbleView.transform = .identity
                self.replyIcon.alpha = 0
            }
        default:
            break
        }
    }

    static func tickImage(_ status: MessageStatus) -> UIImage? {
        switch status {
        case .failed: return UIImage(systemName: "exclamationmark.circle.fill")
        case .sending: return UIImage(systemName: "clock")
        case .sent: return UIImage(systemName: "checkmark")
        case .delivered, .read: return doubleTick
        }
    }

    static let doubleTick: UIImage = {
        let size = CGSize(width: 18, height: 13)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            let check = UIImage(systemName: "checkmark", withConfiguration: cfg)!
                .withTintColor(.white, renderingMode: .alwaysOriginal)
            check.draw(in: CGRect(x: 0, y: 1.5, width: 11, height: 10))
            check.draw(in: CGRect(x: 5, y: 1.5, width: 11, height: 10))
        }.withRenderingMode(.alwaysTemplate)
    }()
}

// MARK: - Компоненты

/// Фоны бабблов: ресайзабл-картинки с хвостиком, без offscreen-rendering.
enum BubbleBackground {
    private static var cache: [String: UIImage] = [:]

    static func image(outgoing: Bool, tail: Bool, mediaOnly: Bool) -> UIImage {
        let key = "\(outgoing)|\(tail)|\(mediaOnly)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let img = cache[key] { return img }
        let size = CGSize(width: 44, height: 40)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let color = mediaOnly ? UIColor.clear
                : UIColor(outgoing ? Theme.outgoingBubble : Theme.incomingBubble)
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: Theme.bubbleCorner)
            color.setFill()
            path.fill()
            if tail && !mediaOnly {
                // хвостик снизу у соответствующего края
                let tailPath = UIBezierPath()
                let x: CGFloat = outgoing ? size.width - 2 : 2
                let dir: CGFloat = outgoing ? 1 : -1
                tailPath.move(to: CGPoint(x: x, y: size.height - 14))
                tailPath.addQuadCurve(to: CGPoint(x: x + dir * 6, y: size.height - 1),
                                      controlPoint: CGPoint(x: x, y: size.height - 5))
                tailPath.addQuadCurve(to: CGPoint(x: x - dir * 8, y: size.height - 4),
                                      controlPoint: CGPoint(x: x - dir * 2, y: size.height - 1))
                tailPath.close()
                color.setFill()
                tailPath.fill()
            }
        }
        .resizableImage(withCapInsets: UIEdgeInsets(top: 19, left: 21, bottom: 19, right: 21))
        cache[key] = img
        return img
    }
}

/// Цвет имени автора в группе — стабильный по userId.
enum NameColor {
    static let palette: [UIColor] = [
        .systemRed, .systemOrange, .systemPurple, .systemGreen,
        .systemCyan, .systemBlue, .systemPink,
    ]
    static func color(for userId: String) -> UIColor {
        palette[abs(userId.hashValue) % palette.count]
    }
}

final class ReplyStripView: UIView {
    private let bar = UIView()
    private let authorLabel = UILabel()
    private let textLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.backgroundColor = UIColor(Theme.accent)
        bar.layer.cornerRadius = 1.5
        authorLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        authorLabel.textColor = UIColor(Theme.accent)
        textLabel.font = .systemFont(ofSize: 13)
        textLabel.textColor = .secondaryLabel
        addSubview(bar)
        addSubview(authorLabel)
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(author: String, text: String) {
        authorLabel.text = author
        textLabel.text = text
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        bar.frame = CGRect(x: 0, y: 2, width: 3, height: bounds.height - 4)
        authorLabel.frame = CGRect(x: 9, y: 2, width: bounds.width - 9, height: 16)
        textLabel.frame = CGRect(x: 9, y: 18, width: bounds.width - 9, height: 16)
    }
}

final class ReactionCapsuleView: UIControl {
    private let label = UILabel()
    var onTap: (() -> Void)?
    private(set) var emojiKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 13
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(emoji: String, count: Int, mine: Bool, outgoing: Bool, animateIn: Bool) {
        emojiKey = emoji
        label.text = count > 1 ? "\(emoji) \(count)" : emoji
        backgroundColor = mine ? UIColor(Theme.accent).withAlphaComponent(0.85)
            : UIColor.systemGray5.withAlphaComponent(0.9)
        label.textColor = mine ? .white : .label
        // spring-появление только для реально новой реакции
        if animateIn {
            transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            alpha = 0
            UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.6, initialSpringVelocity: 0.4) {
                self.transform = .identity
                self.alpha = 1
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds
    }

    @objc private func tapped() {
        UIView.animate(withDuration: 0.12, animations: { self.transform = CGAffineTransform(scaleX: 1.25, y: 1.25) }) { _ in
            UIView.animate(withDuration: 0.25, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
                self.transform = .identity
            }
        }
        onTap?()
    }
}

// MARK: - Контекстное меню

extension MessageCell: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let msg, !msg.deletedForAll else { return nil }
        Haptics.medium()
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            // строка быстрых реакций
            let reactions = ["❤️", "👍", "🔥", "😂", "😮", "😢"]
            let reactionActions = reactions.map { emoji in
                UIAction(title: emoji) { _ in self?.onReact?(emoji) }
            }
            actions.append(UIMenu(title: "Реакция", options: .displayInline, children: reactionActions))
            actions.append(UIAction(title: "Ответить", image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                self?.onContextAction?(.reply)
            })
            if msg.kind == .text {
                actions.append(UIAction(title: "Копировать", image: UIImage(systemName: "doc.on.doc")) { _ in
                    self?.onContextAction?(.copy)
                })
            }
            actions.append(UIAction(title: "Переслать", image: UIImage(systemName: "arrowshape.turn.up.right")) { _ in
                self?.onContextAction?(.forward)
            })
            actions.append(UIAction(title: "Закрепить", image: UIImage(systemName: "pin")) { _ in
                self?.onContextAction?(.pin)
            })
            if msg.isOutgoing && msg.kind == .text {
                actions.append(UIAction(title: "Изменить", image: UIImage(systemName: "pencil")) { _ in
                    self?.onContextAction?(.edit)
                })
            }
            let deleteMenu = UIMenu(title: "Удалить", image: UIImage(systemName: "trash"),
                                    options: .destructive, children: [
                UIAction(title: "Удалить у меня", attributes: .destructive) { _ in
                    self?.onContextAction?(.deleteForMe)
                },
                UIAction(title: "Удалить у всех", attributes: .destructive) { _ in
                    self?.onContextAction?(.deleteForAll)
                },
            ])
            actions.append(deleteMenu)
            return UIMenu(children: actions)
        }
    }
}

extension UIImage {
    static func fromRGBA(_ pixels: [UInt8], width: Int, height: Int) -> UIImage? {
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: provider, decode: nil, shouldInterpolate: true,
                               intent: .defaultIntent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
