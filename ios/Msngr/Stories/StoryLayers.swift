import UIKit
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins

/// What a story frame is made of before it is baked: the picture or clip, the
/// way the author placed it on the canvas, the strokes drawn over it and the
/// text and emoji laid on top. Everything is kept in canvas units — fractions
/// of the canvas width and height — so the same frame renders on any screen
/// and exports at any size without a second set of numbers.
struct StoryFrame: Identifiable, Equatable {
    let id = UUID()
    /// The picture, or the clip's poster.
    var image: UIImage
    var isVideo: Bool
    /// The clip on disk while the story is being composed.
    var videoURL: URL?
    var duration: Double?
    /// The clip goes out without its sound track.
    var muted = false
    /// Where the picture sits on the canvas: a scale over the fitted size and an
    /// offset from the centre, as fractions of the canvas width and height.
    var zoom: CGFloat = 1
    var pan: CGPoint = .zero
    var strokes: [StoryStroke] = []
    var layers: [StoryLayer] = []
}

/// A line drawn with a finger, in canvas fractions.
struct StoryStroke: Identifiable, Equatable {
    enum Brush: CaseIterable, Equatable {
        case pen, marker, neon
    }
    let id = UUID()
    var brush: Brush
    var color: String
    /// As a fraction of the canvas width.
    var width: CGFloat
    var points: [CGPoint]
}

/// A piece of text or an emoji sticker placed over the frame.
struct StoryLayer: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case emoji(String)
    }
    let id = UUID()
    var kind: Kind
    /// The centre, as fractions of the canvas width and height.
    var center = CGPoint(x: 0.5, y: 0.5)
    /// A multiplier over the base size the layer is created at.
    var scale: CGFloat = 1
    var rotation: CGFloat = 0
    var font: StoryFont = .classic
    var color = "#ffffff"
    var plate: StoryPlate = .none
    var alignment: NSTextAlignment = .center

    var text: String {
        switch kind {
        case .text(let s), .emoji(let s): return s
        }
    }

    var isEmoji: Bool {
        if case .emoji = kind { return true }
        return false
    }

    /// Everything that changes how the layer is drawn, and nothing about where
    /// it sits: a moved or turned layer keeps its picture.
    struct Appearance: Equatable {
        let kind: Kind
        let scale: CGFloat
        let font: StoryFont
        let color: String
        let plate: StoryPlate
        let alignment: NSTextAlignment
    }

    var appearance: Appearance {
        Appearance(kind: kind, scale: scale, font: font, color: color, plate: plate, alignment: alignment)
    }
}

/// The type a text layer is set in.
enum StoryFont: CaseIterable, Equatable {
    case classic, serif, typewriter, rounded, bold

    var name: String {
        switch self {
        case .classic: return "Classic"
        case .serif: return "Serif"
        case .typewriter: return "Typewriter"
        case .rounded: return "Rounded"
        case .bold: return "Bold"
        }
    }

    func uiFont(size: CGFloat) -> UIFont {
        switch self {
        case .classic:
            return .systemFont(ofSize: size, weight: .semibold)
        case .serif:
            let base = UIFont.systemFont(ofSize: size, weight: .medium)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        case .typewriter:
            return .monospacedSystemFont(ofSize: size, weight: .regular)
        case .rounded:
            let base = UIFont.systemFont(ofSize: size, weight: .heavy)
            return base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        case .bold:
            return .systemFont(ofSize: size, weight: .black)
        }
    }
}

/// The plate behind a text layer; the button cycles through the three.
enum StoryPlate: CaseIterable, Equatable {
    case none, dark, light

    var next: StoryPlate {
        switch self {
        case .none: return .dark
        case .dark: return .light
        case .light: return .none
        }
    }

    var uiColor: UIColor? {
        switch self {
        case .none: return nil
        case .dark: return UIColor.black.withAlphaComponent(0.4)
        case .light: return UIColor.white.withAlphaComponent(0.7)
        }
    }
}

/// Draws a frame the same way on screen and into the exported file: the
/// numbers are canvas fractions and the only input that changes is the size.
enum StoryRenderer {
    /// The text size a fresh layer is created at, as a fraction of the canvas width.
    static let textBase: CGFloat = 0.085
    static let emojiBase: CGFloat = 0.28
    /// The width of the canvas a story is exported at; the height follows the
    /// screen the story was composed on.
    static let exportWidth: CGFloat = 1080

    static func exportSize(for canvas: CGSize) -> CGSize {
        let h = (exportWidth * canvas.height / canvas.width).rounded(.down)
        return CGSize(width: exportWidth, height: h - h.truncatingRemainder(dividingBy: 2))
    }

    // MARK: - The picture

    /// Where the picture lands on a canvas of `size`: fitted, then scaled and
    /// moved the way the author placed it. A clip fills the canvas instead.
    static func imageRect(_ frame: StoryFrame, in size: CGSize) -> CGRect {
        let img = frame.image.size
        guard img.width > 0, img.height > 0 else { return CGRect(origin: .zero, size: size) }
        let fit: CGFloat = frame.isVideo
            ? max(size.width / img.width, size.height / img.height)
            : min(size.width / img.width, size.height / img.height)
        let s = fit * frame.zoom
        let w = img.width * s, h = img.height * s
        let cx = size.width / 2 + frame.pan.x * size.width
        let cy = size.height / 2 + frame.pan.y * size.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// The blurred copy that stands behind a picture which does not fill the
    /// canvas; drawn at a small size and stretched, which is all a blur needs.
    static func backdrop(_ image: UIImage, size: CGSize) -> UIImage? {
        guard let cg = image.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        let small = ci.transformed(by: CGAffineTransform(scaleX: 160 / ci.extent.width, y: 160 / ci.extent.width))
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = small.clampedToExtent()
        filter.radius = 12
        guard let out = filter.outputImage?.cropped(to: small.extent) else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let result = context.createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: result)
    }

    // MARK: - Strokes

    static func path(for stroke: StoryStroke, in size: CGSize) -> UIBezierPath {
        let path = UIBezierPath()
        let pts = stroke.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first)
            return path
        }
        // a quadratic through the midpoints keeps a fast finger from leaving corners
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, controlPoint: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }

    /// How a brush lays its line: one or two passes, each a colour, an alpha
    /// and a width multiplier. Screen layers and the export walk the same list,
    /// and no pass uses a shadow — a shadow is what makes a live stroke stutter.
    struct Pass {
        let color: UIColor
        let widthFactor: CGFloat
    }

    static func passes(for stroke: StoryStroke) -> [Pass] {
        let color = UIColor(hex: stroke.color)
        switch stroke.brush {
        case .pen:
            return [Pass(color: color, widthFactor: 1)]
        case .marker:
            return [Pass(color: color.withAlphaComponent(0.45), widthFactor: 2.2)]
        case .neon:
            return [Pass(color: color.withAlphaComponent(0.55), widthFactor: 2.6),
                    Pass(color: UIColor.white, widthFactor: 0.9)]
        }
    }

    static func draw(_ stroke: StoryStroke, in ctx: CGContext, size: CGSize) {
        let path = path(for: stroke, in: size)
        let width = stroke.width * size.width
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for pass in passes(for: stroke) {
            ctx.setLineWidth(width * pass.widthFactor)
            ctx.setStrokeColor(pass.color.cgColor)
            ctx.addPath(path.cgPath)
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    // MARK: - Layers

    /// A layer as a picture, at `scale` points per canvas fraction: the same
    /// call sets the on-screen view and the exported pixels.
    static func image(for layer: StoryLayer, canvasWidth: CGFloat) -> UIImage {
        let base = layer.isEmoji ? emojiBase : textBase
        let fontSize = base * canvasWidth * layer.scale
        let font = layer.isEmoji ? UIFont.systemFont(ofSize: fontSize) : layer.font.uiFont(size: fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = layer.alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font, .paragraphStyle: paragraph,
            .foregroundColor: layer.isEmoji ? UIColor.white : UIColor(hex: layer.color),
        ]
        if !layer.isEmoji && layer.plate == .none {
            // text over a picture with nothing behind it keeps a soft shadow, so
            // white stays readable over white
            let shadow = NSShadow()
            shadow.shadowColor = UIColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = fontSize * 0.08
            shadow.shadowOffset = CGSize(width: 0, height: fontSize * 0.03)
            attrs[.shadow] = shadow
        }
        let text = NSAttributedString(string: layer.text, attributes: attrs)
        let maxWidth = canvasWidth * 0.86 * layer.scale
        var bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        bounds.size.width = ceil(bounds.width)
        bounds.size.height = ceil(bounds.height)
        let padX = layer.isEmoji ? 0 : fontSize * 0.42
        let padY = layer.isEmoji ? 0 : fontSize * 0.22
        let size = CGSize(width: bounds.width + padX * 2 + 2, height: bounds.height + padY * 2 + 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            if let plate = layer.plate.uiColor, !layer.isEmoji {
                plate.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: fontSize * 0.3).fill()
            }
            text.draw(with: CGRect(x: padX + 1, y: padY + 1, width: bounds.width, height: bounds.height),
                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            _ = ctx
        }
    }

    /// The overlay — strokes and layers — drawn into a context of `size`.
    static func drawOverlay(_ frame: StoryFrame, in ctx: CGContext, size: CGSize) {
        for stroke in frame.strokes { draw(stroke, in: ctx, size: size) }
        for layer in frame.layers {
            let img = image(for: layer, canvasWidth: size.width)
            ctx.saveGState()
            ctx.translateBy(x: layer.center.x * size.width, y: layer.center.y * size.height)
            ctx.rotate(by: layer.rotation)
            img.draw(in: CGRect(x: -img.size.width / 2, y: -img.size.height / 2,
                                width: img.size.width, height: img.size.height))
            ctx.restoreGState()
        }
    }

    // MARK: - Export

    /// The whole picture frame as it leaves: backdrop, picture, strokes, layers.
    static func renderPhoto(_ frame: StoryFrame, canvas: CGSize) -> UIImage {
        let size = exportSize(for: canvas)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            let whole = CGRect(origin: .zero, size: size)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(whole)
            let rect = imageRect(frame, in: size)
            if !whole.contains(rect.insetBy(dx: -1, dy: -1)),
               let backdrop = backdrop(frame.image, size: size) {
                let fill = max(size.width / backdrop.size.width, size.height / backdrop.size.height)
                let w = backdrop.size.width * fill, h = backdrop.size.height * fill
                backdrop.draw(in: CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h))
                cg.setFillColor(UIColor.black.withAlphaComponent(0.25).cgColor)
                cg.fill(whole)
            }
            frame.image.draw(in: rect)
            drawOverlay(frame, in: cg, size: size)
        }
    }

    /// The overlay alone on a clear ground, for a clip.
    static func renderOverlay(_ frame: StoryFrame, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            drawOverlay(frame, in: ctx.cgContext, size: size)
        }
    }

    struct ExportedVideo {
        let data: Data
        let poster: UIImage
        let duration: Double
        let size: CGSize
    }

    /// The clip filling the canvas with the overlay burnt in, as an mp4 of the
    /// export size, at most `maxSeconds` long, silent when the author muted it.
    static func renderVideo(_ frame: StoryFrame, canvas: CGSize, maxSeconds: Double = 60) async -> ExportedVideo? {
        guard let url = frame.videoURL else { return nil }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform),
              let fullDuration = try? await asset.load(.duration) else { return nil }
        let size = exportSize(for: canvas)
        let displayed = CGRect(origin: .zero, size: natural).applying(transform).standardized.size
        let fill = max(size.width / displayed.width, size.height / displayed.height)
        // the clip's own orientation, then the fill scale, then centring
        var t = transform
        let shown = CGRect(origin: .zero, size: natural).applying(transform)
        t = t.concatenating(CGAffineTransform(translationX: -shown.minX, y: -shown.minY))
        t = t.concatenating(CGAffineTransform(scaleX: fill, y: fill))
        t = t.concatenating(CGAffineTransform(translationX: (size.width - displayed.width * fill) / 2,
                                              y: (size.height - displayed.height * fill) / 2))

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: min(fullDuration, CMTime(seconds: maxSeconds, preferredTimescale: 600)))
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              (try? videoTrack.insertTimeRange(range, of: track, at: .zero)) != nil else { return nil }
        if !frame.muted, let audio = try? await asset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try? audioTrack.insertTimeRange(range, of: audio, at: .zero)
        }

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(t, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: range.duration)
        instruction.layerInstructions = [layerInstruction]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = size
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = [instruction]

        if !frame.strokes.isEmpty || !frame.layers.isEmpty {
            let overlay = renderOverlay(frame, size: size)
            let parent = CALayer()
            parent.frame = CGRect(origin: .zero, size: size)
            parent.isGeometryFlipped = true
            let video = CALayer()
            video.frame = parent.frame
            let top = CALayer()
            top.frame = parent.frame
            top.contents = overlay.cgImage
            top.contentsGravity = .resize
            parent.addSublayer(video)
            parent.addSublayer(top)
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
                postProcessingAsVideoLayer: video, in: parent)
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("story-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        export.videoComposition = videoComposition
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            try await export.export(to: out, as: .mp4)
        } catch {
            return nil
        }
        guard let data = try? Data(contentsOf: out) else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: out))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 720, height: 1280)
        let posterCG = try? await gen.image(at: CMTime(seconds: 0.1, preferredTimescale: 600)).image
        let poster = posterCG.map(UIImage.init(cgImage:)) ?? frame.image
        return ExportedVideo(data: data, poster: poster, duration: range.duration.seconds, size: size)
    }
}

extension UIColor {
    /// "#rrggbb", the way a story layer carries its colour.
    convenience init(hex: String) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(cleaned, radix: 16) ?? 0xffffff
        self.init(red: CGFloat((value >> 16) & 0xff) / 255,
                  green: CGFloat((value >> 8) & 0xff) / 255,
                  blue: CGFloat(value & 0xff) / 255, alpha: 1)
    }
}
