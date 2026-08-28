import UIKit
import AVFoundation
import Combine
import MsngrCore

/// Message cell: manual layout driven by BubbleLayoutPlan, no Auto Layout at all.
final class MessageCell: UICollectionViewCell, UIGestureRecognizerDelegate {
    var onReply: (() -> Void)?
    var onReact: ((String) -> Void)?
    var onContextAction: ((MessageContextAction) -> Void)?
    /// Tap on a reaction capsule. Separate from onReact: in a group it opens
    /// the list of who reacted instead of toggling.
    var onCapsuleTap: ((String) -> Void)?
    /// Whether this message is the pinned one, asked at the moment the menu opens.
    var isPinned: (() -> Bool)?
    var onTapMedia: ((Int, UIView) -> Void)?
    var onTapShader: (() -> Void)?
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
    /// Muted looping players over the video tiles whose files are already on
    /// the device; torn down together with the media views.
    private var autoplay: [(layer: AVPlayerLayer, looper: NSObjectProtocol)] = []
    /// Frame loops of the animated GIFs on screen. Each holds a flag the loop
    /// reads: cleared, the animation stops with the view it was drawing into.
    private var gifLoops: [GIFAnimation] = []
    /// One fingerprint per media view (blurhash + mediaId + local paths): a
    /// message's media is no longer immutable once picked — it fills in from
    /// a placeholder to a finished upload — so an in-place reconfigure has to
    /// tell "nothing changed" from "the same slot now points at more".
    private var mediaSignatures: [String] = []
    /// The progress ring over each tile of a message still being sent, by slot.
    private var progressRings: [Int: UploadRingView] = [:]
    private var progressCancellable: AnyCancellable?
    /// The play glyph over each video tile, by slot; hidden while its ring shows.
    private var playGlyphs: [Int: UIImageView] = [:]
    private var reactionViews: [ReactionCapsuleView] = []
    private let voiceView = VoiceMessageView()
    private let shaderView = ShaderMessageView()
    /// A sticker: the same live view with nothing painted behind the shader.
    private let stickerView = ShaderMessageView(transparent: true)
    /// The shader a sender put behind a text bubble, under every other subview.
    private let bubbleShaderCanvas = ShaderCanvas()
    /// Between willDisplay and didEndDisplaying: what a live shader configured
    /// into this cell in the meantime has to know to start.
    private var onScreen = false
    private let avatarView = FeedAvatarView()
    private var msg: Message?
    private var plan: BubbleLayoutPlan?
    private var configuredMsgId: String?

    // swipe-to-reply
    private var panStartX: CGFloat = 0
    private let replyIcon = UIImageView(image: UIImage(systemName: "arrowshape.turn.up.left.fill"))
    private var replyTriggered = false

    // press feedback: the bubble dips under the finger long before the context menu
    private var pressGesture: UILongPressGestureRecognizer!
    private var pressStart: CGPoint = .zero
    /// swipe-to-reply owns the bubble transform while the finger drags
    private var panDrivesBubble = false

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
        bubbleShaderCanvas.isHidden = true
        bubbleShaderCanvas.isUserInteractionEnabled = false
        bubbleShaderCanvas.clipsToBounds = true
        bubbleShaderCanvas.layer.cornerRadius = Theme.bubbleCorner
        bubbleShaderCanvas.layer.cornerCurve = .continuous
        bubbleView.addSubview(bubbleShaderCanvas)
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
        shaderView.isHidden = true
        shaderView.isUserInteractionEnabled = true
        shaderView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shaderTapped)))
        // under the status capsule, like a photo: the time reads over the picture
        bubbleView.insertSubview(shaderView, belowSubview: statusBackdrop)
        stickerView.isHidden = true
        stickerView.isUserInteractionEnabled = true
        stickerView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(shaderTapped)))
        bubbleView.insertSubview(stickerView, belowSubview: statusBackdrop)
        // the rings follow the sender's progress store rather than polling it
        progressCancellable = MediaProgress.shared.$fractions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fractions in self?.applyProgress(fractions) }

        // the avatar lives outside the bubble: press dips and swipe-to-reply move
        // the bubble alone, the face stays put the way it does in Telegram
        avatarView.isHidden = true
        contentView.addSubview(avatarView)

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

        // the dip is purely visual and runs alongside every other gesture; it does
        // not cancel touches, so the reaction capsules still get their tap
        let press = UILongPressGestureRecognizer(target: self, action: #selector(handlePress(_:)))
        press.minimumPressDuration = 0.1
        press.cancelsTouchesInView = false
        press.delegate = self
        bubbleView.addGestureRecognizer(press)
        pressGesture = press

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
        gestures = [pan, doubleTap, longPress, tap, replyTap, press]
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
            // the avatar clears room for the checkbox together with its bubble
            if let af = plan.avatarFrame { self.avatarView.frame = af.offsetBy(dx: shift, dy: 0) }
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

    /// The accent wash a message mentioning this user keeps for as long as it
    /// is on screen; it lies under every other subview, so a photo covers it
    /// and only the bubble's own background is tinted.
    private func applyMentionWash(_ plan: BubbleLayoutPlan) {
        let wash = bubbleView.viewWithTag(Self.mentionTag)
        guard plan.mentionsMe else {
            wash?.removeFromSuperview()
            return
        }
        let view = wash ?? {
            let v = UIView()
            v.tag = Self.mentionTag
            v.backgroundColor = UIColor(Theme.accent).withAlphaComponent(0.14)
            v.layer.cornerRadius = Theme.bubbleCorner
            v.layer.cornerCurve = .continuous
            v.isUserInteractionEnabled = false
            bubbleView.insertSubview(v, at: 0)
            return v
        }()
        view.frame = bubbleView.bounds
    }

    private static let highlightTag = 7181
    private static let mentionTag = 7182

    required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        teardownAutoplay()
        shaderView.setActive(false)
        stickerView.setActive(false)
        bubbleShaderCanvas.setRunning(false)
        reactionViews.forEach { $0.removeFromSuperview() }
        reactionViews = []
        bubbleView.viewWithTag(Self.highlightTag)?.removeFromSuperview()
        bubbleView.viewWithTag(Self.mentionTag)?.removeFromSuperview()
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        // drop an unfinished swipe-to-reply or press dip; a bubble the context
        // overlay hid must not stay hidden for the next message in this cell
        bubbleView.transform = .identity
        bubbleView.isHidden = false
        replyIcon.alpha = 0
        replyTriggered = false
        panDrivesBubble = false
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

    func configure(msg: Message, plan: BubbleLayoutPlan, avatar: FeedAvatar? = nil) {
        self.msg = msg
        self.plan = plan

        if let af = plan.avatarFrame, let avatar {
            avatarView.isHidden = false
            avatarView.frame = af
            avatarView.set(avatar)
        } else {
            avatarView.isHidden = true
        }

        // Fonts are applied here rather than in init: a cell sitting in the
        // reuse pool gets no trait callback when the text size changes.
        nameLabel.font = BubbleLayout.nameFont
        forwardLabel.font = BubbleLayout.forwardFont
        timeLabel.font = BubbleLayout.timeFont

        bubbleView.frame = plan.bubbleFrame
        // a bubble shader takes the place of the bubble colour; the tail keeps it
        let bubbleShader = msg.kind == .text && !msg.deletedForAll ? msg.bubbleShader : nil
        bubbleView.image = BubbleBackground.image(outgoing: plan.isOutgoing,
                                                  mediaOnly: plan.statusOnMedia || bubbleShader != nil)
        if let bubbleShader {
            bubbleShaderCanvas.isHidden = false
            bubbleShaderCanvas.frame = bubbleView.bounds
            bubbleShaderCanvas.show(bubbleShader)
            bubbleShaderCanvas.setRunning(onScreen)
        } else {
            bubbleShaderCanvas.isHidden = true
            bubbleShaderCanvas.setRunning(false)
        }
        applyMentionWash(plan)

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
            let colors = Self.textColors(plan: plan, deleted: msg.deletedForAll, overShader: bubbleShader != nil)
            textView.configure(text, color: colors.text, linkColor: colors.link,
                               codeBackground: Self.codeBackground(outgoing: plan.isOutgoing))
            // over a shader the text is white and carries a shadow, whatever the picture
            textView.layer.shadowColor = UIColor.black.cgColor
            textView.layer.shadowOpacity = bubbleShader != nil ? 0.9 : 0
            textView.layer.shadowRadius = 2
            textView.layer.shadowOffset = .zero
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
            // the meta gray of the incoming bubble is unreadable on the dark
            // outgoing one; the line follows the time's palette
            forwardLabel.textColor = plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel
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

        // shader and sticker
        if let sf = plan.shaderFrame, let document = msg.shader, msg.kind == .shader {
            shaderView.isHidden = false
            shaderView.frame = sf
            shaderView.configure(document: document)
            shaderView.setActive(onScreen)
        } else {
            shaderView.isHidden = true
            shaderView.setActive(false)
        }
        if let sf = plan.shaderFrame, let document = msg.shader, msg.kind == .sticker {
            stickerView.isHidden = false
            stickerView.frame = sf
            stickerView.configure(document: document)
            stickerView.setActive(onScreen)
        } else {
            stickerView.isHidden = true
            stickerView.setActive(false)
        }

        // status: time and ticks
        timeLabel.text = (plan.edited ? BubbleLayout.editedMark : "") + plan.timeString
        timeLabel.textColor = plan.statusOnMedia || bubbleShader != nil ? .white
            : (plan.isOutgoing ? UIColor(Theme.outgoingMeta) : .secondaryLabel)
        statusBackdrop.isHidden = !(plan.statusOnMedia || bubbleShader != nil)
        if plan.statusOnMedia || bubbleShader != nil {
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
                : (plan.statusOnMedia || bubbleShader != nil ? .white : UIColor(Theme.outgoingMeta))
        } else {
            tickView.isHidden = true
        }
        timeLabel.frame = timeFrame
        // media views are added after the status, so the time capsule is raised back on top
        bubbleView.bringSubviewToFront(statusBackdrop)
        bubbleView.bringSubviewToFront(timeLabel)
        bubbleView.bringSubviewToFront(tickView)

        // reactions: capsules are reused by emoji, so a count change or a shifted frame
        // animates in place when configure runs inside an animation block. Only a
        // genuinely new one springs in, and only when the same cell is being
        // reconfigured; a cell reused during scrolling gets no animation
        let sameCell = configuredMsgId == msg.id
        var previous: [String: ReactionCapsuleView] = [:]
        for v in reactionViews { previous[v.emojiKey] = v }
        reactionViews = []
        for r in plan.reactionsFrames {
            let capsule = previous.removeValue(forKey: r.emoji) ?? ReactionCapsuleView()
            let isNew = capsule.superview == nil
            if isNew {
                bubbleView.addSubview(capsule)
                // the frame and the label are laid out before the entrance
                // spring starts: a label that picks its bounds up in a later
                // layout pass inherits the outer animation block and reveals
                // the glyph as a clipped sliver instead of scaling with the
                // capsule
                UIView.performWithoutAnimation {
                    capsule.frame = r.frame
                    capsule.layoutIfNeeded()
                }
            } else {
                capsule.frame = r.frame
            }
            capsule.configure(emoji: r.emoji, count: r.count, mine: r.mine,
                              outgoing: plan.isOutgoing, animateIn: sameCell && isNew)
            capsule.onTap = { [weak self] in self?.onCapsuleTap?(r.emoji) }
            reactionViews.append(capsule)
        }
        for (_, gone) in previous {
            guard sameCell else { gone.removeFromSuperview(); continue }
            // a withdrawn reaction shrinks away instead of vanishing
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState],
                           animations: {
                gone.alpha = 0
                gone.transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
            }, completion: { _ in gone.removeFromSuperview() })
        }
        configuredMsgId = msg.id
        applySelectionLayout(animated: false)
    }

    /// A fingerprint of what a media view should be showing: two calls with the
    /// same signature would load the same picture, so a change here is the
    /// only thing worth another fetch. A message being sent goes through
    /// several of these for the same slot — a blank placeholder, a fast
    /// BlurHash, the finished upload — as `SyncEngine.updateMediaPreview`/
    /// `finalizeMedia` fill it in.
    private static func mediaSignature(_ media: MediaInfo) -> String {
        [media.blurhash ?? "", media.mediaId, media.localPath ?? "",
         media.thumbMediaId ?? "", media.thumbLocalPath ?? ""].joined(separator: "|")
    }

    private func configureMedia(msg: Message, plan: BubbleLayoutPlan) {
        guard let mediaFrame = plan.mediaFrame else {
            mediaViews.forEach { $0.removeFromSuperview() }
            mediaViews = []
            mediaSignatures = []
            return
        }
        let rects: [(Int, CGRect)] = plan.albumRects.isEmpty
            ? [(0, mediaFrame)]
            : plan.albumRects.map { ($0.index, $0.frame.offsetBy(dx: mediaFrame.minX, dy: mediaFrame.minY)) }
        let medias: [MediaInfo] = msg.album ?? (msg.media.map { [$0] } ?? [])
        let signatures = medias.map { Self.mediaSignature($0) }

        // the same message reconfigured in place (a reaction, an ack, a step of
        // sending) keeps its media views — a teardown mid-resize would flash the
        // blurhash placeholder — but a slot whose signature moved on (the send
        // pipeline filling it in) still gets its image reloaded
        if configuredMsgId == msg.id, !mediaViews.isEmpty, mediaViews.count == rects.count,
           zip(mediaViews, rects).allSatisfy({ $0.0.tag == $0.1.0 }) {
            for (iv, (index, rect)) in zip(mediaViews, rects) {
                iv.frame = rect
                applyMediaCorners(iv, rect: rect, plan: plan)
                if index < medias.count, index >= mediaSignatures.count || signatures[index] != mediaSignatures[index] {
                    loadMedia(into: iv, media: medias[index], index: index, rect: rect)
                }
            }
            mediaSignatures = signatures
            syncProgressRings(msg)
            return
        }

        // configure also runs on a live cell (content updated in place), so the previous
        // media views are torn down here and not only in prepareForReuse
        teardownAutoplay()
        mediaViews.forEach { $0.removeFromSuperview() }
        mediaViews = []
        progressRings = [:]
        playGlyphs = [:]
        mediaSignatures = signatures

        for (index, rect) in rects {
            guard index < medias.count else { continue }
            let media = medias[index]
            let iv = UIImageView()
            // a fresh tile is built without animation: configure can run inside
            // the feed's animation block, and an animated first frame flies the
            // tile in from zero
            UIView.performWithoutAnimation {
                iv.frame = rect
                iv.contentMode = .scaleAspectFill
                iv.clipsToBounds = true
                iv.backgroundColor = .tertiarySystemFill
                iv.isUserInteractionEnabled = true
                applyMediaCorners(iv, rect: rect, plan: plan)
                iv.tag = index
                let tap = UITapGestureRecognizer(target: self, action: #selector(mediaTapped(_:)))
                iv.addGestureRecognizer(tap)
                bubbleView.addSubview(iv)
                mediaViews.append(iv)
                loadMedia(into: iv, media: media, index: index, rect: rect)

                if media.type == "video" {
                    let play = UIImageView(image: UIImage(systemName: "play.circle.fill"))
                    play.tintColor = .white.withAlphaComponent(0.9)
                    play.frame = CGRect(x: rect.width / 2 - 22, y: rect.height / 2 - 22, width: 44, height: 44)
                    play.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                             .flexibleTopMargin, .flexibleBottomMargin]
                    iv.addSubview(play)
                    playGlyphs[index] = play
                    startAutoplayIfLocal(on: iv, media: media, playGlyph: play)
                }
            }
        }
        syncProgressRings(msg)
    }

    /// A message on its way out carries a ring per tile with the fraction of
    /// its preparation and upload; the rings go the moment the ack lands and
    /// the status leaves `sending`.
    private func syncProgressRings(_ msg: Message) {
        let wanted = msg.isOutgoing && msg.status == .sending
        // the ring stands where the play glyph would: one of the two at a time
        playGlyphs.values.forEach { $0.isHidden = wanted }
        if !wanted {
            progressRings.values.forEach { $0.removeFromSuperview() }
            progressRings = [:]
            return
        }
        for iv in mediaViews where progressRings[iv.tag] == nil {
            let ring = UploadRingView()
            let side: CGFloat = 52
            // a retry flips a visible cell to sending inside the feed's animation
            // block; the ring's first frame lands in place, never animated
            UIView.performWithoutAnimation {
                ring.frame = CGRect(x: (iv.bounds.width - side) / 2, y: (iv.bounds.height - side) / 2,
                                    width: side, height: side)
            }
            ring.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                     .flexibleTopMargin, .flexibleBottomMargin]
            iv.addSubview(ring)
            progressRings[iv.tag] = ring
        }
        applyProgress(MediaProgress.shared.fractions)
    }

    private func applyProgress(_ fractions: [String: Double]) {
        guard let msg, !progressRings.isEmpty else { return }
        for (index, ring) in progressRings {
            ring.fraction = fractions[MediaProgress.key(msg.id, index: index)] ?? 0
        }
    }

    // MARK: - Muted autoplay

    /// A video whose file is already on the device plays in place, muted and
    /// looping, and the play glyph gives way — the tap still opens the viewer.
    /// A video that would need a download keeps the preview frame and the
    /// glyph: the feed does not start network transfers on its own.
    private func startAutoplayIfLocal(on iv: UIImageView, media: MediaInfo, playGlyph: UIImageView) {
        guard let mm = AppState.shared.media else { return }
        let url: URL? = media.mediaId.isEmpty
            ? media.localPath.flatMap { mm.pendingURL(for: $0) }
            : mm.cachedURL(for: media.mediaId, mime: media.mime)
        guard let url else { return }
        // muted playback must not stop whatever the user is listening to; the
        // voice paths set their own category right before they run
        Self.claimAmbientAudioOnce
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.actionAtItemEnd = .none
        let layer = AVPlayerLayer(player: player)
        layer.frame = iv.bounds
        layer.videoGravity = .resizeAspectFill
        iv.layer.addSublayer(layer)
        let looper = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
        autoplay.append((layer, looper))
        playGlyph.isHidden = true
        player.play()
    }

    private static let claimAmbientAudioOnce: Void = {
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
    }()

    private func teardownAutoplay() {
        for (layer, looper) in autoplay {
            NotificationCenter.default.removeObserver(looper)
            layer.player?.pause()
            layer.player = nil
            layer.removeFromSuperlayer()
        }
        autoplay = []
        for loop in gifLoops { loop.stop() }
        gifLoops = []
    }

    /// Off-screen cells stop their players; the collection view drives this
    /// from willDisplay/didEndDisplaying.
    func setAutoplayActive(_ active: Bool) {
        onScreen = active
        shaderView.setActive(active && !shaderView.isHidden)
        stickerView.setActive(active && !stickerView.isHidden)
        bubbleShaderCanvas.setRunning(active && !bubbleShaderCanvas.isHidden)
        for (layer, _) in autoplay {
            if active { layer.player?.play() } else { layer.player?.pause() }
        }
        for loop in gifLoops { loop.setPaused(!active) }
    }

    /// The blurhash placeholder shows at once, the real image replaces it once the
    /// pipeline can fetch it — from the local file while a send is still in flight,
    /// from the server once it is uploaded. Safe to call again for the same view: a
    /// fetch that resolves against a stale tag (the cell moved on to another slot)
    /// is dropped, and one that resolves against nothing yet to fetch is a no-op.
    private func loadMedia(into iv: UIImageView, media: MediaInfo, index: Int, rect: CGRect) {
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
            // a GIF plays where it stands: its frames go into the same tile the
            // still image would have filled
            if effective.mime == "image/gif", let data = try? Data(contentsOf: url),
               ImageProcessor.isAnimatedGIF(data) {
                await MainActor.run { [weak self] in
                    guard let self, let iv, iv.tag == index else { return }
                    let loop = GIFAnimation(data: data, into: iv)
                    self.gifLoops.append(loop)
                    loop.start()
                }
                return
            }
            let cg = await ImagePipeline.shared.image(at: url, targetPixelSize: target)
            await MainActor.run {
                guard let iv, iv.tag == index, let cg else { return }
                UIView.transition(with: iv, duration: 0.18, options: .transitionCrossDissolve) {
                    iv.image = UIImage(cgImage: cg)
                }
            }
        }
    }

    /// Rounds a media view: a single photo gets the bubble radius on all corners, a
    /// mosaic tile only where it touches the outer corners of the grid.
    private func applyMediaCorners(_ iv: UIImageView, rect: CGRect, plan: BubbleLayoutPlan) {
        if plan.albumRects.isEmpty {
            iv.layer.cornerRadius = Theme.bubbleCorner
            iv.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                                      .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        } else if let mf = plan.mediaFrame {
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
    }

    @objc private func mediaTapped(_ g: UITapGestureRecognizer) {
        guard let v = g.view else { return }
        onTapMedia?(v.tag, v)
    }

    @objc private func shaderTapped() {
        onTapShader?()
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

    /// Where the bubble is on the screen, for an effect that starts from it.
    func bubbleCenter(in view: UIView) -> CGPoint {
        bubbleView.convert(CGPoint(x: bubbleView.bounds.midX, y: bubbleView.bounds.midY), to: view)
    }

    /// The bubble's text colours; the lifted menu paints its live text with the same ones.
    static func textColors(plan: BubbleLayoutPlan, deleted: Bool, overShader: Bool = false) -> (text: UIColor, link: UIColor) {
        if overShader { return (.white, .white) }
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

    // MARK: - Press feedback

    /// The bubble answers the touch at once: a slight dip under the finger, the way
    /// Telegram does it, while the 0.35 s context menu timer keeps running.
    @objc private func handlePress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            pressStart = g.location(in: nil)
            guard !panDrivesBubble else { return }
            UIView.animate(withDuration: 0.22, delay: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]) {
                self.bubbleView.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
            }
        case .changed:
            // the finger started scrolling or swiping: the dip lets go so the feed
            // does not drag a pressed bubble along
            let p = g.location(in: nil)
            if hypot(p.x - pressStart.x, p.y - pressStart.y) > 12 {
                g.isEnabled = false
                g.isEnabled = true
            }
        case .ended, .cancelled, .failed:
            guard !panDrivesBubble else { return }
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                self.bubbleView.transform = .identity
            }
        default:
            break
        }
    }

    // MARK: - Swipe-to-reply with resistance

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // the dip runs alongside everything, scroll included; the rest stay exclusive
        g === pressGesture || other === pressGesture
    }

    /// Width of the screen's left edge that belongs to the back swipe.
    static let backSwipeEdge: CGFloat = 24

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard let pan = g as? UIPanGestureRecognizer else { return true }
        // a gesture from the screen's left edge is the back swipe: swipe-to-reply does not steal it
        if pan.location(in: nil).x < Self.backSwipeEdge { return false }
        let v = pan.velocity(in: contentView)
        return abs(v.x) > abs(v.y) && v.x > 0
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let tx = g.translation(in: contentView).x
        switch g.state {
        case .changed:
            if !panDrivesBubble {
                panDrivesBubble = true
                // the dip, if any, hands the transform over without a restore animation
                pressGesture.isEnabled = false
                pressGesture.isEnabled = true
            }
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
            panDrivesBubble = false
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

/// Sender avatar beside an incoming group bubble: the photo from the avatar
/// cache, or initials over the same gradient the chat list draws for this name.
final class FeedAvatarView: UIView {
    private let gradient = CAGradientLayer()
    private let initialsLabel = UILabel()
    private let imageView = UIImageView()
    /// A shader avatar runs here, at the avatar priority of the budget.
    private let canvas = ShaderCanvas()
    /// What the view currently shows: a repeated set for the same sender and
    /// picture is a no-op, so a reused cell does not restart the load.
    private var shownKey: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = true
        layer.addSublayer(gradient)
        initialsLabel.textColor = .white
        initialsLabel.textAlignment = .center
        addSubview(initialsLabel)
        imageView.contentMode = .scaleAspectFill
        addSubview(imageView)
        canvas.priority = .avatar
        canvas.isHidden = true
        addSubview(canvas)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.width / 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
        initialsLabel.frame = bounds
        initialsLabel.font = .systemFont(ofSize: bounds.width * 0.4, weight: .semibold)
        imageView.frame = bounds
        canvas.frame = bounds
    }

    func set(_ avatar: FeedAvatar) {
        let key = "\(avatar.userId)|\(avatar.avatarId ?? "")"
        guard key != shownKey else { return }
        shownKey = key
        initialsLabel.text = AvatarStyle.initials(avatar.name)
        gradient.colors = AvatarStyle.gradient(for: avatar.name).map { UIColor($0).cgColor }
        imageView.image = nil
        canvas.isHidden = true
        canvas.setRunning(false)
        guard let avatarId = avatar.avatarId, !avatarId.isEmpty else { return }
        Task { [weak self] in
            let picture = await AvatarImageLoader.shared.picture(avatarId)
            // the cell may have moved on to another sender while the file loaded
            guard let self, self.shownKey == key else { return }
            switch picture {
            case .image(let image): self.imageView.image = image
            case .shader(let doc):
                self.canvas.isHidden = false
                self.canvas.show(doc)
                self.canvas.setRunning(self.window != nil)
            case nil: break
            }
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if !canvas.isHidden { canvas.setRunning(window != nil) }
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
        // the spring entrance is for a genuinely new reaction only; the starting state
        // is pinned outside any outer animation block, or it would animate too
        if animateIn {
            UIView.performWithoutAnimation {
                transform = CGAffineTransform(scaleX: 0.5, y: 0.5)
                alpha = 0
            }
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
            items.append(.init(title: String(localized: "Send again"), icon: "arrow.clockwise") { [weak self] in
                self?.onContextAction?(.resend)
            })
            if msg.kind == .text {
                items.append(.init(title: String(localized: "Copy"), icon: "doc.on.doc") { [weak self] in
                    self?.onContextAction?(.copy)
                })
            }
            items.append(.init(title: String(localized: "Delete"), icon: "trash", destructive: true) { [weak self] in
                self?.onContextAction?(.delete)
            })
            presentContextMenu(items, in: window, msg: msg, showsReactions: false)
            return
        }
        items.append(.init(title: String(localized: "Reply"), icon: "arrowshape.turn.up.left", id: "chat.menu.reply") { [weak self] in
            self?.onContextAction?(.reply)
        })
        // a photo or album goes to the clipboard as an image, text as a string
        if msg.kind == .text || msg.kind == .photo || msg.kind == .album {
            items.append(.init(title: String(localized: "Copy"), icon: "doc.on.doc") { [weak self] in
                self?.onContextAction?(.copy)
            })
        }
        items.append(.init(title: String(localized: "Forward"), icon: "arrowshape.turn.up.right") { [weak self] in
            self?.onContextAction?(.forward)
        })
        items.append(.init(title: String(localized: "Select"), icon: "checkmark.circle") { [weak self] in
            self?.onContextAction?(.select)
        })
        // a pin is held by the seq, so a message the server has not
        // acknowledged yet has nothing to pin to
        if isPinned?() == true {
            items.append(.init(title: String(localized: "Unpin"), icon: "pin.slash") { [weak self] in
                self?.onContextAction?(.unpin)
            })
        } else if msg.seq != nil {
            items.append(.init(title: String(localized: "Pin"), icon: "pin") { [weak self] in
                self?.onContextAction?(.pin)
            })
        }
        if msg.isOutgoing && msg.kind == .text {
            items.append(.init(title: String(localized: "Edit"), icon: "pencil") { [weak self] in
                self?.onContextAction?(.edit)
            })
        }
        if msg.kind == .shader, msg.shader != nil {
            items.append(.init(title: String(localized: "Set as background"), icon: "photo.artframe",
                               id: "chat.menu.setBackground") { [weak self] in
                self?.onContextAction?(.setBackground)
            })
        }
        if msg.kind == .sticker, let doc = msg.shader, !ShaderSurfaces.shared.hasSticker(doc) {
            items.append(.init(title: String(localized: "Add to stickers"), icon: "plus.square.on.square",
                               id: "chat.menu.saveSticker") { [weak self] in
                self?.onContextAction?(.saveSticker)
            })
        }
        if msg.edited {
            items.append(.init(title: String(localized: "Edit history"),
                               icon: "clock.arrow.circlepath", id: "chat.menu.editHistory") { [weak self] in
                self?.onContextAction?(.editHistory)
            })
        }
        items.append(.init(title: String(localized: "Delete"), icon: "trash", destructive: true) { [weak self] in
            self?.onContextAction?(.delete)
        })

        presentContextMenu(items, in: window, msg: msg)
    }

    private func presentContextMenu(_ items: [MessageContextOverlay.Item], in window: UIWindow,
                                    msg: Message, showsReactions: Bool = true) {
        let mine = msg.reactions.first(where: { $0.value.contains(OwnUser.id) })?.key
        // the lifted bubble's text is selectable by dragging, so it goes into the
        // menu live and the snapshot is rendered without it
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
        // the overlay's snapshot took over from the pressed bubble: the press ends
        // here so the hidden bubble is back at rest when the overlay reveals it
        pressGesture.isEnabled = false
        pressGesture.isEnabled = true
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

/// The ring over a tile of a message on its way out: a track, the arc of the
/// fraction done and the same number in percent, on a dimmed disc so it reads
/// over any picture.
final class UploadRingView: UIView {
    var fraction: Double = 0 {
        didSet {
            guard fraction != oldValue else { return }
            label.text = "\(Int((fraction * 100).rounded()))%"
            setNeedsDisplay()
        }
    }
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        label.textColor = .white
        label.textAlignment = .center
        label.font = Theme.Text.voiceDuration.uiFont
        label.text = "0%"
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        addSubview(label)
        accessibilityIdentifier = "media.progress"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 8, dy: 8)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let line: CGFloat = 3
        let disc = bounds.insetBy(dx: line / 2, dy: line / 2)
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
        ctx.fillEllipse(in: disc)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = disc.width / 2 - line
        ctx.setLineWidth(line)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(UIColor.white.withAlphaComponent(0.3).cgColor)
        ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        guard fraction > 0 else { return }
        ctx.setStrokeColor(UIColor.white.cgColor)
        let start = -CGFloat.pi / 2
        ctx.addArc(center: center, radius: radius, startAngle: start,
                   endAngle: start + CGFloat(fraction) * .pi * 2, clockwise: false)
        ctx.strokePath()
    }
}
