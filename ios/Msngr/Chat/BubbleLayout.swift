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

    static func clearCache() { cache.removeAllObjects() }

    private static func compute(for msg: Message, width: CGFloat, tightGap: Bool, showTail: Bool,
                                showName: Bool, authorName: String?) -> BubbleLayoutPlan {
        // защита от заниженной/завышенной ширины коллекции: баббл не шире экрана
        let safeWidth = min(width, UIScreen.main.bounds.width)
        let maxBubbleWidth = floor(safeWidth * Theme.bubbleMaxWidthRatio)
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
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: 42)
            contentWidth = max(contentWidth, w)
            y += 42
        case .file:
            let w: CGFloat = min(240, maxBubbleWidth - 2 * hPadding)
            voiceFrame = CGRect(x: hPadding, y: y, width: w, height: 42) // файл использует voiceFrame-слот
            contentWidth = max(contentWidth, w)
            y += 42
        default:
            let display = msg.deletedForAll ? "Сообщение удалено" : (msg.text ?? "")
            let (f, a) = measureText(display, maxWidth: maxBubbleWidth - 2 * hPadding, startY: y)
            textFrame = f
            attrText = a
            contentWidth = max(contentWidth, f.width)
            y = f.maxY
        }

        // --- Реакции: считаем капсулы заранее, размещение статуса зависит от них ---
        struct Chip { let emoji: String; let count: Int; let mine: Bool; let width: CGFloat }
        let chipH: CGFloat = 26
        let chipGap: CGFloat = 4
        let ownId = OwnUser.id
        // порядок стабильный: по количеству, при равенстве — по эмодзи,
        // иначе капсулы прыгают местами при каждой перерисовке
        let chips: [Chip] = msg.reactions
            .sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            .map { emoji, users in
                let label = users.count > 1 ? "\(emoji) \(users.count)" : emoji
                let w = label.size(withAttributes: [.font: UIFont.systemFont(ofSize: 14)]).width + 18
                return Chip(emoji: emoji, count: users.count, mine: users.contains(ownId), width: w)
            }

        let maxContent = maxBubbleWidth - 2 * hPadding
        let gap: CGFloat = 6
        var statusFrame: CGRect
        var reactionsFrames: [(String, Int, Bool, CGRect)] = []
        var reactionsHeight: CGFloat = 0

        if statusOnMedia, let mf = mediaFrame {
            // статус — капсулой поверх медиа; реакции лягут ниже отдельным блоком
            statusFrame = CGRect(x: mf.maxX - statusWidth - 16, y: mf.maxY - 26,
                                 width: statusWidth + 10, height: 20)
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
            // есть реакции → время привязано к ним, а не к последней строке текста
            let contentBottom = y
            // текст, оканчивающийся блоком кода, занимает всю ширину подложкой:
            // ни реакции, ни время рядом с последней строкой не встают
            let trailingCode = attrText.map(Self.endsWithCodeBlock) ?? false
            let lastLine = (textFrame != nil && attrText != nil && !trailingCode)
                ? Self.lastLineWidth(attrText!, maxWidth: maxContent) : (trailingCode ? maxContent : 0)
            let singleLineText = !trailingCode
                && (textFrame.map { $0.height <= ceil(textFont.lineHeight) + 2 } ?? true)
            let chipsWidth = chips.reduce(0) { $0 + $1.width } + CGFloat(chips.count - 1) * chipGap
            // voice/file: капсулы всегда своими рядами под волной/плашкой файла,
            // inline-строка «текст + реакции + время» есть только у текстовых
            let inlineAll = voiceFrame == nil && singleLineText
                && lastLine + gap + chipsWidth + gap + statusWidth <= maxContent

            if inlineAll {
                // короткий текст: текст + реакции + время в одну строку
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
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: baseY + (lineH - 16) / 2, width: statusWidth, height: 16)
                y = baseY + lineH
                reactionsHeight = 0
            } else {
                // реакции — своими рядами под текстом; время садится в конец последнего
                // ряда, если помещается, иначе уходит на строку ниже
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
                                         y: ry + (chipH - 16) / 2, width: statusWidth, height: 16)
                    y = ry + chipH
                } else {
                    statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                         y: ry + chipH + 2, width: statusWidth, height: 16)
                    y = ry + chipH + 18
                }
                reactionsHeight = y - contentBottom
            }
        } else if let tf = textFrame, let at = attrText {
            // без реакций — три случая размещения времени как в TG;
            // после блока кода время всегда уходит на свою строку
            let lastLineWidth = Self.endsWithCodeBlock(at)
                ? maxContent : Self.lastLineWidth(at, maxWidth: maxContent)
            if lastLineWidth + gap + statusWidth <= maxContent {
                // случай 1/3: статус в последней строке текста
                let bubbleContentW = max(contentWidth, lastLineWidth + gap + statusWidth)
                contentWidth = bubbleContentW
                statusFrame = CGRect(x: hPadding + bubbleContentW - statusWidth,
                                     y: tf.maxY - 16, width: statusWidth, height: 16)
            } else {
                // случай 2: статус выталкивается на свою строку
                statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                     y: y + 2, width: statusWidth, height: 16)
                y += 18
            }
        } else if voiceFrame != nil {
            // voice/file без реакций: время в правом нижнем углу той же строки,
            // где мелкая длительность/размер — баббл остаётся одноэтажным
            statusFrame = CGRect(x: hPadding + contentWidth - statusWidth,
                                 y: y - 16, width: statusWidth, height: 16)
        } else {
            // прочий контент без текста: статус под контентом справа
            statusFrame = CGRect(x: hPadding + contentWidth - statusWidth, y: y, width: statusWidth, height: 16)
            y += 18
        }

        y += vPadding
        var bubbleWidth = (mediaFrame != nil && textFrame == nil)
            ? mediaFrame!.width
            : contentWidth + 2 * hPadding
        bubbleWidth = max(bubbleWidth, statusWidth + 2 * hPadding)
        for r in reactionsFrames { bubbleWidth = max(bubbleWidth, r.3.maxX + hPadding) }
        var bubbleHeight = max(y, mediaFrame?.maxY ?? 0)
        if statusOnMedia && chips.isEmpty { bubbleHeight = mediaFrame!.maxY }
        // капсулы реакций всегда внутри баббла: низ баббла не выше низа капсул
        for r in reactionsFrames { bubbleHeight = max(bubbleHeight, r.3.maxY + vPadding) }

        // зазор занимает верх ячейки, баббл прижат к её низу: на экране это
        // расстояние до сообщения выше, о котором и говорит tightGap
        let seriesGap = tightGap ? groupGap : normalGap
        let bubbleX = msg.isOutgoing ? safeWidth - sideMargin - bubbleWidth : sideMargin
        let bubbleFrame = CGRect(x: bubbleX, y: seriesGap, width: bubbleWidth, height: bubbleHeight)

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
            cellHeight: bubbleHeight + seriesGap,
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

    /// Текст меряется ровно тем же attributed-текстом и тем же стеком TextKit,
    /// каким он рисуется в MessageTextView, — иначе поедут высоты бабблов.
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
        // высота — по фрагментам строк: в них входят интервалы абзацев,
        // то есть вертикальные отступы блока кода
        let bounding = stack.manager.boundingRect(forGlyphRange: glyphs, in: stack.container)
        var width = used.maxX
        if hasCodeBlock(attr) { width += MessageMarkdownRenderer.codeInset } // правый отступ подложки
        return CGSize(width: ceil(min(width, maxWidth)), height: ceil(max(used.maxY, bounding.maxY)))
    }

    /// Последний блок — код: время не должно садиться рядом с подложкой.
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

    /// Стек TextKit держит storage: layout manager ссылается на него не владея.
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

    /// Ширина последней строки — ключ к размещению времени.
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
