import CoreGraphics
import Foundation

/// An album item: the aspect ratio (width/height) of a photo or a video.
public struct MosaicItem {
    public let aspect: CGFloat
    public init(aspect: CGFloat) { self.aspect = aspect }
}

/// A tile's frame in the finished layout; index is the item's position in the input array.
public struct MosaicRect {
    public let index: Int
    public let frame: CGRect
    public init(index: Int, frame: CGRect) {
        self.index = index
        self.frame = frame
    }
}

/// Album layout inside a bubble, along the lines of MosaicLayout in Telegram iOS:
/// fixed patterns for 1 to 4 items; from 5 to 10 the items are split into rows of
/// two or three tiles, chosen to distort the aspect ratios as little as possible.
public enum AlbumMosaic {

    // Above this ratio an item counts as wide.
    private static let wideAspect: CGFloat = 1.2
    // Input aspects are clamped so extreme values cannot wreck the grid.
    private static let aspectRange: ClosedRange<CGFloat> = 0.45...2.5
    // The comfortable row height the row search aims for.
    private static let idealRowFactor: CGFloat = 0.45

    public static func layout(items: [MosaicItem], maxWidth: CGFloat,
                              spacing: CGFloat = 2) -> (rects: [MosaicRect], size: CGSize) {
        guard !items.isEmpty, maxWidth > 0 else { return ([], .zero) }
        let aspects = items.map { $0.aspect > 0 ? min(max($0.aspect, aspectRange.lowerBound), aspectRange.upperBound) : 1 }
        let w = maxWidth

        let result: (rects: [MosaicRect], size: CGSize)
        switch aspects.count {
        case 1:
            let h = clamp(w / aspects[0], w * 0.35, w * 1.4)
            result = ([MosaicRect(index: 0, frame: CGRect(x: 0, y: 0, width: w, height: h))],
                      CGSize(width: w, height: h))
        case 2:
            // Two wide items stack; anything else sits side by side.
            let rows = (aspects[0] > wideAspect && aspects[1] > wideAspect) ? [[0], [1]] : [[0, 1]]
            result = rowsLayout(rows: rows, aspects: aspects, width: w, spacing: spacing)
        case 3:
            if aspects[0] > wideAspect {
                // The wide one on top, the other two below it.
                result = rowsLayout(rows: [[0], [1, 2]], aspects: aspects, width: w, spacing: spacing)
            } else {
                result = bigLeft(aspects: aspects, width: w, spacing: spacing)
            }
        case 4:
            let rows = aspects[0] > wideAspect ? [[0], [1, 2, 3]] : [[0, 1], [2, 3]]
            result = rowsLayout(rows: rows, aspects: aspects, width: w, spacing: spacing)
        default:
            result = bestRows(aspects: aspects, width: w, spacing: spacing)
        }
        return capHeight(result, maxHeight: w * 1.9)
    }

    // MARK: - Pattern for three items: one big on the left, two stacked on the right

    private static func bigLeft(aspects: [CGFloat], width w: CGFloat,
                                spacing: CGFloat) -> (rects: [MosaicRect], size: CGSize) {
        let contentW = w - spacing
        let leftW = (contentW * 2 / 3).rounded()
        let rightW = contentW - leftW
        let h = clamp(leftW / aspects[0], w * 0.4, w)
        let rightH = (h - spacing) / 2
        let rects = [
            MosaicRect(index: 0, frame: CGRect(x: 0, y: 0, width: leftW, height: h)),
            MosaicRect(index: 1, frame: CGRect(x: leftW + spacing, y: 0, width: rightW, height: rightH)),
            MosaicRect(index: 2, frame: CGRect(x: leftW + spacing, y: rightH + spacing, width: rightW, height: rightH)),
        ]
        return (rects, CGSize(width: w, height: h))
    }

    // MARK: - Row layout

    /// Lays the items out into the given rows: row height comes from the sum of the aspects,
    /// tile widths are proportional to them, and the last tile is stretched to the right edge.
    private static func rowsLayout(rows: [[Int]], aspects: [CGFloat], width w: CGFloat,
                                   spacing: CGFloat) -> (rects: [MosaicRect], size: CGSize) {
        var rects: [MosaicRect] = []
        var y: CGFloat = 0
        for row in rows {
            let availW = w - spacing * CGFloat(row.count - 1)
            let sumA = row.reduce(CGFloat(0)) { $0 + aspects[$1] }
            let h = clamp(availW / sumA, w * 0.2, w * 0.68)
            var x: CGFloat = 0
            for (i, idx) in row.enumerated() {
                let tileW = i == row.count - 1 ? w - x : (availW * aspects[idx] / sumA).rounded()
                rects.append(MosaicRect(index: idx, frame: CGRect(x: x, y: y, width: tileW, height: h)))
                x += tileW + spacing
            }
            y += h + spacing
        }
        return (rects, CGSize(width: w, height: y - spacing))
    }

    /// 5 to 10 items: enumerate the splits into rows of two or three tiles and take the one
    /// with the smallest penalty for distorted aspects and for rows away from the ideal height.
    private static func bestRows(aspects: [CGFloat], width w: CGFloat,
                                 spacing: CGFloat) -> (rects: [MosaicRect], size: CGSize) {
        var best: [[Int]] = []
        var bestPenalty = CGFloat.greatestFiniteMagnitude
        for counts in compositions(aspects.count) {
            var rows: [[Int]] = []
            var start = 0
            for c in counts {
                rows.append(Array(start..<(start + c)))
                start += c
            }
            var penalty: CGFloat = 0
            for row in rows {
                let availW = w - spacing * CGFloat(row.count - 1)
                let sumA = row.reduce(CGFloat(0)) { $0 + aspects[$1] }
                let naturalH = availW / sumA
                let h = clamp(naturalH, w * 0.2, w * 0.68)
                // Distortion of every tile in the row, plus the row's distance from the ideal height.
                penalty += CGFloat(row.count) * abs(log(naturalH / h))
                penalty += abs(log(h / (w * idealRowFactor)))
            }
            if penalty < bestPenalty {
                bestPenalty = penalty
                best = rows
            }
        }
        return rowsLayout(rows: best, aspects: aspects, width: w, spacing: spacing)
    }

    /// Every way to write n as an ordered sum of 2s and 3s.
    private static func compositions(_ n: Int) -> [[Int]] {
        if n == 0 { return [[]] }
        var result: [[Int]] = []
        for part in [2, 3] where part <= n {
            for rest in compositions(n - part) {
                result.append([part] + rest)
            }
        }
        return result
    }

    // MARK: - Capping the overall height

    /// Content taller than maxHeight is squeezed vertically by a single factor.
    private static func capHeight(_ layout: (rects: [MosaicRect], size: CGSize),
                                  maxHeight: CGFloat) -> (rects: [MosaicRect], size: CGSize) {
        guard layout.size.height > maxHeight else { return layout }
        let f = maxHeight / layout.size.height
        let rects = layout.rects.map {
            MosaicRect(index: $0.index,
                       frame: CGRect(x: $0.frame.minX, y: $0.frame.minY * f,
                                     width: $0.frame.width, height: $0.frame.height * f))
        }
        return (rects, CGSize(width: layout.size.width, height: maxHeight))
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        min(max(v, lo), hi)
    }
}
