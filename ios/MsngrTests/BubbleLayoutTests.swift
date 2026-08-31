import XCTest
@testable import Msngr
import MsngrCore

/// Layout of a chat bubble: where the time lands, how reactions wrap, what the
/// reply quote shows. Telegram is the reference for time placement.
final class BubbleLayoutTests: XCTestCase {
    private let width: CGFloat = 390 // iPhone width in points

    private func outgoing(_ text: String) -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000, kind: .text, text: text,
                        status: .read, isOutgoing: true)
        m.seq = 1
        m.serverTs = 1_700_000_000
        return m
    }

    private func plan(_ text: String) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: outgoing(text), width: width, tightGap: false,
                          showTail: true, showName: false, authorName: nil)
    }

    /// An unfolded voice transcript reads as message text under the waveform
    /// and grows the bubble; folded, the bubble stays single-storey.
    func testVoiceTranscriptUnfoldsUnderTheWaveform() {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000, kind: .voice, text: nil,
                        status: .read, isOutgoing: true)
        m.seq = 1
        m.transcript = "ну привет, я записал голосовое"
        let folded = BubbleLayout.plan(for: m, width: width, tightGap: false,
                                       showTail: true, showName: false, authorName: nil)
        XCTAssertNil(folded.textFrame, "a folded transcript draws nothing")

        m.transcriptShown = true
        let unfolded = BubbleLayout.plan(for: m, width: width, tightGap: false,
                                         showTail: true, showName: false, authorName: nil)
        let tf = try! XCTUnwrap(unfolded.textFrame)
        let vf = try! XCTUnwrap(unfolded.voiceFrame)
        XCTAssertEqual(unfolded.text?.string, m.transcript)
        XCTAssertGreaterThanOrEqual(tf.minY, vf.maxY, "the text sits under the waveform")
        XCTAssertGreaterThan(unfolded.cellHeight, folded.cellHeight)
    }

    /// Case 1: short single-line text — the time sits inline on the same line.
    func testShortTextTimeInline() {
        let p = plan("Hello")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertLessThan(p.statusFrame.minY, tf.maxY,
                          "short text: the time belongs inline, not below the text")
        XCTAssertGreaterThan(p.statusFrame.minX, tf.minX)
    }

    /// Case 2: a single long line filling almost the whole width pushes the
    /// time onto a line of its own below.
    func testLongLineTimePushedToNewLine() {
        // fits the bubble width, but leaves no room for the time after it
        let p = plan("This line runs right up to the edge.")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
            "long line with no room left: the time must move to a new line under the text")
        // the cell height accounts for that extra status line
        XCTAssertGreaterThan(p.cellHeight, tf.maxY)
    }

    /// Case 3: multiline text whose last line has room to spare — the time
    /// joins the end of that last line instead of starting a new one.
    func testMultilineShortLastLineTimeInline() {
        // long enough to wrap, with a short trailing line
        let p = plan("The time is not on the first line and not on a line of its own. It rides the last one")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThan(tf.height, 30, "the text is expected to wrap")
        XCTAssertLessThan(p.statusFrame.minY, tf.maxY,
            "with a short last line the time belongs inline")
    }

    /// Media without a caption — the time rides in a capsule over the image.
    func testMediaStatusOverlay() {
        var m = outgoing("")
        m.text = nil
        m.kind = .photo
        var media = MediaInfo(type: "photo", mediaId: "x", key: "k", hash: "h", size: 1, mime: "image/jpeg")
        media.w = 1000; media.h = 800
        m.media = media
        let p = BubbleLayout.plan(for: m, width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil)
        XCTAssertTrue(p.statusOnMedia, "on a photo without a caption the status is an overlay capsule")
        let mf = try! XCTUnwrap(p.mediaFrame)
        // capsule in the bottom right corner of the image
        XCTAssertGreaterThan(p.statusFrame.maxY, mf.midY)
        XCTAssertGreaterThan(p.statusFrame.minX, mf.midX)
    }

    private func withReactions(_ text: String, _ reactions: [String: [String]]) -> BubbleLayoutPlan {
        var m = outgoing(text)
        m.reactions = reactions
        return BubbleLayout.plan(for: m, width: width, tightGap: false,
                                 showTail: true, showName: false, authorName: nil)
    }

    /// Short text: text, reaction and time all fit on one line.
    func testShortTextReactionAndTimeOnSameLine() {
        let p = withReactions("OK", ["👍": ["u1"]])
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        let tf = try! XCTUnwrap(p.textFrame)
        // capsule right of the text, time right of the capsule, all on one line
        XCTAssertGreaterThan(chip.frame.minX, tf.minX)
        XCTAssertGreaterThan(p.statusFrame.minX, chip.frame.minX)
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 6,
                          "the time and the reaction must share a line")
    }

    /// Multiline text with reactions: the time leaves the last text line and
    /// moves down to the reactions row.
    func testTimeMovesToReactionRowForMultilineText() {
        let p = withReactions("A fairly long message that is certain to take up several lines in a row",
                              ["😂": ["u1", "u2"], "🔥": ["u3"]])
        let tf = try! XCTUnwrap(p.textFrame)
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
            "with reactions present the time must not stay on the last text line")
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 8,
            "the time must sit on the reactions line")
        XCTAssertGreaterThan(p.statusFrame.minX, chip.frame.maxX,
            "the time goes to the right of the reaction capsules")
    }

    /// Many reactions wrap onto several rows, all of them inside the bubble.
    func testManyReactionsWrapToMultipleRows() {
        let emojis = ["😂", "🔥", "❤️", "👍", "😮", "😢", "🎉", "🙏", "👏", "💯"]
        var reactions: [String: [String]] = [:]
        for (i, e) in emojis.enumerated() { reactions[e] = ["u\(i)"] }
        let p = withReactions("Text", reactions)
        XCTAssertEqual(p.reactionsFrames.count, emojis.count)
        let rows = Set(p.reactionsFrames.map { Int($0.frame.minY.rounded()) })
        XCTAssertGreaterThan(rows.count, 1, "capsules must wrap onto new rows")
        for r in p.reactionsFrames {
            XCTAssertLessThanOrEqual(r.frame.maxX, p.bubbleFrame.width,
                                     "a capsule must not stick out of the bubble")
        }
        XCTAssertLessThanOrEqual(p.statusFrame.maxX, p.bubbleFrame.width)
    }

    /// A reaction must not shift the time and the ticks: the status keeps the same
    /// insets from the bubble's right and bottom edges as it does without reactions.
    func testReactionKeepsStatusInsetsOfPlainBubble() {
        let cases: [(name: String, text: String, reactions: [String: [String]])] = [
            ("short text, one reaction", "OK", ["👍": ["u1"]]),
            ("multiline text, two reactions",
             "A fairly long message that is certain to take up several lines in a row",
             ["😂": ["u1", "u2"], "🔥": ["u3"]]),
            ("reactions over several rows", "Text",
             ["😂": ["u1"], "🔥": ["u2"], "❤️": ["u3"], "👍": ["u4"], "😮": ["u5"],
              "😢": ["u6"], "🎉": ["u7"], "🙏": ["u8"], "👏": ["u9"], "💯": ["u10"]]),
        ]
        for c in cases {
            let plain = plan(c.text)
            let withR = withReactions(c.text, c.reactions)
            XCTAssertEqual(rightInset(plain), rightInset(withR), accuracy: 0.5,
                           "\(c.name): the time's inset on the right")
            XCTAssertEqual(bottomInset(plain), bottomInset(withR), accuracy: 0.5,
                           "\(c.name): the time's inset at the bottom")
            XCTAssertEqual(bottomInset(withR), BubbleLayout.vPadding, accuracy: 0.5,
                           "\(c.name): the time sits on the bubble's bottom padding")
        }
    }

    private func rightInset(_ p: BubbleLayoutPlan) -> CGFloat { p.bubbleFrame.width - p.statusFrame.maxX }
    private func bottomInset(_ p: BubbleLayoutPlan) -> CGFloat { p.bubbleFrame.height - p.statusFrame.maxY }

    /// The bubble never collapses narrower than the time it has to show.
    func testBubbleNotNarrowerThanStatus() {
        let p = plan("!")
        XCTAssertGreaterThanOrEqual(p.bubbleFrame.width, p.statusWidth)
    }

    /// A plain text message without reactions still draws a visible bubble:
    /// at least one text line tall plus the vertical padding.
    func testPlainTextWithoutReactionsHasVisibleBubble() {
        let p = plan("Test message 1")
        XCTAssertGreaterThan(p.bubbleFrame.height, 0)
        XCTAssertGreaterThanOrEqual(
            p.bubbleFrame.height,
            ceil(BubbleLayout.textFont.lineHeight) + 2 * BubbleLayout.vPadding,
            "the bubble is no shorter than a text line with its padding")
        XCTAssertGreaterThan(p.cellHeight, p.bubbleFrame.height - 1)
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThan(tf.width, 0)
        XCTAssertGreaterThan(tf.height, 0)
    }

    /// Short text: a fixed gap between text and time, with the time flush
    /// against the right edge of the bubble.
    func testShortTextStatusPinnedToBubbleRightEdge() {
        let p = plan("Sown")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertEqual(p.statusFrame.maxX, p.bubbleFrame.width - BubbleLayout.hPadding,
                       accuracy: 0.5, "the time is flush with the right edge of the bubble")
        XCTAssertEqual(p.statusFrame.minX - tf.maxX, 6, accuracy: 1.5,
                       "the gap between text and time is fixed")
    }

    // MARK: - Gap between bubbles

    private func gapPlan(tightGap: Bool) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: outgoing("Hello"), width: width, tightGap: tightGap,
                          showTail: true, showName: false, authorName: nil)
    }

    /// Inside a run of messages the gap is groupGap, between runs normalGap;
    /// the bubble itself keeps the same height either way.
    func testCellHeightTightVersusNormalGap() {
        let tight = gapPlan(tightGap: true)
        let normal = gapPlan(tightGap: false)
        XCTAssertEqual(tight.bubbleFrame.height, normal.bubbleFrame.height,
                       "the gap must not change the height of the bubble itself")
        XCTAssertEqual(tight.cellHeight - tight.bubbleFrame.height, BubbleLayout.groupGap, accuracy: 0.01)
        XCTAssertEqual(normal.cellHeight - normal.bubbleFrame.height, BubbleLayout.normalGap, accuracy: 0.01)
        XCTAssertEqual(normal.cellHeight - tight.cellHeight,
                       BubbleLayout.normalGap - BubbleLayout.groupGap, accuracy: 0.01)
    }

    /// The gap sits above the bubble: the cell is flipped, so its top on screen
    /// is the border with the message above — the one tightGap talks about.
    func testGapSitsAboveBubble() {
        XCTAssertEqual(gapPlan(tightGap: true).bubbleFrame.minY, BubbleLayout.groupGap, accuracy: 0.01)
        XCTAssertEqual(gapPlan(tightGap: false).bubbleFrame.minY, BubbleLayout.normalGap, accuracy: 0.01)
        // the bubble is flush with the bottom of the cell: no empty space under it
        for tight in [true, false] {
            let p = gapPlan(tightGap: tight)
            XCTAssertEqual(p.bubbleFrame.maxY, p.cellHeight, accuracy: 0.01)
        }
    }

    // MARK: - Mini markdown

    /// A code block takes more room than the same text unformatted: the inset
    /// backdrop plus the time on a line of its own.
    func testCodeBlockBubbleIsTallerThanPlainText() {
        let plain = plan("let a = 1")
        let code = plan("```\nlet a = 1\n```")
        XCTAssertGreaterThan(code.bubbleFrame.height, plain.bubbleFrame.height,
                             "a bubble with a code block has to be taller")
        XCTAssertGreaterThan(code.cellHeight, plain.cellHeight)
    }

    /// A multiline code block is taller than a one-liner by at least a line.
    func testMultilineCodeBlockGrowsWithLines() {
        let one = plan("```\nlet a = 1\n```")
        let three = plan("```\nlet a = 1\nlet b = 2\nlet c = 3\n```")
        XCTAssertGreaterThan(three.bubbleFrame.height - one.bubbleFrame.height,
                             2 * BubbleLayout.textFont.lineHeight - 6)
    }

    /// After a code block the time does not join the last line.
    func testStatusBelowCodeBlock() {
        let p = plan("```\nx\n```")
        let tf = try! XCTUnwrap(p.textFrame)
        XCTAssertGreaterThanOrEqual(p.statusFrame.minY, tf.maxY - 2,
                                    "the time must move below the code backdrop")
    }

    /// Markup markers never reach the bubble; the styles they carry do.
    func testMarkersAreNotRendered() {
        let p = plan("**bold** and `code`")
        let attr = try! XCTUnwrap(p.text)
        XCTAssertEqual(attr.string, "bold and code")
        let boldFont = attr.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        XCTAssertTrue(boldFont?.fontDescriptor.symbolicTraits.contains(.traitBold) ?? false)
        let codeFont = attr.attribute(.font, at: attr.length - 1, effectiveRange: nil) as? UIFont
        XCTAssertEqual(codeFont, MessageMarkdownRenderer.codeFont)
    }

    /// A link gets the .msngrLink attribute; that is what makes the cell open a browser.
    func testLinkAttributePresent() {
        let attr = try! XCTUnwrap(plan("tap https://example.com right here").text)
        var found: URL?
        attr.enumerateAttribute(.msngrLink, in: NSRange(location: 0, length: attr.length)) { value, _, _ in
            if let url = value as? URL { found = url }
        }
        XCTAssertEqual(found, URL(string: "https://example.com"))
    }

    /// The size in the plan matches a direct measurement of the same attributed
    /// text: what gets drawn is exactly what was measured.
    func testTextFrameMatchesMeasuredSize() {
        for source in ["Hello", "**bold** text", "```\nlet a = 1\nlet b = 22\n```",
                       "text\n```\ncode\n```\ntail"] {
            let p = plan(source)
            let tf = try! XCTUnwrap(p.textFrame)
            let attr = try! XCTUnwrap(p.text)
            let maxContent = floor(width * Theme.bubbleMaxWidthRatio) - 2 * BubbleLayout.hPadding
            let size = BubbleLayout.textSize(attr, maxWidth: maxContent)
            XCTAssertEqual(tf.width, size.width, accuracy: 0.01, source)
            XCTAssertEqual(tf.height, size.height, accuracy: 0.01, source)
        }
    }

    // MARK: - Reactions on voice and file bubbles

    private func mediaMessage(_ kind: MessageKind, reactions: [String: [String]]) -> Message {
        var m = outgoing("")
        m.text = nil
        m.kind = kind
        var media = MediaInfo(type: kind == .voice ? "voice" : "file", mediaId: "x",
                              key: "k", hash: "h", size: 1,
                              mime: kind == .voice ? "audio/mp4" : "application/octet-stream")
        media.dur = 3
        m.media = media
        m.reactions = reactions
        return m
    }

    private func mediaPlan(_ kind: MessageKind, _ reactions: [String: [String]]) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: mediaMessage(kind, reactions: reactions), width: width,
                          tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    /// No capsule and no status may cross the edge of the bubble.
    private func assertReactionsInsideBubble(_ p: BubbleLayoutPlan,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for r in p.reactionsFrames {
            XCTAssertLessThanOrEqual(r.frame.maxY, p.bubbleFrame.height,
                                     "a capsule must not hang below the bubble", file: file, line: line)
            XCTAssertLessThanOrEqual(r.frame.maxX, p.bubbleFrame.width,
                                     "a capsule must not cross the right edge", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(p.statusFrame.maxY, p.bubbleFrame.height, file: file, line: line)
    }

    /// Voice with one reaction: the bubble grows, the capsule goes under the
    /// waveform, the time sits on that row, everything stays inside.
    func testVoiceBubbleGrowsForOneReaction() {
        let base = mediaPlan(.voice, [:])
        let p = mediaPlan(.voice, ["👍": ["u1", "u2"]])
        XCTAssertGreaterThan(p.bubbleFrame.height, base.bubbleFrame.height,
                             "a bubble with a reaction has to be taller")
        let chip = try! XCTUnwrap(p.reactionsFrames.first)
        let vf = try! XCTUnwrap(p.voiceFrame)
        XCTAssertGreaterThanOrEqual(chip.frame.minY, vf.maxY, "the capsule goes under the waveform")
        XCTAssertLessThan(abs(p.statusFrame.midY - chip.frame.midY), 8,
                          "the time sits on the reactions row")
        assertReactionsInsideBubble(p)
    }

    /// Voice with five reactions: the bubble grows by at least a capsule row.
    func testVoiceBubbleGrowsForFiveReactions() {
        let base = mediaPlan(.voice, [:])
        let reactions = ["😂": ["u1", "u2"], "🔥": ["u3", "u4"], "❤️": ["u5", "u6"],
                         "👍": ["u7", "u8"], "💯": ["u9", "u10"]]
        let p = mediaPlan(.voice, reactions)
        XCTAssertEqual(p.reactionsFrames.count, 5)
        XCTAssertGreaterThanOrEqual(p.bubbleFrame.height - base.bubbleFrame.height, 26,
                                    "the bubble grows by no less than the height of a capsule row")
        let vf = try! XCTUnwrap(p.voiceFrame)
        for r in p.reactionsFrames {
            XCTAssertGreaterThanOrEqual(r.frame.minY, vf.maxY, "capsules go under the waveform")
        }
        assertReactionsInsideBubble(p)
    }

    // MARK: - Reply quote

    private func replyPlan(replyTo: ReplyPreview, replyAuthorName: String?) -> BubbleLayoutPlan {
        var m = outgoing("Reply text")
        m.replyTo = replyTo
        return BubbleLayout.plan(for: m, width: width, tightGap: false, showTail: true,
                                 showName: false, authorName: nil, replyAuthorName: replyAuthorName)
    }

    /// The quote shows the name the caller resolved from user/participants,
    /// never the raw userId in replyTo.authorId.
    func testReplyAuthorUsesResolvedName() {
        let reply = ReplyPreview(seq: nil, authorId: "01KZXED9XMFKTKYDBVH30C", text: "hello", kind: "text")
        let p = replyPlan(replyTo: reply, replyAuthorName: "Anna")
        XCTAssertEqual(p.replyAuthor, "Anna")
        XCTAssertNotEqual(p.replyAuthor, reply.authorId, "a quote must never show a raw userId")
    }

    /// Replying to your own message: the quote is attributed to you.
    func testReplyAuthorShowsYouForOwnMessage() {
        let reply = ReplyPreview(seq: nil, authorId: "me", text: "my message", kind: "text")
        let p = replyPlan(replyTo: reply, replyAuthorName: "You")
        XCTAssertEqual(p.replyAuthor, "You")
    }

    /// Without a quote replyAuthor stays nil, even when a name is available.
    func testReplyAuthorNilWithoutReplyTo() {
        let p = BubbleLayout.plan(for: outgoing("no reply"), width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil,
                                  replyAuthorName: "Anna")
        XCTAssertNil(p.replyAuthor)
    }

    /// Comparisons go through the same catalog key the product reads, so the
    /// test holds in whatever language the simulator runs.
    private func s(_ key: String.LocalizationValue) -> String {
        String(localized: key)
    }

    /// A quote of a non-text message previews as an icon plus a caption.
    func testReplyPreviewTextForEachKind() {
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "Photo", kind: "photo")), s("📷 Photo"))
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "Video", kind: "video")), s("🎥 Video"))
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "Voice message", kind: "voice")),
            s("🎤 Voice message"))
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "Contract.pdf", kind: "file")), "📎 Contract.pdf")
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "", kind: "album")), s("🖼 Album"))
    }

    /// When the stored text is empty (a file without a name, a missing preview)
    /// the quote falls back to a placeholder instead of an empty line.
    func testReplyPreviewTextFallsBackWhenEmpty() {
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "", kind: "file")), "📎 " + s("File"))
        XCTAssertEqual(BubbleLayout.replyPreviewText(
            ReplyPreview(seq: nil, authorId: "u", text: "", kind: "text")), s("Message"))
    }

    /// The plan builds its preview line through replyPreviewText rather than
    /// copying replyTo.text.
    func testPlanReplyTextUsesPreviewMapping() {
        let reply = ReplyPreview(seq: nil, authorId: "peer", text: "Video", kind: "video")
        let p = replyPlan(replyTo: reply, replyAuthorName: "Pete")
        XCTAssertEqual(p.replyText, s("🎥 Video"))
    }

    /// A file bubble with reactions: same guarantees as voice.
    func testFileBubbleGrowsForReactions() {
        let base = mediaPlan(.file, [:])
        let one = mediaPlan(.file, ["👍": ["u1", "u2"]])
        let five = mediaPlan(.file, ["😂": ["u1", "u2"], "🔥": ["u3", "u4"], "❤️": ["u5", "u6"],
                                     "👍": ["u7", "u8"], "💯": ["u9", "u10"]])
        XCTAssertGreaterThan(one.bubbleFrame.height, base.bubbleFrame.height)
        XCTAssertGreaterThanOrEqual(five.bubbleFrame.height - base.bubbleFrame.height, 26)
        for p in [one, five] {
            let vf = try! XCTUnwrap(p.voiceFrame)
            for r in p.reactionsFrames {
                XCTAssertGreaterThanOrEqual(r.frame.minY, vf.maxY, "capsules go under the file row")
            }
            assertReactionsInsideBubble(p)
        }
    }

    // MARK: - Dynamic Type

    /// The reader's text size drives the whole bubble: at an accessibility size
    /// the same message is taller, and its time line grows with it. A plan
    /// measured at the old size must not survive the change.
    func testBubbleGrowsWithTextSize() {
        let msg = outgoing("Hello, how are you?")
        let measure = { (category: UIContentSizeCategory) -> BubbleLayoutPlan in
            TypeScale.apply(category)
            return BubbleLayout.plan(for: msg, width: self.width, tightGap: false,
                                     showTail: true, showName: false, authorName: nil)
        }
        defer { TypeScale.apply(.large) }

        let small = measure(.extraSmall)
        let large = measure(.large)
        let huge = measure(.accessibilityExtraExtraExtraLarge)

        XCTAssertGreaterThan(large.cellHeight, small.cellHeight)
        XCTAssertGreaterThan(huge.cellHeight, large.cellHeight)
        XCTAssertGreaterThan(huge.statusFrame.height, large.statusFrame.height)
        XCTAssertGreaterThan(huge.statusWidth, large.statusWidth)
        // the bubble still has to hold what it measured
        for p in [small, large, huge] {
            let tf = try! XCTUnwrap(p.textFrame)
            XCTAssertLessThanOrEqual(tf.maxY, p.bubbleFrame.height)
            XCTAssertLessThanOrEqual(p.statusFrame.maxX, p.bubbleFrame.width)
        }
    }

    /// Reaction capsules stay inside the bubble at every text size — a stale
    /// chip height is exactly what makes them hang out of it.
    func testReactionsStayInsideBubbleAtEverySize() {
        defer { TypeScale.apply(.large) }
        for category in [UIContentSizeCategory.extraSmall, .large,
                         .accessibilityExtraExtraExtraLarge] {
            TypeScale.apply(category)
            let p = mediaPlan(.voice, ["😂": ["u1", "u2"], "🔥": ["u3"], "❤️": ["u4", "u5"]])
            assertReactionsInsideBubble(p)
        }
    }

    /// A voice bubble is the plate and nothing else: the time shares the plate's
    /// bottom line at every text size instead of opening a storey of its own.
    func testVoiceTimeStaysOnThePlateAtEverySize() {
        defer { TypeScale.apply(.large) }
        for category in [UIContentSizeCategory.extraSmall, .large, .extraExtraLarge,
                         .accessibilityExtraExtraExtraLarge] {
            TypeScale.apply(category)
            let p = mediaPlan(.voice, [:])
            let vf = try! XCTUnwrap(p.voiceFrame)
            XCTAssertEqual(p.statusFrame.maxY, vf.maxY, accuracy: 0.5, "\(category.rawValue)")
            XCTAssertGreaterThanOrEqual(p.statusFrame.minY, vf.minY, "\(category.rawValue)")
            XCTAssertEqual(p.bubbleFrame.height, vf.height + 2 * BubbleLayout.vPadding,
                           accuracy: 0.5, "\(category.rawValue)")
        }
    }

    // MARK: - Forward line over media

    private func forwarded(_ kind: MessageKind) -> Message {
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000, kind: kind, text: nil,
                        status: .sent, isOutgoing: false)
        m.seq = 1
        m.forward = ForwardInfo(fromUserId: "orig", fromName: "Bob")
        let item = MediaInfo(type: "photo", mediaId: "b", key: "k", hash: "h", size: 1, mime: "image/jpeg")
        if kind == .album { m.album = [item, item, item] } else { m.media = item }
        return m
    }

    /// down instead of bleeding over the header.
    func testForwardedPhotoMediaBelowForwardLine() {
        let p = BubbleLayout.plan(for: forwarded(.photo), width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil)
        let ff = try! XCTUnwrap(p.forwardFrame)
        let mf = try! XCTUnwrap(p.mediaFrame)
        XCTAssertGreaterThanOrEqual(mf.minY, ff.maxY,
            "forwarded photo: the mosaic must start below the forward line, not cover it")
    }

    /// The same for an album: the mosaic starts below the forward line.
    func testForwardedAlbumMediaBelowForwardLine() {
        let p = BubbleLayout.plan(for: forwarded(.album), width: width, tightGap: false,
                                  showTail: true, showName: false, authorName: nil)
        let ff = try! XCTUnwrap(p.forwardFrame)
        let mf = try! XCTUnwrap(p.mediaFrame)
        XCTAssertGreaterThanOrEqual(mf.minY, ff.maxY)
        // the status capsule sits on the media, and the cell ends with it
        XCTAssertGreaterThanOrEqual(p.cellHeight, mf.maxY)
    }
}
