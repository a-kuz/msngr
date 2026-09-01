import UIKit
import MsngrCore

/// A finished drawing plan for one message: every frame is computed ahead of time
/// (off the main thread) and the cell only places layers. No Auto Layout in cells.
struct BubbleLayoutPlan: Equatable {
    var cellHeight: CGFloat
    var bubbleFrame: CGRect
    var textFrame: CGRect?
    var text: NSAttributedString?
    /// status (time and ticks): frame in the bubble's coordinates
    var statusFrame: CGRect
    var statusOnMedia: Bool         // capsule laid over the photo or video
    var mediaFrame: CGRect?
    var albumRects: [MosaicRect]
    var voiceFrame: CGRect?
    /// the live shader of a shader message, in the bubble's coordinates
    var shaderFrame: CGRect?
    var replyFrame: CGRect?
    var replyAuthor: String?
    var replyText: String?
    /// the link card under the text, in the bubble's coordinates
    var linkFrame: CGRect?
    var linkTitle: String?
    var linkDesc: String?
    var linkHost: String?
    var linkURL: String?
    var linkImage: MediaInfo?
    /// a bot's buttons under the message, in the bubble's coordinates, one
    /// rect per button in reading order
    var buttonFrames: [(button: MessageButton, frame: CGRect)]
    var forwardFrame: CGRect?
    var forwardText: String?
    var authorNameFrame: CGRect?    // the name shown in groups
    var authorName: String?
    /// the sender's avatar in group chats, in cell coordinates; set only on the
    /// message that carries the picture (the last of a run)
    var avatarFrame: CGRect?
    var reactionsFrames: [(emoji: String, count: Int, mine: Bool, frame: CGRect)]
    var reactionsHeight: CGFloat
    var isOutgoing: Bool
    /// An incoming message whose text carries a mention of this user: the
    /// bubble keeps an accent wash so the message is findable by eye.
    var mentionsMe: Bool
    var showTail: Bool
    var timeString: String
    var edited: Bool
    var statusWidth: CGFloat

    static func == (a: BubbleLayoutPlan, b: BubbleLayoutPlan) -> Bool {
        a.cellHeight == b.cellHeight && a.bubbleFrame == b.bubbleFrame
            && a.text?.string == b.text?.string && a.timeString == b.timeString
            && a.reactionsFrames.count == b.reactionsFrames.count
    }
}

/// The current user's userId, reachable from background measurement (written at bootstrap).
enum OwnUser {
    nonisolated(unsafe) static var id: String = ""
}

enum BubbleLayout {
    static var textFont: UIFont { Theme.Text.bubble.uiFont }
    static var timeFont: UIFont { Theme.Text.bubbleTime.uiFont }
    static var nameFont: UIFont { Theme.Text.bubbleName.uiFont }
    static var forwardFont: UIFont { Theme.Text.bubbleForward.uiFont }
    static let hPadding: CGFloat = 12
    static let vPadding: CGFloat = 7
    static let sideMargin: CGFloat = 10
    static let groupGap: CGFloat = 2
    static let normalGap: CGFloat = 8

    // Everything the plan places vertically follows the text it holds, so the
    // whole bubble grows and shrinks with the reader's text size.

    /// Height of the time/ticks line.
    static var statusHeight: CGFloat { ceil(timeFont.lineHeight) + 4 }
    /// A bot's button: tall enough for a comfortable tap, and it grows with the
    /// reader's text size like everything else in the bubble.
    static var buttonHeight: CGFloat { ceil(textFont.lineHeight) + 16 }
    static let buttonGap: CGFloat = 6
    /// A row of buttons is never narrower than this, whatever the text above it.
    static let buttonRowMinWidth: CGFloat = 180
    /// Author name row in groups.
    static var nameHeight: CGFloat { ceil(nameFont.lineHeight) + 2 }
    /// "Forwarded from" row.
    static var forwardHeight: CGFloat { ceil(forwardFont.lineHeight) }
    /// Quoted-message strip: author line over preview line.
    static var replyHeight: CGFloat {
        ceil(Theme.Text.replyAuthor.uiFont.lineHeight + Theme.Text.replyText.uiFont.lineHeight) + 6
    }
    static var replyWidth: CGFloat { TypeScale.scaled(220, max: 340) }
    /// The link card under the text: its labels' fonts and paddings.
    static var linkTitleFont: UIFont { Theme.Text.replyAuthor.uiFont }
    static var linkDescFont: UIFont { Theme.Text.replyText.uiFont }
    static var linkHostFont: UIFont { Theme.Text.replyText.uiFont }
    static var linkCardWidth: CGFloat { TypeScale.scaled(240, max: 360) }
    static let linkCardPad: CGFloat = 6
    /// bar (3) + its gap (6), the same geometry the reply strip draws
    static let linkCardLead: CGFloat = 9
    /// The page's picture in the card: a square thumbnail on the right.
    static var linkThumbSide: CGFloat { TypeScale.scaled(48, max: 68) }
    /// Reaction capsule.
    static var chipHeight: CGFloat { ceil(Theme.Text.reaction.uiFont.lineHeight) + 8 }
    /// Voice waveform and file plate.
    static var attachmentHeight: CGFloat { TypeScale.scaled(42, max: 78) }
    static var attachmentWidth: CGFloat { TypeScale.scaled(220, max: 340) }
    /// Delivery ticks next to the time.
    static var tickWidth: CGFloat { TypeScale.scaled(20, relativeTo: .caption1, max: 34) }
    /// Sender avatar beside an incoming group bubble.
    static var avatarSize: CGFloat { TypeScale.scaled(30, max: 42) }
    /// A shader sticker's square.
    static var stickerSide: CGFloat { TypeScale.scaled(180, max: 260) }
    /// A round video message's diameter.
    static var roundVideoSide: CGFloat { TypeScale.scaled(200, max: 280) }
    /// Horizontal room the avatar column takes: the picture plus its gap.
    static var avatarSpan: CGFloat { avatarSize + 6 }

    /// Plan cache: (message id|width|version) → plan.
    private static let cache = NSCache<NSString, Box>()
    final class Box {
        let plan: BubbleLayoutPlan
        init(_ p: BubbleLayoutPlan) { self.plan = p }
    }

    static func cacheKey(_ msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                         showName: Bool, avatarInset: Bool, ownId: String) -> NSString {
        let reactions = msg.reactions.map { "\($0.key)\($0.value.count)\($0.value.contains(ownId) ? "*" : "")" }.sorted().joined()
        let ver = "\(msg.text ?? "")|\(msg.status.rawValue)|\(msg.edited)|\(reactions)|\(msg.deletedForAll)|\(msg.linkPreview?.url ?? "")|\(msg.linkPreview?.image?.mediaId ?? (msg.linkPreview?.image != nil ? "local" : ""))|\(msg.transcriptShown ? msg.transcript ?? "" : "")"
        return "\(msg.id)|\(Int(width))|\(TypeScale.category.rawValue)|\(tightGap)|\(showTail)|\(showName)|\(avatarInset)|\(ver.hashValue)" as NSString
    }

    static func plan(for msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                     showName: Bool, authorName: String?, replyAuthorName: String? = nil,
                     avatarInset: Bool = false) -> BubbleLayoutPlan {
        let key = cacheKey(msg, width: width, tightGap: tightGap, showTail: showTail,
                           showName: showName, avatarInset: avatarInset, ownId: OwnUser.id)
        if let boxed = cache.object(forKey: key) { return boxed.plan }
        let p = PerfTrace.shared.measure("bubble.measure") {
            compute(for: msg, width: width, tightGap: tightGap, showTail: showTail,
                    showName: showName, authorName: authorName, replyAuthorName: replyAuthorName,
                    avatarInset: avatarInset)
        }
        cache.setObject(Box(p), forKey: key)
        return p
    }

    // MARK: - Computation

    static func clearCache() { cache.removeAllObjects() }

    private static func compute(for msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                                showName: Bool, authorName: String?,
                                replyAuthorName: String?, avatarInset: Bool) -> BubbleLayoutPlan {
        // guards against a collection width reported too small or too large: a bubble is
        // never wider than the screen
        let safeWidth = min(width, UIScreen.main.bounds.width)
        // the avatar column narrows an incoming group bubble the way it shifts it
        let inset = avatarInset && !msg.isOutgoing
        let maxBubbleWidth = floor(safeWidth * Theme.bubbleMaxWidthRatio) - (inset ? avatarSpan : 0)
        let timeString = Self.timeString(msg)
        let statusWidth = Self.statusWidth(msg, timeString: timeString)
        let statusH = statusHeight
        let textFont = Self.textFont

        var contentWidth: CGFloat = 0
        var y: CGFloat = vPadding
        var textFrame: CGRect?
        var attrText: NSAttributedString?
        var mediaFrame: CGRect?
        var albumRects: [MosaicRect] = []
        var voiceFrame: CGRect?
        var shaderFrame: CGRect?
        var replyFrame: CGRect?
        var forwardFrame: CGRect?
        var authorNameFrame: CGRect?
        var statusOnMedia = false

        // author name (groups, incoming, first of a series)
        if showName, !msg.isOutgoing {
            let h = nameHeight
            authorNameFrame = CGRect(x: hPadding, y: y, width: 0, height: h) // width once contentWidth is known
            let nameW = (authorName ?? "").size(withAttributes: [.font: nameFont]).width
            contentWidth = max(contentWidth, min(nameW, maxBubbleWidth - 2 * hPadding))
            y += h + 2
        }

        // forward; a message deleted for everyone is a tombstone and carries
        // nothing but the deletion text — no forward line, no reply strip
        if let fwd = msg.forward, !msg.deletedForAll {
            let text = Self.forwardedFrom(fwd.fromName)
            let h = forwardHeight
            let w = min(text.size(withAttributes: [.font: forwardFont]).width, maxBubbleWidth - 2 * hPadding)
            forwardFrame = CGRect(x: hPadding, y: y, width: w, height: h)
            contentWidth = max(contentWidth, w)
            y += h + 2
        }

        // reply strip
        if msg.replyTo != nil, !msg.deletedForAll {
            let w = min(maxBubbleWidth - 2 * hPadding, replyWidth)
            let h = replyHeight
            replyFrame = CGRect(x: hPadding, y: y, width: w, height: h)
            contentWidth = max(contentWidth, w)
            y += h + 4
        }

        // content
        switch msg.kind {
        case .photo, .video:
            let aspect = CGFloat(msg.media?.w ?? 4) / CGFloat(max(msg.media?.h ?? 3, 1))
            let mw = maxBubbleWidth
            let mh = min(max(mw / max(aspect, 0.4), 120), 420)
            // full bleed only with nothing above: any header row (author name,
            // forward line, reply strip) pushes the media down or it covers them
            let bareMedia = authorNameFrame == nil && forwardFrame == nil && replyFrame == nil
            mediaFrame = CGRect(x: 0, y: bareMedia ? 0 : y, width: mw, height: mh)
            contentWidth = mw - 2 * hPadding
            y = mediaFrame!.maxY
            if let caption = msg.text, !caption.isEmpty {
                y += vPadding
                let (f, a) = measureText(caption, maxWidth: maxBubbleWidth - 2 * hPadding, startY: y)
                textFrame = f
                attrText = a
                contentWidth = max(contentWidth, f.width)
                y = f.maxY
            } else {
                statusOnMedia = true
            }
        case .album:
            let items = (msg.album ?? []).map {
                MosaicItem(aspect: CGFloat($0.w ?? 1) / CGFloat(max($0.h ?? 1, 1)))
            }
            let (rects, size) = AlbumMosaic.layout(items: items, maxWidth: maxBubbleWidth)
            let bareMedia = authorNameFrame == nil && forwardFrame == nil && replyFrame == nil
            let top = bareMedia ? 0 : y
            albumRects = rects
            mediaFrame = CGRect(x: 0, y: top, width: size.width, height: size.height)
            contentWidth = size.width - 2 * hPadding
            y = top + size.height
            statusOnMedia = true
        case .voice:
            let w = attachmentWidth
            let h = attachmentHeight
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h)
            contentWidth = max(contentWidth, w)
            y += h
            // the unfolded transcript reads as ordinary message text under the
            // waveform; the status then follows the text rules further down
            if msg.transcriptShown, let t = msg.transcript, !t.isEmpty {
                y += 4
                let (f, a) = measureText(t, maxWidth: maxBubbleWidth - 2 * hPadding, startY: y)
                textFrame = f
                attrText = a
                contentWidth = max(contentWidth, f.width)
                y = f.maxY
            }
        case .file:
            let w = min(attachmentWidth + 20, maxBubbleWidth - 2 * hPadding)
            let h = attachmentHeight
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h) // a file borrows the voiceFrame slot
            contentWidth = max(contentWidth, w)
            y += h
        case .poll:
            let w = min(attachmentWidth + 40, maxBubbleWidth - 2 * hPadding)
            let h = msg.poll.map { PollMessageView.height(for: $0, width: w) } ?? attachmentHeight
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h) // a poll borrows the voiceFrame slot
            contentWidth = max(contentWidth, w)
            y += h
        case .contact:
            let w = min(attachmentWidth + 20, maxBubbleWidth - 2 * hPadding)
            let h = attachmentHeight
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h) // a contact borrows the voiceFrame slot
            contentWidth = max(contentWidth, w)
            y += h
        case .call:
            let w = min(attachmentWidth, maxBubbleWidth - 2 * hPadding)
            let h = attachmentHeight
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h) // a call borrows the voiceFrame slot
            contentWidth = max(contentWidth, w)
            y += h
        case .location:
            // a map card in the shared slot, wide and 5:3
            let w = min(attachmentWidth + 60, maxBubbleWidth - 2 * hPadding)
            let h = floor(w * 0.6)
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: h)
            contentWidth = max(contentWidth, w)
            y += h
        case .shader:
            // the shader takes a photo's width at 16:9, full bleed like a photo
            // with nothing above it, with the status capsule over the picture
            let mw = maxBubbleWidth
            let mh = floor(mw * 9 / 16)
            let bare = authorNameFrame == nil && forwardFrame == nil && replyFrame == nil
            shaderFrame = CGRect(x: 0, y: bare ? 0 : y, width: mw, height: mh)
            mediaFrame = shaderFrame
            contentWidth = mw - 2 * hPadding
            y = shaderFrame!.maxY
            statusOnMedia = true
        case .roundVideo:
            // a circle with no bubble behind it; the time capsule sits on the
            // circle's lower edge, centered, where the round shape leaves room
            let side = min(roundVideoSide, maxBubbleWidth)
            let bare = authorNameFrame == nil && forwardFrame == nil && replyFrame == nil
            mediaFrame = CGRect(x: 0, y: bare ? 0 : y, width: side, height: side)
            contentWidth = side - 2 * hPadding
            y = mediaFrame!.maxY
            statusOnMedia = true
        case .sticker:
            // a sticker is a square with no bubble behind it: the shader's own
            // alpha decides what shows; the time sits in its capsule as on a photo
            let side = min(stickerSide, maxBubbleWidth)
            let bare = authorNameFrame == nil && forwardFrame == nil && replyFrame == nil
            shaderFrame = CGRect(x: 0, y: bare ? 0 : y, width: side, height: side)
            mediaFrame = shaderFrame
            contentWidth = side - 2 * hPadding
            y = shaderFrame!.maxY
            statusOnMedia = true
        default:
            let display = msg.deletedForAll ? String(localized: "Message deleted") : (msg.text ?? "")
            let (f, a) = measureText(display, maxWidth: maxBubbleWidth - 2 * hPadding, startY: y)
            textFrame = f
            attrText = a
            contentWidth = max(contentWidth, f.width)
            y = f.maxY
        }

        // the link card under the text: title, up to two lines of description,
        // the host — sized here with the same fonts the cell draws them with
        var linkFrame: CGRect?
        if let card = msg.linkPreview, msg.kind == .text, !msg.deletedForAll {
            y += 6
            let w = min(maxBubbleWidth - 2 * hPadding, linkCardWidth)
            let thumb = card.image != nil ? linkThumbSide : 0
            let innerW = w - linkCardLead - (thumb > 0 ? thumb + 8 : 0)
            var cardH = linkCardPad + ceil(linkTitleFont.lineHeight)
            if let desc = card.desc, !desc.isEmpty {
                let bound = (desc as NSString).boundingRect(
                    with: CGSize(width: innerW, height: 2 * linkDescFont.lineHeight + 2),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: linkDescFont], context: nil)
                cardH += 2 + ceil(min(bound.height, 2 * linkDescFont.lineHeight))
            }
            if card.host != nil { cardH += 2 + ceil(linkHostFont.lineHeight) }
            cardH += linkCardPad
            if thumb > 0 { cardH = max(cardH, thumb + 2 * linkCardPad) }
            linkFrame = CGRect(x: hPadding, y: y, width: w, height: cardH)
            contentWidth = max(contentWidth, w)
            y = linkFrame!.maxY
        }

        // a bot's buttons under the message: a row per array, split evenly
        // across the bubble's width
        var buttonFrames: [(button: MessageButton, frame: CGRect)] = []
        if let rows = msg.buttons, !rows.isEmpty, !msg.deletedForAll {
            let w = min(maxBubbleWidth - 2 * hPadding, max(contentWidth, buttonRowMinWidth))
            for row in rows where !row.isEmpty {
                y += buttonGap
                let each = (w - buttonGap * CGFloat(row.count - 1)) / CGFloat(row.count)
                for (i, button) in row.enumerated() {
                    buttonFrames.append((button, CGRect(x: hPadding + CGFloat(i) * (each + buttonGap),
                                                        y: y, width: each, height: buttonHeight)))
                }
                y += buttonHeight
            }
            contentWidth = max(contentWidth, w)
        }

        // --- Reactions: the capsules are measured first, the status placement depends on them ---
        struct Chip { let emoji: String; let count: Int; let mine: Bool; let width: CGFloat }
        let chipH = chipHeight
        let chipGap: CGFloat = 4
        let chipFont = Theme.Text.reaction.uiFont
        let ownId = OwnUser.id
        // the order has to be stable: by count, ties broken by the emoji itself, otherwise
        // the capsules swap places on every redraw
        let chips: [Chip] = msg.reactions
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { emoji, users in
                let label = users.count > 1 ? "\(emoji) \(users.count)" : emoji
                let w = label.size(withAttributes: [.font: chipFont]).width + 18
                return Chip(emoji: emoji, count: users.count, mine: users.contains(ownId), width: w)
            }

        let maxContent = maxBubbleWidth - 2 * hPadding
        let gap: CGFloat = 6
        var statusFrame: CGRect
        var reactionsFrames: [(String, Int, Bool, CGRect)] = []
        var reactionsHeight: CGFloat = 0

        if statusOnMedia, let mf = mediaFrame {
            // the status is a capsule over the media; reactions form their own block below it
            let capsuleH = statusH + 4
            statusFrame = CGRect(x: mf.maxX - statusWidth - 16, y: mf.maxY - capsuleH - 6,
                                 width: statusWidth + 10, height: capsuleH)
            if !chips.isEmpty {
                var rx = hPadding
                var ry = mf.maxY + 4
                for chip in chips {
                    if rx > hPadding, rx + chip.width > maxBubbleWidth - hPadding {
                        rx = hPadding
                        ry += chipH + chipGap
                    }
                    reactionsFrames.append((chip.emoji, chip.count, chip.mine,
                                            CGRect(x: rx, y: ry, width: chip.width, height: chipH)))
                    rx += chip.width + chipGap
                }
                reactionsHeight = ry + chipH - mf.maxY
                y = ry + chipH
            }
        } else if !chips.isEmpty {
            // with reactions present the time follows them instead of the last line of text
            let contentBottom = y
            // text that ends in a code block fills the whole width with its backdrop, so
            // neither the reactions nor the time can sit beside that last line
            let trailingCode = attrText.map(Self.endsWithCodeBlock) ?? false
            let lastLine = (textFrame != nil && attrText != nil && !trailingCode)
                ? Self.lastLineWidth(attrText!, maxWidth: maxContent) : (trailingCode ? maxContent : 0)
            let singleLineText = !trailingCode
                && (textFrame.map { $0.height <= ceil(textFont.lineHeight) + 2 } ?? true)
            let chipsWidth = chips.reduce(0) { $0 + $1.width } + CGFloat(chips.count - 1) * chipGap
            // voice and file: capsules always get their own rows under the waveform or the
            // file plate; the inline "text + reactions + time" row exists for text only
            let inlineAll = voiceFrame == nil && singleLineText && linkFrame == nil
                && lastLine + gap + chipsWidth + gap + statusWidth <= maxContent

            if inlineAll {
                // short text: text, reactions and time all on one line
                let baseY = textFrame?.minY ?? y
                let lineH = max(textFrame?.height ?? chipH, chipH)
                var rx = hPadding + lastLine + (lastLine > 0 ? gap : 0)
                for chip in chips {
                    reactionsFrames.append((chip.emoji, chip.count, chip.mine,
                                            CGRect(x: rx, y: baseY + (lineH - chipH) / 2,
                                                   width: chip.width, height: chipH)))
                    rx += chip.width + chipGap
                }
                contentWidth = max(contentWidth, rx - chipGap - hPadding + gap + statusWidth)
                // the time hugs the bottom of the line, the same as in a bubble without
                // reactions: there the status ends with the text and vPadding remains to the
                // bubble's bottom. Centering on the capsule gave a different inset
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: baseY + lineH - statusH, width: statusWidth, height: statusH)
                y = baseY + lineH
                reactionsHeight = 0
            } else {
                // reactions take their own rows under the text; the time lands at the end of
                // the last row when it fits and drops to the line below when it does not
                var rx = hPadding
                var ry = y + 4
                for chip in chips {
                    if rx > hPadding, rx + chip.width > maxBubbleWidth - hPadding {
                        rx = hPadding
                        ry += chipH + chipGap
                    }
                    reactionsFrames.append((chip.emoji, chip.count, chip.mine,
                                            CGRect(x: rx, y: ry, width: chip.width, height: chipH)))
                    rx += chip.width + chipGap
                    contentWidth = max(contentWidth, rx - chipGap - hPadding)
                }
                let usedInLastRow = rx - chipGap - hPadding
                if usedInLastRow + gap + statusWidth <= maxContent {
                    contentWidth = max(contentWidth, usedInLastRow + gap + statusWidth)
                    statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                         y: ry + chipH - statusH, width: statusWidth, height: statusH)
                    y = ry + chipH
                } else {
                    statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                         y: ry + chipH + 2, width: statusWidth, height: statusH)
                    y = ry + chipH + statusH + 2
                }
                reactionsHeight = y - contentBottom
            }
        } else if let tf = textFrame, let at = attrText {
            // without reactions the time has three placements, the way TG does it; after a
            // code block it always moves to a line of its own
            let lastLineWidth = Self.endsWithCodeBlock(at)
                ? maxContent : Self.lastLineWidth(at, maxWidth: maxContent)
            if linkFrame != nil {
                // the card fills the bubble's bottom, so the time goes under it
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: y + 2, width: statusWidth, height: statusH)
                y += statusH + 2
            } else if lastLineWidth + gap + statusWidth <= maxContent {
                // placement 1 of 3: the status sits in the last line of the text
                let bubbleContentW = max(contentWidth, lastLineWidth + gap + statusWidth)
                contentWidth = bubbleContentW
                statusFrame = CGRect(x: hPadding + bubbleContentW - statusWidth,
                                     y: tf.maxY - statusH, width: statusWidth, height: statusH)
            } else {
                // placement 2: the status is pushed onto a line of its own
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: y + 2, width: statusWidth, height: statusH)
                y += statusH + 2
            }
        } else if voiceFrame != nil {
            // voice or file without reactions: the time goes to the bottom right of the same
            // line that carries the small duration or size, keeping the bubble single-storey
            statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                 y: y - statusH, width: statusWidth, height: statusH)
        } else {
            // any other content without text: the status goes under it on the right
            statusFrame = CGRect(x: hPadding + contentWidth - statusWidth, y: y,
                                 width: statusWidth, height: statusH)
            y += statusH + 2
        }

        y += vPadding
        var bubbleWidth = (mediaFrame != nil && textFrame == nil)
            ? mediaFrame!.width
            : contentWidth + 2 * hPadding
        bubbleWidth = max(bubbleWidth, statusWidth + 2 * hPadding)
        for r in reactionsFrames { bubbleWidth = max(bubbleWidth, r.3.maxX + hPadding) }
        var bubbleHeight = max(y, mediaFrame?.maxY ?? 0)
        if statusOnMedia && chips.isEmpty { bubbleHeight = mediaFrame!.maxY }
        // reaction capsules always stay inside the bubble: its bottom never sits above theirs
        for r in reactionsFrames { bubbleHeight = max(bubbleHeight, r.3.maxY + vPadding) }

        // the gap occupies the top of the cell and the bubble is pinned to its bottom: on
        // screen that is the distance up to the message above, which is what tightGap means
        let seriesGap = tightGap ? groupGap : normalGap
        let bubbleX = msg.isOutgoing ? safeWidth - sideMargin - bubbleWidth
            : sideMargin + (inset ? avatarSpan : 0)
        let bubbleFrame = CGRect(x: bubbleX, y: seriesGap, width: bubbleWidth, height: bubbleHeight)

        // the picture sits in the reserved column, bottom-aligned with the bubble
        // of the run's last message — the same one that carries the tail
        let avatarFrame: CGRect? = inset && showTail
            ? CGRect(x: sideMargin, y: bubbleFrame.maxY - avatarSize,
                     width: avatarSize, height: avatarSize)
            : nil

        // the name width can only be settled now that the bubble width is known
        if var nf = authorNameFrame {
            nf.size.width = bubbleWidth - 2 * hPadding
            authorNameFrame = nf
        }
        // the status is pinned to the right edge of the bubble
        if msg.kind == .roundVideo {
            // centered on the circle's lower edge: the square's corners are
            // empty, so the right-pinned capsule would float in blank space
            statusFrame.origin.x = (bubbleWidth - statusFrame.width) / 2
        } else if statusOnMedia {
            statusFrame.origin.x = bubbleWidth - statusWidth - 18
        } else {
            statusFrame.origin.x = bubbleWidth - statusWidth - hPadding
        }

        return BubbleLayoutPlan(
            cellHeight: bubbleHeight + seriesGap,
            bubbleFrame: bubbleFrame,
            textFrame: textFrame, text: attrText,
            statusFrame: statusFrame, statusOnMedia: statusOnMedia,
            mediaFrame: mediaFrame, albumRects: albumRects,
            voiceFrame: voiceFrame,
            shaderFrame: shaderFrame,
            replyFrame: replyFrame,
            replyAuthor: msg.replyTo != nil ? replyAuthorName : nil,
            replyText: msg.replyTo.map(Self.replyPreviewText),
            linkFrame: linkFrame,
            linkTitle: linkFrame != nil ? msg.linkPreview?.title : nil,
            linkDesc: linkFrame != nil ? msg.linkPreview?.desc : nil,
            linkHost: linkFrame != nil ? msg.linkPreview?.host : nil,
            linkURL: linkFrame != nil ? msg.linkPreview?.url : nil,
            linkImage: linkFrame != nil ? msg.linkPreview?.image : nil,
            buttonFrames: buttonFrames,
            forwardFrame: forwardFrame,
            forwardText: msg.deletedForAll ? nil : msg.forward.map { Self.forwardedFrom($0.fromName) },
            authorNameFrame: authorNameFrame, authorName: authorName,
            avatarFrame: avatarFrame,
            reactionsFrames: reactionsFrames.map { ($0.0, $0.1, $0.2, $0.3) },
            reactionsHeight: reactionsHeight,
            isOutgoing: msg.isOutgoing,
            mentionsMe: !msg.isOutgoing && !msg.deletedForAll && !OwnUser.id.isEmpty
                && MessageMarkdown.mentionsUser(msg.text ?? "", userId: OwnUser.id),
            showTail: showTail,
            timeString: timeString,
            edited: msg.edited,
            statusWidth: statusWidth)
    }

    static func forwardedFrom(_ name: String) -> String {
        String(localized: "Forwarded from \(name)")
    }

    /// The marker next to the time on an edited message; layout and cell share it.
    static let editedMark = String(localized: "edited") + " "

    /// Preview of the quoted message in the reply strip: media gets an icon and a caption
    /// instead of an empty line, text gets itself (or a stand-in when it was not kept).
    static func replyPreviewText(_ reply: ReplyPreview) -> String {
        switch MessageKind(rawValue: reply.kind) {
        case .photo: return String(localized: "📷 Photo")
        case .video: return String(localized: "🎥 Video")
        case .voice: return String(localized: "🎤 Voice message")
        case .roundVideo: return String(localized: "📹 Video message")
        case .poll: return "📊 " + (reply.text.isEmpty ? String(localized: "Poll") : reply.text)
        case .file: return "📎 " + (reply.text.isEmpty ? String(localized: "File") : reply.text)
        case .album: return String(localized: "🖼 Album")
        case .contact: return "👤 " + (reply.text.isEmpty ? String(localized: "Contact") : reply.text)
        case .location: return "📍 " + (reply.text.isEmpty ? String(localized: "Location") : reply.text)
        case .call: return String(localized: "📞 Call")
        case .shader: return "✨ " + (reply.text.isEmpty ? String(localized: "Shader") : reply.text)
        case .sticker: return "✨ " + (reply.text.isEmpty ? String(localized: "Sticker") : reply.text)
        default: return reply.text.isEmpty ? String(localized: "Message") : reply.text
        }
    }

    // MARK: - Text measurement (TextKit)

    /// Text is measured with exactly the attributed string and the TextKit stack that
    /// MessageTextView draws it with, otherwise bubble heights drift.
    private static func measureText(_ text: String, maxWidth: CGFloat, startY: CGFloat) -> (CGRect, NSAttributedString) {
        let attr = MessageMarkdownRenderer.attributed(text)
        let size = textSize(attr, maxWidth: maxWidth)
        return (CGRect(x: hPadding, y: startY, width: size.width, height: size.height), attr)
    }

    static func textSize(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let stack = TextKitStack(attr, maxWidth: maxWidth)
        let glyphs = stack.manager.glyphRange(for: stack.container)
        guard glyphs.length > 0 else { return .zero }
        let used = stack.manager.usedRect(for: stack.container)
        // the height comes from the line fragments: they include paragraph spacing, which is
        // where a code block's vertical padding lives
        let bounding = stack.manager.boundingRect(forGlyphRange: glyphs, in: stack.container)
        var width = used.maxX
        if hasCodeBlock(attr) { width += MessageMarkdownRenderer.codeInset } // right inset of the backdrop
        return CGSize(width: ceil(min(width, maxWidth)), height: ceil(max(used.maxY, bounding.maxY)))
    }

    /// The last block is code: the time must not sit next to its backdrop.
    static func endsWithCodeBlock(_ attr: NSAttributedString) -> Bool {
        guard attr.length > 0 else { return false }
        return attr.attribute(.msngrCodeBlock, at: attr.length - 1, effectiveRange: nil) != nil
    }

    private static func hasCodeBlock(_ attr: NSAttributedString) -> Bool {
        var found = false
        attr.enumerateAttribute(.msngrCodeBlock, in: NSRange(location: 0, length: attr.length)) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    /// The TextKit stack holds the storage: the layout manager refers to it without owning it.
    private final class TextKitStack {
        let storage: NSTextStorage
        let manager = NSLayoutManager()
        let container: NSTextContainer

        init(_ attr: NSAttributedString, maxWidth: CGFloat) {
            storage = NSTextStorage(attributedString: attr)
            container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.maximumNumberOfLines = 0
            manager.addTextContainer(container)
            storage.addLayoutManager(manager)
            manager.ensureLayout(for: container)
        }
    }

    /// Width of the last line, which decides where the time goes.
    static func lastLineWidth(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let stack = TextKitStack(attr, maxWidth: maxWidth)
        let glyphRange = stack.manager.glyphRange(for: stack.container)
        guard glyphRange.length > 0 else { return 0 }
        let lastGlyph = glyphRange.upperBound - 1
        let lineRect = stack.manager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        return ceil(lineRect.width)
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    /// A clock glyph in front of the time reads as "not sent yet" the same
    /// way the failed/sending ticks do, ahead of the time it names.
    static let scheduledMark = "\u{1F551} "

    static func timeString(_ msg: Message) -> String {
        if let scheduledFor = msg.scheduledFor {
            return scheduledMark + hmFormatter.string(from: Date(timeIntervalSince1970: scheduledFor))
        }
        return hmFormatter.string(from: Date(timeIntervalSince1970: msg.serverTs ?? msg.sentAt))
    }

    /// Room in the status line for the listened dots of a voice or round video.
    static let noteDotsSpan: CGFloat = 14

    static func statusWidth(_ msg: Message, timeString: String) -> CGFloat {
        let font = timeFont
        var w = timeString.size(withAttributes: [.font: font]).width
        if msg.edited { w += editedMark.size(withAttributes: [.font: font]).width }
        if msg.isOutgoing { w += tickWidth }
        // the dots' slot is always reserved: the time must not shift when a
        // note flips between heard and unheard
        if msg.kind == .voice || msg.kind == .roundVideo { w += noteDotsSpan }
        return ceil(w) + 2
    }
}
