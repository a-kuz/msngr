import UIKit

/// The markup tools. Screenshot-level: the point is to point at something,
/// not to edit a photograph.
enum MarkupTool: CaseIterable {
    case pen, arrow, line, rect, ellipse, blur, text
}

/// One drawn step. Geometry lives in the base image's pixel space (the picture
/// as it was opened, orientation already normalized), so rotation and crop
/// never have to rewrite what was drawn.
struct MarkupStroke: Identifiable {
    let id = UUID()
    var tool: MarkupTool
    var color: UIColor
    /// Line width in base-image pixels.
    var width: CGFloat
    /// The pen keeps every point of the drag; a shape keeps [start, end];
    /// text keeps [anchor] — the top-left corner of the label.
    var points: [CGPoint]
    var text: String = ""
    /// Text height in base-image pixels.
    var fontSize: CGFloat = 0
}

/// The whole edit: what was drawn, and how the picture is turned and cut.
/// The crop rectangle lives in the rotated picture's pixel space.
struct MarkupDocument {
    var strokes: [MarkupStroke] = []
    /// Clockwise quarter turns, 0...3.
    var rotationQuarters: Int = 0
    var crop: CGRect?

    var isEmpty: Bool { strokes.isEmpty && rotationQuarters == 0 && crop == nil }

    /// The picture's size after the rotation, before the crop.
    func rotatedSize(of baseSize: CGSize) -> CGSize {
        rotationQuarters % 2 == 0 ? baseSize : CGSize(width: baseSize.height, height: baseSize.width)
    }

    /// The size of the final picture.
    func outputSize(of baseSize: CGSize) -> CGSize {
        crop?.size ?? rotatedSize(of: baseSize)
    }

    /// A point of the rotated (pre-crop) picture, mapped back into base space.
    func toBase(_ p: CGPoint, baseSize: CGSize) -> CGPoint {
        var point = p
        var size = rotatedSize(of: baseSize)
        // undo the quarter turns one at a time: the inverse of one clockwise
        // turn of a w×h picture takes (u, v) of the h×w result to (v, h − u)
        for _ in 0..<(rotationQuarters % 4) {
            point = CGPoint(x: point.y, y: size.width - point.x)
            size = CGSize(width: size.height, height: size.width)
        }
        return point
    }

    /// A base-space point mapped into the rotated (pre-crop) picture.
    func fromBase(_ p: CGPoint, baseSize: CGSize) -> CGPoint {
        var point = p
        var size = baseSize
        for _ in 0..<(rotationQuarters % 4) {
            point = CGPoint(x: size.height - point.y, y: point.x)
            size = CGSize(width: size.height, height: size.width)
        }
        return point
    }
}

/// Undo and redo over whole-document snapshots: every step — a stroke, a crop,
/// a turn, a moved label — is one entry, and either stack replays it exactly.
struct MarkupHistory {
    private(set) var current = MarkupDocument()
    private var undoStack: [MarkupDocument] = []
    private var redoStack: [MarkupDocument] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func push(_ document: MarkupDocument) {
        undoStack.append(current)
        current = document
        redoStack = []
    }

    mutating func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(current)
        current = previous
    }

    mutating func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(current)
        current = next
    }

    /// The live phase of a gesture rewrites the current snapshot in place;
    /// the step lands in the stacks only when the gesture ends and pushes.
    mutating func replaceCurrent(_ document: MarkupDocument) {
        current = document
    }
}
