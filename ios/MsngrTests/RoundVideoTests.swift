import XCTest
import AVFoundation
@testable import Msngr
import MsngrCore

/// The round video bubble: a circle with no bubble backdrop, the time capsule
/// centered on its lower edge, and the previews that name the kind.
final class RoundVideoTests: XCTestCase {
    private let width: CGFloat = 390

    private func roundVideoMessage(outgoing: Bool = true) -> Message {
        var media = MediaInfo(type: "video", mediaId: "m1", key: "k", hash: "h",
                              size: 1000, mime: "video/mp4")
        media.w = 400
        media.h = 400
        media.dur = 5
        var m = Message(id: UUID().uuidString, chatId: "c", fromUserId: outgoing ? "me" : "peer",
                        sentAt: 1_700_000_000, kind: .roundVideo, text: nil,
                        status: .read, isOutgoing: outgoing)
        m.media = media
        m.seq = 1
        m.serverTs = 1_700_000_000
        return m
    }

    private func plan(outgoing: Bool = true) -> BubbleLayoutPlan {
        BubbleLayout.plan(for: roundVideoMessage(outgoing: outgoing), width: width,
                          tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    func testCircleIsSquareOfTheRoundDiameter() {
        let p = plan()
        let mf = try! XCTUnwrap(p.mediaFrame)
        XCTAssertEqual(mf.width, mf.height, "the circle is drawn in a square frame")
        XCTAssertEqual(mf.width, min(BubbleLayout.roundVideoSide,
                                     floor(width * Theme.bubbleMaxWidthRatio)))
    }

    func testStatusCapsuleSitsOverTheCircle() {
        let p = plan()
        XCTAssertTrue(p.statusOnMedia, "no bubble backdrop: the time reads over the video")
        let mf = try! XCTUnwrap(p.mediaFrame)
        // centered horizontally, on the circle's lower edge — the square's
        // right corner is empty space outside the round shape
        XCTAssertEqual(p.statusFrame.midX, p.bubbleFrame.width / 2, accuracy: 1.0)
        XCTAssertLessThan(p.statusFrame.maxY, mf.maxY)
    }

    func testNoTailOnTheCircle() {
        let p = plan()
        XCTAssertTrue(p.statusOnMedia && p.showTail,
                      "the cell hides the tail for statusOnMedia; the plan carries both flags")
    }

    func testReplyPreviewNamesTheKind() {
        let reply = ReplyPreview(seq: 1, authorId: "peer", text: "", kind: "roundVideo")
        XCTAssertFalse(BubbleLayout.replyPreviewText(reply).isEmpty)
        XCTAssertNotEqual(BubbleLayout.replyPreviewText(reply),
                          BubbleLayout.replyPreviewText(ReplyPreview(seq: 1, authorId: "p", text: "", kind: "video")),
                          "a round video is named apart from a plain video")
    }

    /// A landscape take comes out of the crop as the square the bubble draws.
    func testExportRoundClipCropsToSquare() async throws {
        let source = try makeClip(width: 640, height: 360, frames: 12)
        defer { try? FileManager.default.removeItem(at: source) }
        let exported = await ChatScreen.exportRoundClip(AVURLAsset(url: source))
        let out = try XCTUnwrap(exported)
        defer { try? FileManager.default.removeItem(at: out) }
        let tracks = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(Int(size.width), ChatScreen.roundClipSide)
        XCTAssertEqual(Int(size.height), ChatScreen.roundClipSide)
    }

    /// A tiny H.264 clip written frame by frame, in the BGRA the fill draws in.
    private func makeClip(width: Int, height: Int, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let pool = try XCTUnwrap(adaptor.pixelBufferPool)
        for frame in 0..<frames {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let buf = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(buf, [])
            if let base = CVPixelBufferGetBaseAddress(buf) {
                memset(base, 128, CVPixelBufferGetDataSize(buf))
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            while !input.isReadyForMoreMediaData { usleep(5_000) }
            adaptor.append(buf, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        let done = expectation(description: "written")
        writer.finishWriting { done.fulfill() }
        wait(for: [done], timeout: 10)
        XCTAssertEqual(writer.status, .completed)
        return url
    }

    @MainActor
    func testChatListPreviewNamesTheKind() {
        XCTAssertEqual(ChatViewModel.previewText(roundVideoMessage()),
                       String(localized: "Video message"))
    }

    // MARK: - The play-one-after-another chain

    private func note(_ id: String, kind: MessageKind, outgoing: Bool = false,
                      listened: Bool = false) -> ChatFeedItem {
        var m = Message(id: id, chatId: "c", fromUserId: outgoing ? "me" : "peer",
                        sentAt: 1, kind: kind, text: nil, status: .sent, isOutgoing: outgoing)
        m.media = MediaInfo(type: kind == .voice ? "voice" : "video", mediaId: "m", key: "k",
                            hash: "h", size: 1, mime: "video/mp4")
        if listened { m.listenedAt = 1 }
        return .message(m, tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    private func text(_ id: String) -> ChatFeedItem {
        .message(Message(id: id, chatId: "c", fromUserId: "peer", sentAt: 1, kind: .text,
                         text: "hi", status: .sent, isOutgoing: false),
                 tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    @MainActor
    func testChainWalksToTheNextUnheardNoteOfEitherKind() {
        let model = ChatViewModel(chatId: "c")
        // the feed is inverted: [0] is the newest
        model.feed = [note("circle", kind: .roundVideo), text("t1"), note("voice", kind: .voice)]
        XCTAssertEqual(model.nextMediaNote(after: "voice")?.id, "circle",
                       "a text between two notes does not break the chain")
    }

    @MainActor
    func testChainStopsAtAHeardNoteAndAtOurOwn() {
        let model = ChatViewModel(chatId: "c")
        model.feed = [note("heard", kind: .voice, listened: true), note("voice", kind: .voice)]
        XCTAssertNil(model.nextMediaNote(after: "voice"),
                     "a note already heard does not start again on its own")
        model.feed = [note("mine", kind: .roundVideo, outgoing: true), note("voice", kind: .voice)]
        XCTAssertNil(model.nextMediaNote(after: "voice"),
                     "our own note is not part of the incoming chain")
    }
}
