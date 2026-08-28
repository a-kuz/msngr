#if DEBUG
import AVFoundation
import SwiftUI
import MsngrCore

/// Test data for the attachment screens: photos, an album, a video, a file, a
/// voice message and a couple of links, sent through the regular path — the
/// bytes are stashed, uploaded and encrypted exactly as a person's attachment
/// is, so what the gallery reads afterwards is a real chat.
@MainActor
enum AttachmentSeed {
    static func send(chatId: String, batches: Int) async {
        for round in 1...batches {
            await sendPhoto(chatId: chatId, round: round)
            await sendAlbum(chatId: chatId, round: round, count: 3)
            await sendVideo(chatId: chatId, round: round)
            sendFile(chatId: chatId, round: round)
            await sendVoice(chatId: chatId, round: round)
            sendLinks(chatId: chatId, round: round)
            sendShader(chatId: chatId, round: round)
        }
    }

    /// One album per size, so the mosaic can be looked at across its whole range
    /// in a single chat.
    static func sendAlbums(chatId: String, sizes: [Int]) async {
        for (round, size) in sizes.enumerated() {
            await sendAlbum(chatId: chatId, round: round + 1, count: size)
        }
    }

    // MARK: - Frames

    /// A coloured frame with a number on it, so the grid shows at a glance that
    /// the order and the pagination are right.
    private static func image(_ number: Int, size: CGSize = CGSize(width: 900, height: 1200)) -> Data? {
        let hue = Double(number % 12) / 12
        let renderer = UIGraphicsImageRenderer(size: size)
        let png = renderer.image { ctx in
            UIColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let text = "\(number)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: size.height / 3, weight: .bold),
                .foregroundColor: UIColor.white,
            ]
            let bounds = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - bounds.width) / 2,
                                  y: (size.height - bounds.height) / 2), withAttributes: attrs)
        }
        return png.jpegData(compressionQuality: 0.9)
    }

    private static func info(_ jpeg: Data, type: String = "photo") -> MediaInfo? {
        guard let prepared = ImageProcessor.prepareForSending(jpeg),
              let name = try? AppState.shared.media.stash(prepared.data, mime: "image/jpeg")
        else { return nil }
        var media = MediaInfo(type: type, mediaId: "", key: "", hash: "",
                              size: prepared.data.count, mime: "image/jpeg")
        media.localPath = name
        media.w = Int(prepared.size.width)
        media.h = Int(prepared.size.height)
        media.blurhash = ImageProcessor.rgbaPixels(prepared.data).flatMap {
            BlurHash.encode(pixels: $0.pixels, width: $0.width, height: $0.height)
        }
        return media
    }

    // MARK: - Message kinds

    private static func sendPhoto(chatId: String, round: Int) async {
        guard let jpeg = image(round), let media = info(jpeg) else { return }
        var content = ContentPayload(kind: "photo")
        content.media = media
        content.text = "Photo \(round)"
        try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId)
    }

    private static func sendAlbum(chatId: String, round: Int, count: Int) async {
        let medias = (0..<count).compactMap { i -> MediaInfo? in
            image(round * 10 + i).flatMap { info($0) }
        }
        guard medias.count == count else { return }
        var content = ContentPayload(kind: "album")
        content.album = medias
        try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId)
    }

    private static func sendVideo(chatId: String, round: Int) async {
        guard let url = await renderVideo(round), let data = try? Data(contentsOf: url),
              let name = try? AppState.shared.media.stash(data, mime: "video/mp4"),
              let frame = image(round, size: CGSize(width: 480, height: 480)),
              let thumb = try? AppState.shared.media.stash(frame, mime: "image/jpeg")
        else { return }
        var media = MediaInfo(type: "video", mediaId: "", key: "", hash: "",
                              size: data.count, mime: "video/mp4")
        media.localPath = name
        media.thumbLocalPath = thumb
        media.w = 480
        media.h = 480
        media.dur = 2
        media.blurhash = ImageProcessor.rgbaPixels(frame).flatMap {
            BlurHash.encode(pixels: $0.pixels, width: $0.width, height: $0.height)
        }
        var content = ContentPayload(kind: "video")
        content.media = media
        try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId)
        try? FileManager.default.removeItem(at: url)
    }

    private static func sendFile(chatId: String, round: Int) {
        let text = String(repeating: "Report \(round). A line of data.\n", count: 200)
        guard let data = text.data(using: .utf8),
              let name = try? AppState.shared.media.stash(data) else { return }
        var media = MediaInfo(type: "file", mediaId: "", key: "", hash: "",
                              size: data.count, mime: "text/plain")
        media.localPath = name
        media.name = "report-\(round).txt"
        var content = ContentPayload(kind: "file")
        content.media = media
        Task { try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId) }
    }

    private static func sendVoice(chatId: String, round: Int) async {
        guard let url = renderVoice(round), let data = try? Data(contentsOf: url),
              let name = try? AppState.shared.media.stash(data, mime: "audio/mp4") else { return }
        var media = MediaInfo(type: "voice", mediaId: "", key: "", hash: "",
                              size: data.count, mime: "audio/mp4")
        media.localPath = name
        media.dur = 3
        media.waveform = (0..<60).map { Int(16 + 14 * sin(Double($0) / 3)) }
        var content = ContentPayload(kind: "voice")
        content.media = media
        try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId)
        try? FileManager.default.removeItem(at: url)
    }

    /// A small plasma, a different hue per round, so the feed holds several
    /// live shaders at once.
    private static func sendShader(chatId: String, round: Int) {
        let glsl = """
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float t = iTime * 0.7 + \(round).0;
            float v = sin(uv.x * 6.0 + t) + sin((uv.y + uv.x) * 5.0 - t) + sin(length(uv) * 9.0 - t * 2.0);
            vec3 col = 0.5 + 0.5 * cos(v + vec3(0.0, 2.1, 4.2) + \(round).0 * 0.9);
            O = vec4(col, 1.0);
        }
        """
        var content = ContentPayload(kind: "shader")
        content.shader = ShaderDocument(name: "Plasma \(round)", passes: ShaderDocument.fromGLSL(glsl).passes)
        Task { try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId) }
    }

    private static func sendLinks(chatId: String, round: Int) {
        let texts = [
            "Watch this talk: https://developer.apple.com/videos/play/wwdc\(2020 + round % 5)/",
            "Two addresses here: example.com and https://en.wikipedia.org/wiki/Cryptography",
        ]
        for text in texts {
            var content = ContentPayload(kind: "text")
            content.text = text
            Task { try? await AppState.shared.engine?.enqueue(content: content, chatId: chatId) }
        }
    }

    // MARK: - File generation

    /// Two seconds of solid colour as mp4: a real container the viewer plays and
    /// which yields a preview frame.
    private static func renderVideo(_ number: Int) async -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return nil }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 480, AVVideoHeightKey: 480,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
                                                           sourcePixelBufferAttributes: nil)
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        guard let pool = adaptor.pixelBufferPool else { return nil }
        for frame in 0..<60 {
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { break }
            fill(buffer, hue: Double((number + frame / 20) % 12) / 12)
            while !input.isReadyForMoreMediaData { try? await Task.sleep(nanoseconds: 5_000_000) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed ? url : nil
    }

    private static func fill(_ buffer: CVPixelBuffer, hue: Double) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: base,
                                  width: CVPixelBufferGetWidth(buffer),
                                  height: CVPixelBufferGetHeight(buffer),
                                  bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.setFillColor(UIColor(hue: hue, saturation: 0.6, brightness: 0.9, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    }

    /// Three seconds of a tone as m4a: the voice player opens the file as if it
    /// had been recorded.
    private static func renderVoice(_ number: Int) -> URL? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("seed-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
        ]
        guard let file = try? AVAudioFile(forWriting: url, settings: settings),
              let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100 * 3)
        else { return nil }
        buffer.frameLength = 44_100 * 3
        let tone = 220.0 * Double(1 + number % 4)
        for i in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData?[0][i] = Float(sin(2 * .pi * tone * Double(i) / 44_100) * 0.3)
        }
        try? file.write(from: buffer)
        return url
    }
}
#endif
