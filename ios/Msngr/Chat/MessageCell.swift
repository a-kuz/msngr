import UIKit
import MsngrCore

/// Message cell: manual layout driven by BubbleLayoutPlan, no Auto Layout at all.
final class MessageCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onContextAction: ((MessageContextAction) -> Void)?
    /// Whether this message is the pinned one, asked at the moment the menu opens.
    var isPinned: (() -> Bool)?
    var onTapMedia: ((Int, UIView) -> Void)?
    var onTapLink: ((URL) -> Void)?
    var onTapReplyQuote: (() -> Void)?
    var onToggleSelection: (() -> Void)?

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

    // multi-select
    private let checkbox = SelectionCheckboxView()
    private var selectionMode = false
    private var gestures: [UIGestureRecognizer] = []
    private var selectionTap: UITapGestureRecognizer!
    /// how far an incoming bubble moves right to clear room for the checkbox
    static let selectionShift: CGFloat = 34

    var messageId: String? { msg?.id }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)

        bubbleView.isUserInteractionEnabled = true
        contentView.addSubview(bubbleView)
        // the tail is a subview of the body: it inherits the body's transform and alpha
        // through every animation (appearance, swipe-to-reply, the flight out of the send
        // button) for free, and since bubbleView does not clip to bounds the part of the
        // tail that sticks out survives
        bubbleView.addSubview(tailView)

        bubbleView.addSubview(textView)

        bubbleView.addSubview(nameLabel)

        forwardLabel.textColor = .secondaryLabel
        bubbleView.addSubview(forwardLabel)

        bubbleView.addSubview(replyBar)

        // the time is pinned to the right edge of its frame, so the width slack left by
        // measurement does not show up as a ragged gap on the right
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

        checkbox.alpha = 0
        checkbox.isUserInteractionEnabled = false
        contentView.addSubview(checkbox)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        contentView.addGestureRecognizer(pan)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        bubbleView.addGestureRecognizer(doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.35
        bubbleView.addGestureRecognizer(longPress)

        // a single tap only acts on a hit inside a link; the double tap (reaction) wins,
        // and every other touch passes straight through
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.require(toFail: doubleTap)
        tap.cancelsTouchesInView = false
        bubbleView.addGestureRecognizer(tap)

        // tap confined to the quote area; a long press yields to the context menu and a
        // double tap to the reaction
        let replyTap = UITapGestureRecognizer(target: self, action: #selector(handleReplyQuoteTap))
        replyTap.require(toFail: longPress)
        replyTap.require(toFail: doubleTap)
        replyBar.addGestureRecognizer(replyTap)

        // in selection mode only the row tap works, every other gesture is switched off
        gestures = [pan, doubleTap, longPress, tap, replyTap]
        selectionTap = UITapGestureRecognizer(target: self, action: #selector(handleSelectionTap))
        selectionTap.isEnabled = false
        contentView.addGestureRecognizer(selectionTap)
    }

    @objc private func handleSelectionTap() {
        onToggleSelection?()
    }

    /// Multi-select mode: a checkbox next to the row, the incoming bubble shifted right.
    func setSelection(mode: Bool, selected: Bool, animated: Bool) {
        selectionMode = mode
        for g in gestures { g.isEnabled = !mode }
        selectionTap.isEnabled = mode
        checkbox.setChecked(selected, animated: animated)
        applySelectionLayout(animated: animated)
    }

    private func applySelectionLayout(animated: Bool) {
        guard let plan else { return }
        let shift = (selectionMode && !plan.isOutgoing) ? Self.selectionShift : 0
        let apply = {
            self.bubbleView.frame = plan.bubbleFrame.offsetBy(dx: shift, dy: 0)
            self.checkbox.center = CGPoint(x: 20, y: plan.bubbleFrame.midY)
            self.checkbox.alpha = self.selectionMode ? 1 : 0
        }
        guard animated else { return apply() }
        UIView.animate(withDuration: 0.24, delay: 0, usingSpringWithDamping: 0.9,
                       initialSpringVelocity: 0, options: [.allowUserInteraction], animations: apply)
    }

    @objc private func handleReplyQuoteTap() {
        guard msg?.replyTo != nil else { return }
        onTapReplyQuote?()
    }

    /// A brief flash of the bubble confirming the jump landed on the original.
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
        // drop an unfinished swipe-to-reply
        bubbleView.transform = .identity
        replyIcon.alpha = 0
        replyTriggered = false
    }

    /// An incoming or restored bubble arrives with a short lift.
    func animateAppearance() {
        bubbleView.transform = CGAffineTransform(translationX: 0, y: 14).scaledBy(x: 0.96, y: 0.96)
        bubbleView.alpha = 0.4
        UIView.animate(withDuration: 0.42, delay: 0, usingSpringWithDamping: 0.82,
                       initialSpringVelocity: 0.5, options: [.allowUserInteraction]) {
            self.bubbleView.transform = .identity
            self.bubbleView.alpha = 1
        }
    }

    /// An own message flies out of the send button: the bubble starts small at the
    /// button and springs into place (the way TG and WhatsApp do it).
    func animateSendFlight(fromScreenPoint point: CGPoint, in source: UIView) {
        layoutIfNeeded()
        // convert already accounts for the cell's Y flip, no sign juggling needed
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

        // Fonts are applied here rather than in init: a cell sitting in the
        // reuse pool gets no trait callback when the text size changes.
        nameLabel.font = BubbleLayout.nameFont
        forwardLabel.font = BubbleLayout.forwardFont
        timeLabel.font = BubbleLayout.timeFont

        bubbleView.frame = plan.bubbleFrame
        bubbleView.image = BubbleBackground.image(outgoing: plan.isOutgoing, mediaOnly: plan.statusOnMedia)

        // the tail is a separate image at the bottom corner of the body and sticks out
        // past it; the body (a rounded rectangle) does not depend on showTail, so the
        // bubble's left or right edge stays put when the tail appears
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

        // text
        if let tf = plan.textFrame, let text = plan.text {
            textView.isHidden = false
            textView.frame = tf
            let colors = Self.textColors(plan: plan, deleted: msg.deletedForAll)
            textView.configure(text, color: colors.text, linkColor: colors.link,
                               codeBackground: Self.codeBackground(outgoing: plan.isOutgoing))
        } else {
            textView.isHidden = true
        }

        // author name
        if let nf = plan.authorNameFrame {
            nameLabel.isHidden = false
            nameLabel.text = plan.authorName
            nameLabel.textColor = NameColor.color(for: msg.fromUserId)
            nameLabel.frame = nf
        } else {
            nameLabel.isHidden = true
        }

        // forward
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

        // media
        configureMedia(msg: msg, plan: plan)

        // voice / file
        if let vf = plan.voiceFrame {
            voiceView.isHidden = false
            voiceView.frame = vf
            voiceView.configure(msg: msg, outgoing: plan.isOutgoing)
        } else {
            voiceView.isHidden = true
        }

        // status: time and ticks
        timeLabel.text = (plan.edited ? "изм. " : "") + plan.timeString
        timeLabel.textColor = plan.statusOnMedia ? .white
            : (plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel)
        statusBackdrop.isHidden = !plan.statusOnMedia
        if plan.statusOnMedia {
            statusBackdrop.frame = plan.statusFrame.insetBy(dx: -6, dy: -1)
            statusBackdrop.layer.cornerRadius = statusBackdrop.bounds.height / 2
        }
        var timeFrame = plan.statusFrame
        if plan.isOutgoing {
            // ticks occupy the tail of the status frame that the plan reserved
            let tickW = BubbleLayout.tickWidth
            let tickH = tickW * 13 / 18
            timeFrame.size.width -= tickW
            tickView.isHidden = false
            tickView.frame = CGRect(x: plan.statusFrame.maxX - tickW + 1,
                                    y: plan.statusFrame.midY - tickH / 2,
                                    width: tickW - 2, height: tickH)
            tickView.image = Self.tickImage(msg.status)
            // read keeps its own colour over media too: the white the rest of the
            // capsule uses would make a read photo look the same as a delivered one
            tickView.tintColor = msg.status == .read ? UIColor(Theme.outgoingTickRead)
                : (plan.statusOnMedia ? .white : UIColor(Theme.outgoingMeta))
        } else {
            tickView.isHidden = true
        }
        timeLabel.frame = timeFrame
        // media views are added after the status, so the time capsule is raised back on top
        bubbleView.bringSubviewToFront(statusBackdrop)
        bubbleView.bringSubviewToFront(timeLabel)
        bubbleView.bringSubviewToFront(tickView)

        // reactions: only a genuinely new one animates in, and only when the same cell is
        // being reconfigured; a cell reused during scrolling gets no animation
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
        applySelectionLayout(animated: false)
    }

    private func configureMedia(msg: Message, plan: BubbleLayoutPlan) {
        // configure also runs on a live cell (content updated in place), so the previous
        // media views are torn down here and not only in prepareForReuse
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
                // mosaic: the large radius belongs to the outer corners of the grid only
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

            // the blurhash placeholder shows at once, the real image replaces it later
            if let bh = media.blurhash, let px = BlurHash.decodePixels(bh, width: 32, height: 32) {
                iv.image = UIImage.fromRGBA(px, width: 32, height: 32)
            }
            let scale = UIScreen.main.scale
            let target = CGSize(width: rect.width * scale, height: rect.height * scale)
            let isVideo = media.type == "video"
            Task { [weak iv] in
                guard let mm = AppState.shared.media else { return }
                let effective: MediaInfo = {
                    // video preview: the uploaded thumb blob, or the local frame before the upload
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

    /// The bubble's text colours; the lifted menu paints its live text with the same ones.
    static func textColors(plan: BubbleLayoutPlan, deleted: Bool) -> (text: UIColor, link: UIColor) {
        let text: UIColor = deleted
            ? (plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel)
            : (plan.isOutgoing ? UIColor(Theme.outgoingText) : .label)
        return (text, plan.isOutgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent))
    }

    /// Backdrop for a code block: lighter than the bubble on an outgoing one, and on an
    /// incoming one a darkening that stays visible in the dark theme too.
    static func codeBackground(outgoing: Bool) -> UIColor {
        if outgoing { return UIColor(Theme.outgoingText).withAlphaComponent(0.16) }
        return UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white.withAlphaComponent(0.12)
                : UIColor.black.withAlphaComponent(0.06)
        }
    }

    // MARK: - Swipe-to-reply with resistance

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        false
    }

    /// Ширина левой кромки экрана, принадлежащей возврату по свайпу.
    static let backSwipeEdge: CGFloat = 24

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        // жест от левой кромки экрана — это возврат: свайп-ответ его не перехватывает
        if pan.location(in: nil).x < Self.backSwipeEdge { return false }
        let v = pan.velocity(in: contentView)
        return abs(v.x) > abs(v.y) && v.x > 0
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: contentView).x
        switch g.state {
        case .changed:
            let capped = min(max(tx, 0), 90)
            let resisted = 60 * (1 - exp(-capped / 60)) // resistance
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
        case .failed: return failedMark
        case .sending: return clockMark
        case .sent: return singleTick
        case .delivered, .read: return doubleTick
        }
    }

    /// Canvas every status glyph is drawn into, so the mark keeps its size when the
    /// status moves on: the single tick is one of the pair, not a stretched symbol
    /// filling the whole frame the pair needs.
    private static let markCanvas = CGSize(width: 18, height: 13)

    private static func mark(_ draw: (UIImage) -> Void) -> UIImage {
        UIGraphicsImageRenderer(size: markCanvas).image { _ in
            draw(UIImage(systemName: "checkmark", withConfiguration: markConfig)!
                .withTintColor(.white, renderingMode: .alwaysOriginal))
        }.withRenderingMode(.alwaysTemplate)
    }

    private static let markConfig = UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)

    private static func glyph(_ name: String) -> UIImage {
        let symbol = UIImage(systemName: name, withConfiguration: markConfig)!
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        return UIGraphicsImageRenderer(size: markCanvas).image { _ in
            symbol.draw(in: CGRect(x: 4, y: 1.5, width: 10, height: 10))
        }.withRenderingMode(.alwaysTemplate)
    }

    static let singleTick: UIImage = mark { check in
        check.draw(in: CGRect(x: 3.5, y: 1.5, width: 11, height: 10))
    }

    static let doubleTick: UIImage = mark { check in
        check.draw(in: CGRect(x: 0, y: 1.5, width: 11, height: 10))
        check.draw(in: CGRect(x: 5, y: 1.5, width: 11, height: 10))
    }

    static let clockMark: UIImage = glyph("clock")
    static let failedMark: UIImage = glyph("exclamationmark.circle.fill")
}

// MARK: - Components

/// Multi-select checkbox to the left of the row: either an empty outline or an
/// accent-filled circle with a checkmark.
final class SelectionCheckboxView: UIView {
    private let ring = UIView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark",
                                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 12,
                                                                                                 weight: .bold)))
    private(set) var isChecked = false

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 22, height: 22))
        ring.frame = bounds
        ring.layer.cornerRadius = 11
        ring.layer.borderWidth = 1.5
        ring.layer.borderColor = UIColor.secondaryLabel.withAlphaComponent(0.6).cgColor
        addSubview(ring)
        check.tintColor = .white
        check.contentMode = .center
        check.frame = bounds
        check.alpha = 0
        addSubview(check)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setChecked(_ checked: Bool, animated: Bool) {
        guard checked != isChecked || !animated else { return }
        isChecked = checked
        let apply = {
            self.ring.backgroundColor = checked ? UIColor(Theme.accent) : .clear
            self.ring.layer.borderColor = checked
                ? UIColor(Theme.accent).cgColor
                : UIColor.secondaryLabel.withAlphaComponent(0.6).cgColor
            self.check.alpha = checked ? 1 : 0
        }
        guard animated else { return apply() }
        UIView.animate(withDuration: 0.18, animations: apply)
        if checked {
            check.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.6,
                           initialSpringVelocity: 0.4) { self.check.transform = .identity }
        }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        setChecked(isChecked, animated: false)
    }
}

/// Bubble backgrounds: a resizable image for the body, which carries no tail so that
/// its left and right edges do not depend on one, plus a separate small tail image
/// laid over the body and sticking out past it.
enum BubbleBackground {
    private static var cache: [String: UIImage] = [:]
    private static var tailCache: [String: UIImage] = [:]

    /// The tail canvas and the position of the body's corner inside it: see tailImage.
    /// Public because MessageCell places tailView by the very same numbers.
    static let tailCanvasSize = CGSize(width: 20, height: 18)
    static let tailAnchorY: CGFloat = 16
    static func tailAnchorX(outgoing: Bool) -> CGFloat { outgoing ? 12 : 8 }

    /// Bubble colours are baked into the images, so a palette change drops the cache.
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

    /// The tail is a small non-stretchable image laid over the body as its own subview
    /// at the matching bottom corner. The canvas keeps slack around the curve so the
    /// outer part of the tail is not clipped; the point (tailAnchorX, tailAnchorY) is
    /// the corner of the bubble body the tail attaches to.
    static func tailImage(outgoing: Bool) -> UIImage {
        let key = "\(outgoing)|\(UITraitCollection.current.userInterfaceStyle.rawValue)"
        if let img = tailCache[key] { return img }
        let size = tailCanvasSize
        let anchorX = tailAnchorX(outgoing: outgoing)
        // the curve below is written in the coordinates of the 44x40 body canvas, whose
        // bottom corner sits at (44,40) or (0,40); dx and dy carry it onto the tail canvas
        // by the same shift that moves that corner to (anchorX, tailAnchorY)
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

/// Colour of an author's name in a group, stable for a given userId.
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
        authorLabel.textColor = UIColor(Theme.accent)
        textLabel.textColor = .secondaryLabel
        addSubview(bar)
        addSubview(authorLabel)
        addSubview(textLabel)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(author: String, text: String, outgoing: Bool) {
        authorLabel.font = Theme.Text.replyAuthor.uiFont
        textLabel.font = Theme.Text.replyText.uiFont
        authorLabel.text = author
        textLabel.text = text
        // accent colours are unreadable on the dark outgoing bubble
        bar.backgroundColor = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        authorLabel.textColor = outgoing ? UIColor(Theme.outgoingText) : UIColor(Theme.accent)
        textLabel.textColor = outgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // the two lines split the strip by their own line heights
        let authorH = ceil(authorLabel.font.lineHeight)
        bar.frame = CGRect(x: 0, y: 2, width: 3, height: bounds.height - 4)
        authorLabel.frame = CGRect(x: 9, y: 2, width: bounds.width - 9, height: authorH)
        textLabel.frame = CGRect(x: 9, y: 2 + authorH, width: bounds.width - 9,
                                 height: max(0, bounds.height - 4 - authorH))
    }
}

final class ReactionCapsuleView: UIControl {
    private let label = UILabel()
    var onTap: (() -> Void)?
    private(set) var emojiKey = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        label.textAlignment = .center
        addSubview(label)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(emoji: String, count: Int, mine: Bool, outgoing: Bool, animateIn: Bool) {
        emojiKey = emoji
        label.font = Theme.Text.reaction.uiFont
        label.text = count > 1 ? "\(emoji) \(count)" : emoji
        // the capsule keeps to the bubble's palette; your own reaction gets a denser fill
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
        // a hairline border separates the capsule from both the incoming and outgoing bubble
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
        // the spring entrance is for a genuinely new reaction only
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
        layer.cornerRadius = bounds.height / 2
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

// MARK: - Context menu

extension MessageCell {
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let msg, !msg.deletedForAll,
              let window = window else { return }
        Haptics.medium()

        var items: [MessageContextOverlay.Item] = []
        // a message that never went out has no server id: it cannot be replied
        // to, forwarded or pinned, and the only two things to do with it are to
        // send it again and to throw it away
        if msg.status == .failed {
            items.append(.init(title: "Отправить заново", icon: "arrow.clockwise") { [weak self] in
                self?.onContextAction?(.resend)
            })
            if msg.kind == .text {
                items.append(.init(title: "Копировать", icon: "doc.on.doc") { [weak self] in
                    self?.onContextAction?(.copy)
                })
            }
            items.append(.init(title: "Удалить", icon: "trash", destructive: true) { [weak self] in
                self?.onContextAction?(.delete)
            })
            presentContextMenu(items, in: window, msg: msg, showsReactions: false)
            return
        }
        items.append(.init(title: "Ответить", icon: "arrowshape.turn.up.left") { [weak self] in
            self?.onContextAction?(.reply)
        })
        // a photo or album goes to the clipboard as an image, text as a string
        if msg.kind == .text || msg.kind == .photo || msg.kind == .album {
            items.append(.init(title: "Копировать", icon: "doc.on.doc") { [weak self] in
                self?.onContextAction?(.copy)
            })
        }
        items.append(.init(title: "Переслать", icon: "arrowshape.turn.up.right") { [weak self] in
            self?.onContextAction?(.forward)
        })
        items.append(.init(title: "Выбрать", icon: "checkmark.circle") { [weak self] in
            self?.onContextAction?(.select)
        })
        if isPinned?() == true {
            items.append(.init(title: "Открепить", icon: "pin.slash") { [weak self] in
                self?.onContextAction?(.unpin)
            })
        } else {
            items.append(.init(title: "Закрепить", icon: "pin") { [weak self] in
                self?.onContextAction?(.pin)
            })
        }
        if msg.isOutgoing && msg.kind == .text {
            items.append(.init(title: "Изменить", icon: "pencil") { [weak self] in
                self?.onContextAction?(.edit)
            })
        }
        items.append(.init(title: "Удалить", icon: "trash", destructive: true) { [weak self] in
            self?.onContextAction?(.delete)
        })

        presentContextMenu(items, in: window, msg: msg)
    }

    private func presentContextMenu(_ items: [MessageContextOverlay.Item], in window: UIWindow,
                                    msg: Message, showsReactions: Bool = true) {
        let mine = msg.reactions.first(where: { $0.value.contains(OwnUser.id) })?.key
        // текст приподнятого баббла выделяется протяжкой, поэтому он уходит
        // в меню живым, а снимок рендерится без него
        var selectable: MessageContextOverlay.SelectableText?
        if let plan, let tf = plan.textFrame, let text = plan.text, !msg.deletedForAll {
            let colors = Self.textColors(plan: plan, deleted: msg.deletedForAll)
            selectable = .init(attributed: text, frame: tf, color: colors.text,
                               linkColor: colors.link,
                               codeBackground: Self.codeBackground(outgoing: plan.isOutgoing))
        }
        let textWasHidden = textView.isHidden
        textView.isHidden = selectable != nil || textWasHidden
        MessageContextOverlay.present(over: bubbleView, in: window, isOutgoing: msg.isOutgoing,
                                      myReaction: mine, items: items, selectableText: selectable,
                                      showsReactions: showsReactions,
                                      onReact: { [weak self] emoji in self?.onReact?(emoji) })
        textView.isHidden = textWasHidden
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
