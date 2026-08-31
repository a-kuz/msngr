import UIKit

/// The drawing surface: shows the document rendered over the picture and turns
/// drags into strokes. The preview bitmap is screen-sized; the full-resolution
/// render happens once, on export.
final class MarkupCanvasView: UIView {
    var tool: MarkupTool = .pen
    var color: UIColor = .white
    /// Stroke width in screen points; recorded into the stroke in image pixels.
    var lineWidth: CGFloat = 4
    /// Fires after every committed step, for the undo/redo buttons.
    var onChange: (() -> Void)?
    /// A tap with the text tool on empty ground: the screen opens the input.
    var onTextTap: ((CGPoint) -> Void)?
    /// A tap on an existing label with the text tool re-opens its input.
    var onTextEdit: ((MarkupStroke) -> Void)?

    private(set) var history = MarkupHistory()
    private let base: UIImage
    private let baseSize: CGSize
    private let preview = UIImageView()
    private let liveLayer = CAShapeLayer()
    private var livePoints: [CGPoint] = []
    /// A pen drag held still at its end straightens into an arrow; from that
    /// moment the finger drags the arrow's tip.
    private var straightened = false
    private var holdTimer: Timer?
    /// The text drag: which label, where the finger took it, and the document
    /// as it stood before — the whole move lands as one undoable step.
    private var draggedText: (id: UUID, grip: CGPoint, before: MarkupDocument)?
    private var renderTask: Task<Void, Never>?

    init(image: UIImage) {
        base = MarkupRenderer.normalized(image)
        baseSize = CGSize(width: base.size.width * base.scale, height: base.size.height * base.scale)
        super.init(frame: .zero)
        isMultipleTouchEnabled = false
        preview.contentMode = .scaleAspectFit
        addSubview(preview)
        liveLayer.fillColor = nil
        liveLayer.lineCap = .round
        liveLayer.lineJoin = .round
        layer.addSublayer(liveLayer)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        preview.frame = bounds
        if bounds.width > 0 { refresh() }
    }

    // MARK: - Document

    var document: MarkupDocument { history.current }

    func push(_ document: MarkupDocument) {
        history.push(document)
        refresh()
        onChange?()
    }

    func undo() {
        history.undo()
        refresh()
        onChange?()
    }

    func redo() {
        history.redo()
        refresh()
        onChange?()
    }

    /// The full-resolution result.
    func export() -> UIImage {
        MarkupRenderer.render(base: base, document: document)
    }

    private func refresh() {
        renderTask?.cancel()
        let doc = document
        let image = base
        let outputSize = doc.outputSize(of: baseSize)
        let pixelLimit = max(bounds.width, 320) * UIScreen.main.scale
        let scale = min(1, pixelLimit / max(outputSize.width, outputSize.height))
        renderTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                MarkupRenderer.render(base: image, document: doc, scale: scale)
            }.value
            guard !Task.isCancelled else { return }
            self?.preview.image = rendered
        }
    }

    // MARK: - Geometry

    /// Where the rendered picture sits inside the view.
    var imageFrame: CGRect {
        let size = document.outputSize(of: baseSize)
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let s = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    /// Screen points to base-image pixels, for widths and font sizes.
    var pixelsPerPoint: CGFloat {
        let size = document.outputSize(of: baseSize)
        return size.width / max(imageFrame.width, 1)
    }

    /// A view point mapped into base-image pixels, through the crop and the rotation.
    private func basePoint(_ p: CGPoint) -> CGPoint {
        let frame = imageFrame
        var point = CGPoint(x: (p.x - frame.minX) * pixelsPerPoint,
                            y: (p.y - frame.minY) * pixelsPerPoint)
        if let crop = document.crop {
            point.x += crop.minX
            point.y += crop.minY
        }
        return document.toBase(point, baseSize: baseSize)
    }

    // MARK: - Touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        straightened = false
        if tool == .text {
            let hit = basePoint(p)
            let slack = 12 * pixelsPerPoint
            if let label = document.strokes.last(where: { $0.tool == .text &&
                MarkupRenderer.textBounds($0).insetBy(dx: -slack, dy: -slack).contains(hit) }) {
                draggedText = (label.id, hit, document)
            }
            return
        }
        livePoints = [p]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        if let drag = draggedText {
            var doc = drag.before
            moveLabel(&doc, drag: drag, to: basePoint(p))
            history.replaceCurrent(doc)
            refresh()
            return
        }
        guard !livePoints.isEmpty else { return }
        if straightened {
            livePoints = [livePoints[0], p]
        } else {
            livePoints.append(p)
            if tool == .pen { armHoldTimer() }
        }
        drawLive()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if draggedText == nil, !straightened, let p = touches.first?.location(in: self),
           !livePoints.isEmpty {
            livePoints.append(p)
        }
        finish(cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(cancelled: true)
    }

    private func finish(cancelled: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil
        liveLayer.path = nil
        if let drag = draggedText {
            draggedText = nil
            if cancelled {
                history.replaceCurrent(drag.before)
                refresh()
            } else {
                let moved = document
                history.replaceCurrent(drag.before)
                if moved.strokes.first(where: { $0.id == drag.id })?.points
                    != drag.before.strokes.first(where: { $0.id == drag.id })?.points {
                    push(moved)
                } else {
                    refresh()
                }
            }
            return
        }
        let points = livePoints
        let wasStraightened = straightened
        livePoints = []
        straightened = false
        guard !cancelled, !points.isEmpty, tool != .text else { return }
        let effectiveTool: MarkupTool = wasStraightened ? .arrow : tool
        if points.count < 2 && effectiveTool != .pen { return }
        var doc = document
        let recorded = effectiveTool == .pen ? points.map(basePoint)
                                             : [basePoint(points.first!), basePoint(points.last!)]
        doc.strokes.append(MarkupStroke(tool: effectiveTool, color: color,
                                        width: lineWidth * pixelsPerPoint, points: recorded))
        push(doc)
    }

    private func moveLabel(_ doc: inout MarkupDocument, drag: (id: UUID, grip: CGPoint, before: MarkupDocument),
                           to point: CGPoint) {
        guard let i = doc.strokes.firstIndex(where: { $0.id == drag.id }),
              let anchor = drag.before.strokes.first(where: { $0.id == drag.id })?.points.first else { return }
        doc.strokes[i].points = [CGPoint(x: anchor.x + point.x - drag.grip.x,
                                         y: anchor.y + point.y - drag.grip.y)]
    }

    // MARK: - The straightening gesture

    /// A pen drag that looks like a line and holds still at its end becomes an
    /// arrow, and the finger keeps dragging the arrow's tip.
    private func armHoldTimer() {
        holdTimer?.invalidate()
        holdTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            guard let self, !self.livePoints.isEmpty, !self.straightened else { return }
            guard Self.isStraight(self.livePoints) else { return }
            self.straightened = true
            self.livePoints = [self.livePoints[0], self.livePoints[self.livePoints.count - 1]]
            Haptics.light()
            self.drawLive()
        }
    }

    /// A path is straight when no point strays far from the chord and the
    /// chord is long enough to mean a line rather than a scribble.
    static func isStraight(_ points: [CGPoint]) -> Bool {
        guard let a = points.first, let b = points.last else { return false }
        let chord = hypot(b.x - a.x, b.y - a.y)
        guard chord > 40 else { return false }
        let tolerance = max(10, chord * 0.07)
        for p in points {
            // distance from p to the a—b line
            let cross = abs((b.x - a.x) * (a.y - p.y) - (a.x - p.x) * (b.y - a.y))
            if cross / chord > tolerance { return false }
        }
        return true
    }

    // MARK: - Live stroke

    private func drawLive() {
        let asArrow = straightened || tool == .arrow
        liveLayer.strokeColor = tool == .blur ? UIColor.white.withAlphaComponent(0.8).cgColor : color.cgColor
        liveLayer.lineWidth = tool == .blur ? 1.5 : lineWidth
        liveLayer.lineDashPattern = tool == .blur ? [6, 4] : nil
        guard let first = livePoints.first, let last = livePoints.last else { return }
        let path = UIBezierPath()
        if asArrow {
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(lineWidth * 4, 18)
            for side: CGFloat in [.pi * 5 / 6, -.pi * 5 / 6] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x + head * cos(angle + side),
                                         y: last.y + head * sin(angle + side)))
            }
        } else {
            switch tool {
            case .pen:
                path.move(to: first)
                for p in livePoints.dropFirst() { path.addLine(to: p) }
            case .line:
                path.move(to: first)
                path.addLine(to: last)
            case .rect, .blur:
                path.append(UIBezierPath(rect: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                                      width: abs(last.x - first.x),
                                                      height: abs(last.y - first.y))))
            case .ellipse:
                path.append(UIBezierPath(ovalIn: CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                                                        width: abs(last.x - first.x),
                                                        height: abs(last.y - first.y))))
            case .arrow, .text:
                break
            }
        }
        liveLayer.path = path.cgPath
    }

    // MARK: - Text entry from the screen

    /// The text tool's tap: an existing label re-opens its input, empty ground
    /// starts a new one.
    @objc func handleTextTap(_ g: UITapGestureRecognizer) {
        guard tool == .text else { return }
        let p = g.location(in: self)
        let hit = basePoint(p)
        let slack = 12 * pixelsPerPoint
        if let label = document.strokes.last(where: { $0.tool == .text &&
            MarkupRenderer.textBounds($0).insetBy(dx: -slack, dy: -slack).contains(hit) }) {
            onTextEdit?(label)
        } else if imageFrame.contains(p) {
            onTextTap?(p)
        }
    }

    /// Adds a label committed by the input overlay. `at` is in view coordinates.
    func addText(_ text: String, at point: CGPoint, fontSize: CGFloat) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var doc = document
        doc.strokes.append(MarkupStroke(tool: .text, color: color, width: 0,
                                        points: [basePoint(point)], text: trimmed,
                                        fontSize: fontSize * pixelsPerPoint))
        push(doc)
    }

    /// Rewrites an existing label's text; emptying it removes the label.
    func updateText(id: UUID, to text: String) {
        var doc = document
        guard let i = doc.strokes.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { doc.strokes.remove(at: i) } else { doc.strokes[i].text = trimmed }
        push(doc)
    }

    // MARK: - Rotation and crop

    func rotateClockwise() {
        var doc = document
        // the crop was cut in the old orientation; a turned picture starts uncut
        doc.crop = nil
        doc.rotationQuarters = (doc.rotationQuarters + 1) % 4
        push(doc)
    }

    /// Cuts to a rectangle given in view coordinates.
    func applyCrop(_ rectInView: CGRect) {
        let frame = imageFrame
        let s = pixelsPerPoint
        var rect = CGRect(x: (rectInView.minX - frame.minX) * s, y: (rectInView.minY - frame.minY) * s,
                          width: rectInView.width * s, height: rectInView.height * s)
        if let crop = document.crop { rect = rect.offsetBy(dx: crop.minX, dy: crop.minY) }
        let bounds = CGRect(origin: .zero, size: document.rotatedSize(of: baseSize))
        rect = rect.intersection(bounds)
        guard rect.width > 8, rect.height > 8 else { return }
        var doc = document
        doc.crop = rect
        push(doc)
    }
}
