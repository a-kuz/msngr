import UIKit
import MsngrCore

/// Готовый план отрисовки одного сообщения: все фреймы посчитаны заранее
/// (в фоне), ячейка только расставляет слои. Никакого Auto Layout в ячейках.
struct BubbleLayoutPlan: Equatable {
    var cellHeight: CGFloat
    var bubbleFrame: CGRect
    var textFrame: CGRect?
    var text: NSAttributedString?
    /// статус (время+галочки): фрейм в координатах баббла
    var statusFrame: CGRect
    var statusOnMedia: Bool         // капсула поверх фото/видео
    var mediaFrame: CGRect?
    var albumRects: [MosaicRect]
    var voiceFrame: CGRect?
    var replyFrame: CGRect?
    var replyAuthor: String?
    var replyText: String?
    var forwardFrame: CGRect?
    var forwardText: String?
    var authorNameFrame: CGRect?    // имя в группах
    var authorName: String?
    var reactionsFrames: [(emoji: String, count: Int, mine: Bool, frame: CGRect)]
    var reactionsHeight: CGFloat
    var isOutgoing: Bool
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

/// userId текущего пользователя, доступный из фоновых замеров (пишется при bootstrap).
enum OwnUser {
    nonisolated(unsafe) static var id: String = ""
}

enum BubbleLayout {
    static let textFont = UIFont.systemFont(ofSize: 17)
    static let timeFont = UIFont.systemFont(ofSize: 12)
    static let nameFont = UIFont.systemFont(ofSize: 14, weight: .semibold)
    static let hPadding: CGFloat = 12
    static let vPadding: CGFloat = 7
    static let sideMargin: CGFloat = 10
    static let groupGap: CGFloat = 2
    static let normalGap: CGFloat = 8

    /// Кэш планов: (msgId|width|версия) → план.
    private static let cache = NSCache<NSString, Box>()
    final class Box {
        let plan: BubbleLayoutPlan
        init(_ p: BubbleLayoutPlan) { self.plan = p }
    }

    static func cacheKey(_ msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                         showName: Bool, ownId: String) -> NSString {
        let reactions = msg.reactions.map { "\($0.key)\($0.value.count)\($0.value.contains(ownId) ? "*" : "")" }.sorted().joined()
        let ver = "\(msg.text ?? "")|\(msg.status.rawValue)|\(msg.edited)|\(reactions)|\(msg.deletedForAll)"
        return "\(msg.id)|\(Int(width))|\(tightGap)|\(showTail)|\(showName)|\(ver.hashValue)" as NSString
    }

    static func plan(for msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                     showName: Bool, authorName: String?) -> BubbleLayoutPlan {
        let key = cacheKey(msg, width: width, tightGap: tightGap, showTail: showTail,
                           showName: showName, ownId: OwnUser.id)
        if let boxed = cache.object(forKey: key) { return boxed.plan }
        let p = compute(for: msg, width: width, tightGap: tightGap, showTail: showTail,
                        showName: showName, authorName: authorName)
        cache.setObject(Box(p), forKey: key)
        return p
    }

    // MARK: - Вычисление

    private static func compute(for msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                                showName: Bool, authorName: String?) -> BubbleLayoutPlan {
        let maxBubbleWidth = floor(width * Theme.bubbleMaxWidthRatio)
        let timeString = Self.timeString(msg)
        let statusWidth = Self.statusWidth(msg, timeString: timeString)

        var contentWidth: CGFloat = 0
        var y: CGFloat = vPadding
        var textFrame: CGRect?
        var attrText: NSAttributedString?
        var mediaFrame: CGRect?
        var albumRects: [MosaicRect] = []
        var voiceFrame: CGRect?
        var replyFrame: CGRect?
        var forwardFrame: CGRect?
        var authorNameFrame: CGRect?
        var statusOnMedia = false

        // имя автора (группы, входящие, первое в серии)
        if showName, !msg.isOutgoing {
            let h: CGFloat = 18
            authorNameFrame = CGRect(x: hPadding, y: y, width: 0, height: h) // ширина после contentWidth
            let nameW = (authorName ?? "").size(withAttributes: [.font: nameFont]).width
            contentWidth = max(contentWidth, min(nameW, maxBubbleWidth - 2 * hPadding))
            y += h + 2
        }

        // форвард
        if let fwd = msg.forward {
            let text = "Переслано от \(fwd.fromName)"
            let w = min(text.size(withAttributes: [.font: timeFont]).width, maxBubbleWidth - 2 * hPadding)
            forwardFrame = CGRect(x: hPadding, y: y, width: w, height: 16)
            contentWidth = max(contentWidth, w)
            y += 18
        }

        // reply-плашка
        if msg.replyTo != nil {
            let w = min(maxBubbleWidth - 2 * hPadding, 220)
            replyFrame = CGRect(x: hPadding, y: y, width: w, height: 36)
            contentWidth = max(contentWidth, w)
            y += 40
        }

        // контент
        switch msg.kind {
        case .photo, .video:
            let aspect = CGFloat(msg.media?.w ?? 4) / CGFloat(max(msg.media?.h ?? 3, 1))
            let mw = maxBubbleWidth
            let mh = min(max(mw / max(aspect, 0.4), 120), 420)
            mediaFrame = CGRect(x: 0, y: msg.replyTo == nil && !showName ? 0 : y, width: mw, height: mh)
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
            albumRects = rects
            mediaFrame = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            contentWidth = size.width - 2 * hPadding
            y = size.height
            statusOnMedia = true
        case .voice:
            let w: CGFloat = 220
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: 44)
            contentWidth = max(contentWidth, w)
            y += 48
        case .file:
            let w: CGFloat = min(240, maxBubbleWidth - 2 * hPadding)
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: 44) // файл использует voiceFrame-слот
            contentWidth = max(contentWidth, w)
            y += 48
        default:
            let display = msg.deletedForAll ? "Сообщение удалено" : (msg.text ?? "")
            let (f, a) = measureText(display, maxWidth: maxBubbleWidth - 2 * hPadding, startY: y)
            textFrame = f
            attrText = a
            contentWidth = max(contentWidth, f.width)
            y = f.maxY
        }

        // --- Размещение статуса: три случая как в TG ---
        var statusFrame: CGRect
        let gap: CGFloat = 6
        if statusOnMedia, let mf = mediaFrame {
            statusFrame = CGRect(x: mf.maxX - statusWidth - 16, y: mf.maxY - 26,
                                 width: statusWidth + 10, height: 20)
        } else if let tf = textFrame, let at = attrText {
            let lastLineWidth = Self.lastLineWidth(at, maxWidth: maxBubbleWidth - 2 * hPadding)
            if lastLineWidth + gap + statusWidth <= maxBubbleWidth - 2 * hPadding {
                // случай 1/3: статус в последней строке
                let bubbleContentW = max(contentWidth, lastLineWidth + gap + statusWidth)
                contentWidth = bubbleContentW
                statusFrame = CGRect(x: hPadding + bubbleContentW - statusWidth,
                                     y: tf.maxY - 16, width: statusWidth, height: 16)
            } else {
                // случай 2: статус на своей строке
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: y + 2, width: statusWidth, height: 16)
                y += 18
            }
        } else {
            // voice/file: статус под контентом справа
            statusFrame = CGRect(x: hPadding + contentWidth - statusWidth, y: y, width: statusWidth, height: 16)
            y += 18
        }

        y += vPadding
        var bubbleWidth = (mediaFrame != nil && textFrame == nil)
            ? mediaFrame!.width
            : contentWidth + 2 * hPadding
        bubbleWidth = max(bubbleWidth, statusWidth + 2 * hPadding)
        var bubbleHeight = max(y, mediaFrame?.maxY ?? 0)
        if statusOnMedia { bubbleHeight = mediaFrame!.maxY }

        // --- Реакции: капсулы флоу-лейаутом ПОД контентом внутри баббла ---
        var reactionsFrames: [(String, Int, Bool, CGRect)] = []
        var reactionsHeight: CGFloat = 0
        if !msg.reactions.isEmpty {
            let ownId = OwnUser.id
            var rx = hPadding
            // под медиа-only бабблом капсулы садятся чуть ниже края фото, без наложения
            var ry = statusOnMedia ? bubbleHeight + 4 : bubbleHeight - vPadding + 4
            let capsuleH: CGFloat = 26
            for (emoji, users) in msg.reactions.sorted(by: { $0.value.count > $1.value.count }) {
                let label = users.count > 1 ? "\(emoji) \(users.count)" : emoji
                let w = label.size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width + 18
                if rx + w > maxBubbleWidth - hPadding {
                    rx = hPadding
                    ry += capsuleH + 4
                }
                reactionsFrames.append((emoji, users.count, users.contains(ownId), CGRect(x: rx, y: ry, width: w, height: capsuleH)))
                rx += w + 4
                bubbleWidth = max(bubbleWidth, rx + hPadding)
            }
            reactionsHeight = ry + capsuleH + vPadding - bubbleHeight + vPadding
            bubbleHeight = ry + capsuleH + vPadding
        }

        let bubbleX = msg.isOutgoing ? width - sideMargin - bubbleWidth : sideMargin
        let bubbleFrame = CGRect(x: bubbleX, y: 0, width: bubbleWidth, height: bubbleHeight)

        // фикс ширины имени
        if var nf = authorNameFrame {
            nf.size.width = bubbleWidth - 2 * hPadding
            authorNameFrame = nf
        }
        // статус прижимаем к правому краю баббла
        if statusOnMedia {
            statusFrame.origin.x = bubbleWidth - statusWidth - 18
        } else {
            statusFrame.origin.x = bubbleWidth - statusWidth - hPadding
        }

        return BubbleLayoutPlan(
            cellHeight: bubbleHeight + (tightGap ? groupGap : normalGap),
            bubbleFrame: bubbleFrame,
            textFrame: textFrame, text: attrText,
            statusFrame: statusFrame, statusOnMedia: statusOnMedia,
            mediaFrame: mediaFrame, albumRects: albumRects,
            voiceFrame: voiceFrame,
            replyFrame: replyFrame,
            replyAuthor: msg.replyTo?.authorId, replyText: msg.replyTo?.text,
            forwardFrame: forwardFrame,
            forwardText: msg.forward.map { "Переслано от \($0.fromName)" },
            authorNameFrame: authorNameFrame, authorName: authorName,
            reactionsFrames: reactionsFrames.map { ($0.0, $0.1, $0.2, $0.3) },
            reactionsHeight: reactionsHeight,
            isOutgoing: msg.isOutgoing,
            showTail: showTail,
            timeString: timeString,
            edited: msg.edited,
            statusWidth: statusWidth)
    }

    // MARK: - Текстовые замеры (TextKit)

    private static func measureText(_ text: String, maxWidth: CGFloat, startY: CGFloat) -> (CGRect, NSAttributedString) {
        let attr = NSAttributedString(string: text, attributes: [.font: textFont])
        let rect = attr.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return (CGRect(x: hPadding, y: startY, width: ceil(rect.width), height: ceil(rect.height)), attr)
    }

    /// Ширина последней строки — ключ к размещению времени.
    static func lastLineWidth(_ attr: NSAttributedString, maxWidth: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: attr)
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        let glyphRange = manager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return 0 }
        let lastGlyph = glyphRange.upperBound - 1
        let lineRect = manager.lineFragmentUsedRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        return ceil(lineRect.width)
    }

    private static let hmFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    static func timeString(_ msg: Message) -> String {
        hmFormatter.string(from: Date(timeIntervalSince1970: msg.serverTs ?? msg.sentAt))
    }

    static func statusWidth(_ msg: Message, timeString: String) -> CGFloat {
        var w = timeString.size(withAttributes: [.font: timeFont]).width
        if msg.edited { w += "изм. ".size(withAttributes: [.font: timeFont]).width }
        if msg.isOutgoing { w += 20 } // галочки
        return ceil(w) + 2
    }
}
