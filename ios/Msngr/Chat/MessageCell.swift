import UIKit
import MsngrCore

/// Ячейка сообщения: ручной layout по BubbleLayoutPlan, ноль Auto Layout.
final class MessageCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onContextAction: ((MessageContextAction) -> Void)?
    var onTapMedia: ((Int, UIView) -> Void)?
    var onTapLink: ((URL) -> Void)?
    var onTapReplyQuote: (() -> Void)?

    private let bubbleView = UIImageView()
    private let tailView = UIImageView()
    private let textView = MessageTextView()
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
        // хвостик — subview тела: наследует его transform/alpha при анимациях
        // (появление, swipe-to-reply, «вылет» при отправке) без лишнего кода;
        // clipsToBounds у bubbleView не включён, так что вылет за пределы
        // тела (сам хвост) не обрезается
        bubbleView.addSubview(tailView)

        bubbleView.addSubview(textView)

        nameLabel.font = BubbleLayout.nameFont
        bubbleView.addSubview(nameLabel)

        forwardLabel.font = .italicSystemFont(ofSize: 13)
        forwardLabel.textColor = .secondaryLabel
        bubbleView.addSubview(forwardLabel)

        bubbleView.addSubview(replyBar)

        timeLabel.font = BubbleLayout.timeFont
        // время прижато к правому краю своего фрейма: запас ширины из замера
        // не оставляет рваного зазора справа
        timeLabel.textAlignment = .right
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

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        bubbleView.addGestureRecognizer(longPress)

        // одиночный тап отрабатывает только попадание по ссылке; двойной тап
        // (реакция) имеет приоритет, остальные касания проходят насквозь
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.cancelsTouchesInView = false
        bubbleView.addGestureRecognizer(tap)

        // тап только по области цитаты; удержание отдаёт жест контекстному меню,
        // двойной тап — реакции
        let replyTap = UITapGestureRecognizer(target: self, action: #selector(handleReplyQuoteTap))
        replyTap.require(toFail: longPress)
        replyTap.require(toFail: doubleTap)
        replyBar.addGestureRecognizer(replyTap)
    }

    @objc private func handleReplyQuoteTap() {
        guard msg?.replyTo != nil else { return }
        onTapReplyQuote?()
    }

    /// Кратковременная вспышка баббла: подтверждает переход к оригиналу.
    func flashHighlight() {
        bubbleView.viewWithTag(Self.highlightTag)?.removeFromSuperview()
        let overlay = UIView(frame: bubbleView.bounds)
        overlay.tag = Self.highlightTag
        overlay.backgroundColor = UIColor(Theme.accent).withAlphaComponent(0.3)
        overlay.layer.cornerRadius = Theme.bubbleCorner
        overlay.layer.cornerCurve = .continuous
        overlay.isUserInteractionEnabled = false
        overlay.alpha = 0
        bubbleView.addSubview(overlay)
        UIView.animate(withDuration: 0.16) {
            overlay.alpha = 1
        } completion: { _ in
            UIView.animate(withDuration: 0.44, delay: 0.06) {
                overlay.alpha = 0
            } completion: { _ in
                overlay.removeFromSuperview()
            }
        }
    }

    private static let highlightTag = 7181

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        reactionViews.forEach { $0.removeFromSuperview() }
        reactionViews = []
        bubbleView.viewWithTag(Self.highlightTag)?.removeFromSuperview()
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        // сброс незавершённого свайпа-reply
        bubbleView.transform = .identity
        replyIcon.alpha = 0
        replyTriggered = false
    }

    /// Появление входящего/восстановленного баббла: короткий подъём.
    func animateAppearance() {
        bubbleView.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.96, y: 0.96)
        bubbleView.alpha = 0.4
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.5, options: [.allowUserInteraction]) {
            self.bubbleView.transform = .identity
            self.bubbleView.alpha = 1
        }
    }

    /// Своё сообщение «вылетает» из кнопки отправки: баббл стартует маленьким
    /// в точке кнопки и пружиной летит на своё место (как в TG/WhatsApp).
    func animateSendFlight(fromScreenPoint point: CGPoint, in source: UIView) {
        layoutIfNeeded()
        // convert учитывает переворот ячейки по Y, считать знаки вручную не нужно
        let start = contentView.convert(point, from: source)
        let target = CGPoint(x: bubbleView.frame.midX, y: bubbleView.frame.midY)
        let dx = start.x - target.x
        let dy = start.y - target.y
        bubbleView.transform = CGAffineTransform(translationX: dx, y: dy)
            .scaledBy(x: 0.15, y: 0.15)
        bubbleView.alpha = 0.5
        bubbleView.layer.cornerRadius = 18
        for sub in [textView, timeLabel, tickView] { sub.alpha = 0 }
        UIView.animate(withDuration: 0.6, delay: 0, usingSpringWithDamping: 0.72,
                       initialSpringVelocity: 1.1, options: [.allowUserInteraction]) {
            self.bubbleView.transform = .identity
            self.bubbleView.alpha = 1
        }
        UIView.animate(withDuration: 0.25, delay: 0.18, options: [.allowUserInteraction]) {
            for sub in [self.textView, self.timeLabel, self.tickView] { sub.alpha = 1 }
        }
    }

    func configure(msg: Message, plan: BubbleLayoutPlan) {
        self.msg = msg
        self.plan = plan

        bubbleView.frame = plan.bubbleFrame
        bubbleView.image = BubbleBackground.image(outgoing: plan.isOutgoing, mediaOnly: plan.statusOnMedia)

        // хвостик — отдельная картинка у нижнего угла тела, торчит за его
        // пределы; тело (закруглённый прямоугольник) от showTail не зависит,
        // поэтому правый/левый край баббла не сдвигается при появлении хвоста
        if plan.showTail && !plan.statusOnMedia {
            tailView.isHidden = false
            tailView.image = BubbleBackground.tailImage(outgoing: plan.isOutgoing)
            let anchorX = BubbleBackground.tailAnchorX(outgoing: plan.isOutgoing)
            let cornerX: CGFloat = plan.isOutgoing ? plan.bubbleFrame.width : 0
            tailView.frame = CGRect(x: cornerX - anchorX,
                                    y: plan.bubbleFrame.height - BubbleBackground.tailAnchorY,
                                    width: BubbleBackground.tailCanvasSize.width,
                                    height: BubbleBackground.tailCanvasSize.height)
        } else {
            tailView.isHidden = true
        }

        // текст
        if let tf = plan.textFrame, let text = plan.text {
            textView.isHidden = false
            textView.frame = tf
            let color: UIColor = msg.deletedForAll
                ? (plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel)
                : (plan.isOutgoing ? UIColor(Theme.outgoingText) : .label)
            textView.configure(text, color: color,
                               linkColor: plan.isOutgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent),
                               codeBackground: Self.codeBackground(outgoing: plan.isOutgoing))
        } else {
            textView.isHidden = true
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
            replyBar.configure(author: plan.replyAuthor ?? "", text: plan.replyText ?? "",
                               outgoing: plan.isOutgoing)
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
            voiceView.configure(msg: msg, outgoing: plan.isOutgoing)
        } else {
            voiceView.isHidden = true
        }

        // статус: время + галочки
        timeLabel.text = (plan.edited ? "изм. " : "") + plan.timeString
        timeLabel.textColor = plan.statusOnMedia ? .white
            : (plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel)
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
                : (msg.status == .read ? UIColor(Theme.outgoingTickRead) : UIColor(Theme.outgoingMeta))
        } else {
            tickView.isHidden = true
        }
        timeLabel.frame = timeFrame
        // медиа-вью добавляются позже статуса — капсула времени должна остаться сверху
        bubbleView.bringSubviewToFront(statusBackdrop)
        bubbleView.bringSubviewToFront(timeLabel)
        bubbleView.bringSubviewToFront(tickView)

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
        // configure вызывается и на живой ячейке (обновление контента на месте) —
        // старые медиа-вью убираем здесь, а не только в prepareForReuse
        mediaViews.forEach { $0.removeFromSuperview() }
        mediaViews = []
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
            if plan.albumRects.isEmpty {
                iv.layer.cornerRadius = Theme.bubbleCorner
            } else if let mf = plan.mediaFrame {
                // мозаика: большой радиус только на внешних углах сетки
                var corners: CACornerMask = []
                let eps: CGFloat = 1.5
                if abs(rect.minX - mf.minX) < eps, abs(rect.minY - mf.minY) < eps { corners.insert(.layerMinXMinYCorner) }
                if abs(rect.maxX - mf.maxX) < eps, abs(rect.minY - mf.minY) < eps { corners.insert(.layerMaxXMinYCorner) }
                if abs(rect.minX - mf.minX) < eps, abs(rect.maxY - mf.maxY) < eps { corners.insert(.layerMinXMaxYCorner) }
                if abs(rect.maxX - mf.maxX) < eps, abs(rect.maxY - mf.maxY) < eps { corners.insert(.layerMaxXMaxYCorner) }
                iv.layer.cornerRadius = corners.isEmpty ? 0 : Theme.bubbleCorner
                iv.layer.maskedCorners = corners
            }
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
                    // превью видео: выгруженный thumb-блоб либо локальный кадр (до аплоада)
                    if isVideo, media.thumbMediaId != nil || media.thumbLocalPath != nil {
                        var t = MediaInfo(type: "photo", mediaId: media.thumbMediaId ?? "",
                                          key: media.thumbKey ?? "", hash: media.thumbHash ?? "",
                                          size: 0, mime: "image/jpeg")
                        t.localPath = media.thumbLocalPath
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

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard !textView.isHidden else { return }
        let point = g.location(in: textView)
        guard let url = textView.url(at: point) else { return }
        onTapLink?(url)
    }

    /// Подложка блока кода: на исходящем баббле — светлее фона, на входящем —
    /// затемнение, различимое и в тёмной теме.
    static func codeBackground(outgoing: Bool) -> UIColor {
        if outgoing { return UIColor(Theme.outgoingText).withAlphaComponent(0.16) }
        return UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
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

/// Фоны бабблов: ресайзабл-картинка тела (без хвоста — правый/левый край
/// тела не зависит от наличия хвоста) + отдельная маленькая картинка
/// хвоста, наложенная поверх тела и торчащая за его пределы.
enum BubbleBackground {
    private static var cache: [String: UIImage] = [:]
    private static var tailCache: [String: UIImage] = [:]

    /// Холст хвоста и точка угла тела баббла внутри этого холста: см. tailImage.
    /// Публичные — MessageCell позиционирует tailView теми же числами.
    static let tailCanvasSize = CGSize(width: 20, height: 18)
    static let tailAnchorY: CGFloat = 16
    static func tailAnchorX(outgoing: Bool) -> CGFloat { outgoing ? 12 : 8 }

    /// Цвета бабблов запечены в картинки — при смене палитры кэш сбрасывается.
    static func clearCache() { cache.removeAll(); tailCache.removeAll() }

    static func image(outgoing: Bool, mediaOnly: Bool) -> UIImage {
        let key = "\(outgoing)|\(mediaOnly)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let img = cache[key] { return img }
        let size = CGSize(width: 44, height: 40)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let color = mediaOnly ? UIColor.clear
                : UIColor(outgoing ? Theme.outgoingBubble : Theme.incomingBubble)
            let rect = CGRect(origin: .zero, size: size)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: Theme.bubbleCorner)
            color.setFill()
            path.fill()
        }
        .resizableImage(withCapInsets: UIEdgeInsets(top: 19, left: 21, bottom: 19, right: 21))
        cache[key] = img
        return img
    }

    /// Хвостик — маленькая нерастягиваемая картинка, накладывается поверх тела
    /// как отдельный subview у соответствующего нижнего угла. Холст с запасом
    /// вокруг кривой, чтобы внешняя часть хвоста не обрезалась по краю; точка
    /// (tailAnchorX, tailAnchorY) — угол тела баббла, к которому хвост крепится.
    static func tailImage(outgoing: Bool) -> UIImage {
        let key = "\(outgoing)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let img = tailCache[key] { return img }
        let size = tailCanvasSize
        let anchorX = tailAnchorX(outgoing: outgoing)
        // старые координаты хвоста были рассчитаны для холста тела 44x40
        // (правый нижний угол в (44,40)); переносим их на холст хвоста тем же
        // сдвигом, которым угол тела (44,40) или (0,40) переезжает в (anchorX, tailAnchorY)
        let dx = anchorX - (outgoing ? 44 : 0)
        let dy = tailAnchorY - 40
        let x: CGFloat = (outgoing ? 44 - 2 : 2) + dx
        let dir: CGFloat = outgoing ? 1 : -1
        let color = UIColor(outgoing ? Theme.outgoingBubble : Theme.incomingBubble)
        let img = UIGraphicsImageRenderer(size: size).image { ctx in
            let tailPath = UIBezierPath()
            tailPath.move(to: CGPoint(x: x, y: 26 + dy))
            tailPath.addQuadCurve(to: CGPoint(x: x + dir * 6, y: 39 + dy),
                                  controlPoint: CGPoint(x: x, y: 35 + dy))
            tailPath.addQuadCurve(to: CGPoint(x: x - dir * 8, y: 36 + dy),
                                  controlPoint: CGPoint(x: x - dir * 2, y: 39 + dy))
            tailPath.close()
            color.setFill()
            tailPath.fill()
        }
        tailCache[key] = img
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
        palette[StableHash.index(userId, modulo: palette.count)]
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

    func configure(author: String, text: String, outgoing: Bool) {
        authorLabel.text = author
        textLabel.text = text
        // на тёмном исходящем баббле акцентные цвета нечитаемы
        bar.backgroundColor = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        authorLabel.textColor = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        textLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
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
        // капсула держится палитры баббла; своя реакция выделена насыщенной заливкой
        if outgoing {
            backgroundColor = mine
                ? UIColor(Theme.outgoingTickRead).withAlphaComponent(0.30)
                : UIColor(Theme.outgoingText).withAlphaComponent(0.16)
            label.textColor = UIColor(Theme.outgoingText)
        } else {
            backgroundColor = mine
                ? UIColor(Theme.accent).withAlphaComponent(0.18)
                : UIColor.tertiarySystemFill
            label.textColor = .label
        }
        // тонкая обводка отделяет капсулу и от входящего, и от исходящего баббла
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
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

extension MessageCell {
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let msg, !msg.deletedForAll,
              let window = window else { return }
        Haptics.medium()

        var items: [MessageContextOverlay.Item] = []
        items.append(.init(title: "Ответить", icon: "arrowshape.turn.up.left") { [weak self] in
            self?.onContextAction?(.reply)
        })
        // фото и альбом копируются картинкой в буфер, текст — строкой
        if msg.kind == .text || msg.kind == .photo || msg.kind == .album {
            items.append(.init(title: "Копировать", icon: "doc.on.doc") { [weak self] in
                self?.onContextAction?(.copy)
            })
        }
        items.append(.init(title: "Переслать", icon: "arrowshape.turn.up.right") { [weak self] in
            self?.onContextAction?(.forward)
        })
        items.append(.init(title: "Закрепить", icon: "pin") { [weak self] in
            self?.onContextAction?(.pin)
        })
        if msg.isOutgoing && msg.kind == .text {
            items.append(.init(title: "Изменить", icon: "pencil") { [weak self] in
                self?.onContextAction?(.edit)
            })
        }
        items.append(.init(title: "Удалить", icon: "trash", destructive: true, submenu: [
            .init(title: "Удалить у меня", icon: "trash", destructive: true) { [weak self] in
                self?.onContextAction?(.deleteForMe)
            },
            .init(title: "Удалить у всех", icon: "trash.fill", destructive: true) { [weak self] in
                self?.onContextAction?(.deleteForAll)
            },
        ]))

        let mine = msg.reactions.first(where: { $0.value.contains(OwnUser.id) })?.key
        MessageContextOverlay.present(over: bubbleView, in: window, isOutgoing: msg.isOutgoing,
                                      myReaction: mine, items: items,
                                      onReact: { [weak self] emoji in self?.onReact?(emoji) })
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
