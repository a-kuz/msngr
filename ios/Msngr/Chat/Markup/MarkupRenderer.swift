import UIKit
import CoreImage

/// Draws a markup document over its picture: strokes in order (a blur takes
/// everything under it, including earlier strokes), then the rotation, then
/// the crop. The editor renders the same way the export does, so what is on
/// screen is what leaves.
enum MarkupRenderer {
    /// `scale` < 1 renders a proportionally smaller picture — the live preview
    /// works on a screen-sized bitmap instead of the full photograph.
    static func render(base: UIImage, document: MarkupDocument, scale: CGFloat = 1) -> UIImage {
        let baseSize = CGSize(width: base.size.width * base.scale, height: base.size.height * base.scale)
        guard baseSize.width > 0, baseSize.height > 0 else { return base }
        let s = min(scale, 1)
        let workSize = CGSize(width: max(1, baseSize.width * s), height: max(1, baseSize.height * s))
        let px = workSize.width / baseSize.width

        var composed = bitmap(size: workSize) { ctx in
            base.draw(in: CGRect(origin: .zero, size: workSize))
            drawStrokes(document.strokes.prefix(while: { $0.tool != .blur }), into: ctx, px: px)
        }
        // a blur takes the picture as composed so far, so the strokes walk in
        // segments: everything up to a blur is drawn, the blur is applied, on
        // to the next segment
        var index = document.strokes.firstIndex(where: { $0.tool == .blur }) ?? document.strokes.count
        while index < document.strokes.count {
            let stroke = document.strokes[index]
            if stroke.tool == .blur, let region = shapeRect(stroke, px: px) {
                composed = blurred(composed, region: region)
            }
            let next = document.strokes[(index + 1)...].firstIndex(where: { $0.tool == .blur })
                ?? document.strokes.count
            let segment = document.strokes[(index + 1)..<next]
            if !segment.isEmpty {
                let under = composed
                composed = bitmap(size: workSize) { ctx in
                    under.draw(in: CGRect(origin: .zero, size: workSize))
                    drawStrokes(segment, into: ctx, px: px)
                }
            }
            index = next
        }

        if document.rotationQuarters % 4 != 0 {
            let turns = CGFloat(document.rotationQuarters % 4)
            let rotatedSize = document.rotatedSize(of: workSize)
            let under = composed
            composed = bitmap(size: rotatedSize) { ctx in
                ctx.cgContext.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
                ctx.cgContext.rotate(by: turns * .pi / 2)
                under.draw(in: CGRect(x: -workSize.width / 2, y: -workSize.height / 2,
                                      width: workSize.width, height: workSize.height))
            }
        }

        if let crop = document.crop {
            let cropPx = CGRect(x: crop.origin.x * px, y: crop.origin.y * px,
                                width: crop.width * px, height: crop.height * px).integral
            if let cg = composed.cgImage, let cut = cg.cropping(to: cropPx) {
                composed = UIImage(cgImage: cut)
            }
        }
        return composed
    }

    /// A copy with the pixels laid the way the bitmap actually stores them:
    /// every draw after this can forget EXIF orientation.
    static func normalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up || image.scale != 1 else { return image }
        return bitmap(size: CGSize(width: image.size.width * image.scale,
                                   height: image.size.height * image.scale)) { _ in
            image.draw(in: CGRect(x: 0, y: 0,
                                  width: image.size.width * image.scale,
                                  height: image.size.height * image.scale))
        }
    }

    // MARK: - Strokes

    private static func bitmap(size: CGSize, _ draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private static func drawStrokes<S: Sequence>(_ strokes: S, into ctx: UIGraphicsImageRendererContext,
                                                 px: CGFloat) where S.Element == MarkupStroke {
        for stroke in strokes {
            switch stroke.tool {
            case .pen: drawPen(stroke, px: px)
            case .line: drawLine(stroke, px: px)
            case .arrow: drawArrow(stroke, px: px)
            case .rect, .ellipse: drawShape(stroke, px: px)
            case .text: drawText(stroke, px: px)
            case .blur: break
            }
        }
    }

    private static func path(width: CGFloat, color: UIColor) -> UIBezierPath {
        color.setStroke()
        let p = UIBezierPath()
        p.lineWidth = width
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        return p
    }

    private static func drawPen(_ stroke: MarkupStroke, px: CGFloat) {
        guard let first = stroke.points.first else { return }
        let p = path(width: stroke.width * px, color: stroke.color)
        p.move(to: scaled(first, px))
        if stroke.points.count == 1 {
            // a tap leaves a dot
            p.addLine(to: scaled(first, px))
        }
        for point in stroke.points.dropFirst() { p.addLine(to: scaled(point, px)) }
        p.stroke()
    }

    private static func drawLine(_ stroke: MarkupStroke, px: CGFloat) {
        guard let a = stroke.points.first, let b = stroke.points.last else { return }
        let p = path(width: stroke.width * px, color: stroke.color)
        p.move(to: scaled(a, px))
        p.addLine(to: scaled(b, px))
        p.stroke()
    }

    private static func drawArrow(_ stroke: MarkupStroke, px: CGFloat) {
        guard let a0 = stroke.points.first, let b0 = stroke.points.last else { return }
        let a = scaled(a0, px), b = scaled(b0, px)
        let p = path(width: stroke.width * px, color: stroke.color)
        p.move(to: a)
        p.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let head = max(stroke.width * 4, 18) * px
        for side: CGFloat in [.pi * 5 / 6, -.pi * 5 / 6] {
            p.move(to: b)
            p.addLine(to: CGPoint(x: b.x + head * cos(angle + side),
                                  y: b.y + head * sin(angle + side)))
        }
        p.stroke()
    }

    private static func drawShape(_ stroke: MarkupStroke, px: CGFloat) {
        guard let rect = shapeRect(stroke, px: px) else { return }
        let p = stroke.tool == .ellipse ? UIBezierPath(ovalIn: rect) : UIBezierPath(rect: rect)
        stroke.color.setStroke()
        p.lineWidth = stroke.width * px
        p.lineJoinStyle = .round
        p.stroke()
    }

    private static func drawText(_ stroke: MarkupStroke, px: CGFloat) {
        guard let anchor = stroke.points.first, !stroke.text.isEmpty else { return }
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = stroke.fontSize * px / 8
        shadow.shadowOffset = .zero
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: stroke.fontSize * px, weight: .semibold),
            .foregroundColor: stroke.color,
            .shadow: shadow,
        ]
        NSAttributedString(string: stroke.text, attributes: attributes).draw(at: scaled(anchor, px))
    }

    /// The bounding box the label takes at scale 1, for hit-testing in the editor.
    static func textBounds(_ stroke: MarkupStroke) -> CGRect {
        guard let anchor = stroke.points.first else { return .zero }
        let size = NSAttributedString(
            string: stroke.text,
            attributes: [.font: UIFont.systemFont(ofSize: stroke.fontSize, weight: .semibold)]).size()
        return CGRect(origin: anchor, size: size)
    }

    private static func shapeRect(_ stroke: MarkupStroke, px: CGFloat) -> CGRect? {
        guard let a = stroke.points.first, let b = stroke.points.last else { return nil }
        return CGRect(x: min(a.x, b.x) * px, y: min(a.y, b.y) * px,
                      width: abs(b.x - a.x) * px, height: abs(b.y - a.y) * px)
    }

    // MARK: - Blur

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private static func blurred(_ image: UIImage, region: CGRect) -> UIImage {
        guard let cg = image.cgImage, region.width > 1, region.height > 1 else { return image }
        let full = CIImage(cgImage: cg)
        let radius = max(6, min(region.width, region.height) / 8)
        let blurredFull = full.clampedToExtent()
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
            .cropped(to: full.extent)
        // Core Image counts from the bottom-left corner
        let ciRegion = CGRect(x: region.minX, y: full.extent.height - region.maxY,
                              width: region.width, height: region.height)
            .intersection(full.extent)
        guard !ciRegion.isEmpty,
              let patch = ciContext.createCGImage(blurredFull.cropped(to: ciRegion), from: ciRegion)
        else { return image }
        let size = CGSize(width: cg.width, height: cg.height)
        return bitmap(size: size) { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            UIImage(cgImage: patch).draw(in: CGRect(x: ciRegion.minX,
                                                    y: size.height - ciRegion.maxY,
                                                    width: ciRegion.width, height: ciRegion.height))
        }
    }

    private static func scaled(_ p: CGPoint, _ px: CGFloat) -> CGPoint {
        CGPoint(x: p.x * px, y: p.y * px)
    }
}
