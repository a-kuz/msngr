import SwiftUI
import UIKit
import AVFoundation

/// What a finger does on the canvas.
enum StoryCanvasMode: Equatable {
    /// Layers move, pinch and turn; the picture pans and zooms under an empty touch.
    case arrange
    /// Every drag is a stroke.
    case draw(brush: StoryStroke.Brush, color: String, width: CGFloat)
}

/// The story canvas: the picture or the looping clip, the strokes and the
/// layers, with the gestures that arrange them. While a finger is down the
/// canvas is the only thing that moves — the view's own layers take the
/// transform and nothing is re-rendered — and the frame goes back to SwiftUI
/// once, when the gesture ends.
struct StoryCanvasView: UIViewRepresentable {
    var frame: StoryFrame
    var mode: StoryCanvasMode
    /// The layer under the text tool stays off the canvas while it is typed.
    var hiddenLayer: UUID?
    var paused: Bool
    /// The frame is about to change under a gesture: the caller keeps the old one.
    var onBegin: () -> Void
    var onCommit: (StoryFrame) -> Void
    var onTapLayer: (UUID) -> Void
    var onTapEmpty: (CGPoint) -> Void
    /// A layer is being dragged; the second flag says whether it is over the bin.
    var onDragging: (Bool, Bool) -> Void

    func makeUIView(context: Context) -> StoryCanvas {
        let view = StoryCanvas()
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: StoryCanvas, context: Context) {
        context.coordinator.parent = self
        view.apply(frame, mode: mode, hiddenLayer: hiddenLayer, paused: paused)
    }

    static func dismantleUIView(_ view: StoryCanvas, coordinator: Coordinator) {
        view.stopPlayback()
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: StoryCanvasDelegate {
        var parent: StoryCanvasView
        init(parent: StoryCanvasView) { self.parent = parent }
        func canvasWillChange() { parent.onBegin() }
        func canvas(didCommit frame: StoryFrame) { parent.onCommit(frame) }
        func canvas(didTapLayer id: UUID) { parent.onTapLayer(id) }
        func canvas(didTapEmptyAt point: CGPoint) { parent.onTapEmpty(point) }
        func canvas(isDragging: Bool, overBin: Bool) { parent.onDragging(isDragging, overBin) }
    }
}

protocol StoryCanvasDelegate: AnyObject {
    func canvasWillChange()
    func canvas(didCommit frame: StoryFrame)
    func canvas(didTapLayer id: UUID)
    func canvas(didTapEmptyAt point: CGPoint)
    func canvas(isDragging: Bool, overBin: Bool)
}

final class StoryCanvas: UIView, UIGestureRecognizerDelegate {
    weak var delegate: StoryCanvasDelegate?

    /// Where a dragged layer is let go to be thrown away, in the canvas's own
    /// points from its bottom edge.
    static let binRadius: CGFloat = 44
    static let binBottomInset: CGFloat = 96

    private(set) var model: StoryFrame?
    private var mode: StoryCanvasMode = .arrange
    private var hiddenLayer: UUID?

    private let backdrop = UIImageView()
    private let picture = UIImageView()
    private let playerView = LoopingPlayerView()
    private let strokesHost = CALayer()
    private var strokeLayers: [UUID: [CAShapeLayer]] = [:]
    private var liveStroke: (stroke: StoryStroke, layers: [CAShapeLayer])?
    private var layerViews: [UUID: LayerView] = [:]
    private let dim = UIView()

    /// The gesture in flight: what it moves and where it started.
    private enum Target { case layer(UUID), picture }
    private var target: Target?
    private var gestureStartFrame: StoryFrame?
    private var liveLayerScale: CGFloat = 1
    private var liveLayerRotation: CGFloat = 0
    private var overBin = false
    private var activeGestures = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        backdrop.contentMode = .scaleAspectFill
        backdrop.alpha = 0.75
        addSubview(backdrop)
        dim.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        addSubview(dim)
        picture.contentMode = .scaleToFill
        addSubview(picture)
        playerView.isHidden = true
        addSubview(playerView)
        layer.addSublayer(strokesHost)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
        pan.maximumNumberOfTouches = 2
        pan.delegate = self
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch))
        pinch.delegate = self
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate))
        rotate.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap))
        doubleTap.numberOfTapsRequired = 2
        tap.require(toFail: doubleTap)
        for g in [pan, pinch, rotate, tap, doubleTap] { addGestureRecognizer(g) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        backdrop.frame = bounds
        dim.frame = bounds
        playerView.frame = bounds
        strokesHost.frame = bounds
        guard let model else { return }
        picture.frame = StoryRenderer.imageRect(model, in: bounds.size)
        for stroke in model.strokes { layoutStroke(stroke) }
        for layer in model.layers { place(layer) }
    }

    // MARK: - Applying the frame

    func apply(_ frame: StoryFrame, mode: StoryCanvasMode, hiddenLayer: UUID?, paused: Bool) {
        self.mode = mode
        self.hiddenLayer = hiddenLayer
        let previous = model
        model = frame
        if activeGestures > 0 {
            // the canvas is ahead of the model while a finger is down
            return
        }
        if previous?.id != frame.id || previous?.image !== frame.image {
            picture.image = frame.image
            let fills = frame.isVideo
            backdrop.isHidden = fills
            dim.isHidden = fills
            backdrop.image = fills ? nil : StoryRenderer.backdrop(frame.image, size: bounds.size)
            if frame.isVideo, let url = frame.videoURL {
                playerView.isHidden = false
                picture.isHidden = true
                playerView.play(url: url)
            } else {
                playerView.isHidden = true
                picture.isHidden = false
                playerView.stop()
            }
        }
        playerView.isMuted = frame.muted
        playerView.paused = paused
        let visible = bounds.width > 0
        if visible {
            picture.frame = StoryRenderer.imageRect(frame, in: bounds.size)
        }
        syncStrokes(frame.strokes)
        syncLayers(frame.layers)
    }

    func stopPlayback() { playerView.stop() }

    private func syncStrokes(_ strokes: [StoryStroke]) {
        let ids = Set(strokes.map(\.id))
        for (id, layers) in strokeLayers where !ids.contains(id) {
            layers.forEach { $0.removeFromSuperlayer() }
            strokeLayers[id] = nil
        }
        for stroke in strokes where strokeLayers[stroke.id] == nil {
            let layers = StoryRenderer.passes(for: stroke).map { pass -> CAShapeLayer in
                let shape = CAShapeLayer()
                shape.fillColor = nil
                shape.lineCap = .round
                shape.lineJoin = .round
                shape.strokeColor = pass.color.cgColor
                strokesHost.addSublayer(shape)
                return shape
            }
            strokeLayers[stroke.id] = layers
            layoutStroke(stroke)
        }
        // strokes stay in drawing order under everything typed
        for stroke in strokes {
            strokeLayers[stroke.id]?.forEach { strokesHost.addSublayer($0) }
        }
    }

    private func layoutStroke(_ stroke: StoryStroke) {
        guard let layers = strokeLayers[stroke.id], bounds.width > 0 else { return }
        let path = StoryRenderer.path(for: stroke, in: bounds.size).cgPath
        for (shape, pass) in zip(layers, StoryRenderer.passes(for: stroke)) {
            shape.path = path
            shape.lineWidth = stroke.width * bounds.width * pass.widthFactor
        }
    }

    private func syncLayers(_ layers: [StoryLayer]) {
        let ids = Set(layers.map(\.id))
        for (id, view) in layerViews where !ids.contains(id) {
            view.removeFromSuperview()
            layerViews[id] = nil
        }
        for layer in layers {
            let view = layerViews[layer.id] ?? {
                let v = LayerView()
                addSubview(v)
                layerViews[layer.id] = v
                return v
            }()
            view.isHidden = layer.id == hiddenLayer
            if view.rendered != layer.appearance || view.renderedWidth != bounds.width {
                view.image = StoryRenderer.image(for: layer, canvasWidth: max(bounds.width, 1))
                view.rendered = layer.appearance
                view.renderedWidth = bounds.width
            }
            bringSubviewToFront(view)
            place(layer)
        }
    }

    private func place(_ layer: StoryLayer) {
        guard let view = layerViews[layer.id], let image = view.image else { return }
        view.bounds = CGRect(origin: .zero, size: image.size)
        view.center = CGPoint(x: layer.center.x * bounds.width, y: layer.center.y * bounds.height)
        view.transform = CGAffineTransform(rotationAngle: layer.rotation)
    }

    // MARK: - Gestures

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(g is UITapGestureRecognizer) && !(other is UITapGestureRecognizer)
    }

    private func layerView(at point: CGPoint) -> UUID? {
        // the topmost layer wins, with a little air around it for a finger
        for (id, view) in layerViews.sorted(by: { subviews.firstIndex(of: $0.value) ?? 0 > subviews.firstIndex(of: $1.value) ?? 0 })
        where !view.isHidden {
            let local = view.convert(point, from: self)
            if view.bounds.insetBy(dx: -14, dy: -14).contains(local) { return id }
        }
        return nil
    }

    /// Every recognizer that begins is counted, and the frame goes back to the
    /// model only when the last of them has ended.
    private func beginGesture(at point: CGPoint) {
        activeGestures += 1
        guard activeGestures == 1, let model else { return }
        gestureStartFrame = model
        liveLayerScale = 1
        liveLayerRotation = 0
        if case .draw = mode {
            target = nil
            return
        }
        if let id = layerView(at: point) {
            target = .layer(id)
        } else if !model.isVideo {
            target = .picture
        } else {
            target = nil
        }
        delegate?.canvasWillChange()
    }

    private func endGesture() {
        activeGestures = max(0, activeGestures - 1)
        guard activeGestures == 0 else { return }
        if case .layer(let id) = target, var model {
            if let i = model.layers.firstIndex(where: { $0.id == id }) {
                if overBin {
                    model.layers.remove(at: i)
                    Haptics.rigid()
                } else {
                    model.layers[i].scale = min(max(model.layers[i].scale * liveLayerScale, 0.3), 6)
                    model.layers[i].rotation += liveLayerRotation
                }
            }
            self.model = model
            overBin = false
            delegate?.canvas(isDragging: false, overBin: false)
        }
        target = nil
        if let model, let start = gestureStartFrame, model != start {
            delegate?.canvas(didCommit: model)
        }
        gestureStartFrame = nil
        syncLayers(model?.layers ?? [])
    }

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let point = g.location(in: self)
        switch g.state {
        case .began:
            beginGesture(at: point)
            if case .draw(let brush, let color, let width) = mode {
                startStroke(brush: brush, color: color, width: width, at: point)
            } else if case .layer = target {
                delegate?.canvas(isDragging: true, overBin: false)
            }
        case .changed:
            if liveStroke != nil {
                extendStroke(to: point)
                return
            }
            let delta = g.translation(in: self)
            g.setTranslation(.zero, in: self)
            guard bounds.width > 0, var model else { return }
            switch target {
            case .layer(let id):
                guard let i = model.layers.firstIndex(where: { $0.id == id }), let view = layerViews[id] else { return }
                model.layers[i].center.x += delta.x / bounds.width
                model.layers[i].center.y += delta.y / bounds.height
                view.center = CGPoint(x: view.center.x + delta.x, y: view.center.y + delta.y)
                self.model = model
                let bin = CGPoint(x: bounds.midX, y: bounds.height - Self.binBottomInset)
                let near = hypot(point.x - bin.x, point.y - bin.y) < Self.binRadius * 1.4
                if near != overBin {
                    overBin = near
                    Haptics.light()
                    delegate?.canvas(isDragging: true, overBin: near)
                }
                UIView.animate(withDuration: 0.15) {
                    view.alpha = near ? 0.4 : 1
                }
            case .picture:
                model.pan.x += delta.x / bounds.width
                model.pan.y += delta.y / bounds.height
                self.model = model
                picture.frame = StoryRenderer.imageRect(model, in: bounds.size)
            case nil:
                break
            }
        case .ended, .cancelled, .failed:
            if liveStroke != nil {
                finishStroke()
                activeGestures = max(0, activeGestures - 1)
                gestureStartFrame = nil
                return
            }
            if case .layer(let id) = target { layerViews[id]?.alpha = 1 }
            endGesture()
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        if case .draw = mode { return }
        switch g.state {
        case .began:
            beginGesture(at: g.location(in: self))
        case .changed:
            guard var model else { return }
            switch target {
            case .layer(let id):
                guard let i = model.layers.firstIndex(where: { $0.id == id }), let view = layerViews[id] else { return }
                let limit = min(max(model.layers[i].scale * g.scale, 0.3), 6) / model.layers[i].scale
                liveLayerScale = limit
                view.transform = CGAffineTransform(rotationAngle: model.layers[i].rotation + liveLayerRotation)
                    .scaledBy(x: limit, y: limit)
            case .picture:
                model.zoom = min(max(model.zoom * g.scale, 1), 4)
                g.scale = 1
                self.model = model
                picture.frame = StoryRenderer.imageRect(model, in: bounds.size)
            case nil:
                break
            }
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handleRotate(_ g: UIRotationGestureRecognizer) {
        if case .draw = mode { return }
        switch g.state {
        case .began:
            beginGesture(at: g.location(in: self))
        case .changed:
            guard let model, case .layer(let id) = target,
                  let i = model.layers.firstIndex(where: { $0.id == id }), let view = layerViews[id] else { return }
            liveLayerRotation = g.rotation
            view.transform = CGAffineTransform(rotationAngle: model.layers[i].rotation + liveLayerRotation)
                .scaledBy(x: liveLayerScale, y: liveLayerScale)
        case .ended, .cancelled, .failed:
            endGesture()
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let point = g.location(in: self)
        if let id = layerView(at: point) {
            delegate?.canvas(didTapLayer: id)
        } else if bounds.width > 0 {
            delegate?.canvas(didTapEmptyAt: CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
        }
    }

    /// A double tap puts a zoomed picture back the way it was fitted.
    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard var model, !model.isVideo, layerView(at: g.location(in: self)) == nil,
              model.zoom != 1 || model.pan != .zero else { return }
        delegate?.canvasWillChange()
        model.zoom = 1
        model.pan = .zero
        self.model = model
        UIView.animate(withDuration: 0.25) {
            self.picture.frame = StoryRenderer.imageRect(model, in: self.bounds.size)
        }
        delegate?.canvas(didCommit: model)
    }

    // MARK: - Drawing

    private func startStroke(brush: StoryStroke.Brush, color: String, width: CGFloat, at point: CGPoint) {
        guard bounds.width > 0 else { return }
        let stroke = StoryStroke(brush: brush, color: color, width: width,
                                 points: [CGPoint(x: point.x / bounds.width, y: point.y / bounds.height)])
        let layers = StoryRenderer.passes(for: stroke).map { pass -> CAShapeLayer in
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.strokeColor = pass.color.cgColor
            shape.lineWidth = stroke.width * bounds.width * pass.widthFactor
            strokesHost.addSublayer(shape)
            return shape
        }
        liveStroke = (stroke, layers)
        delegate?.canvasWillChange()
        extendStroke(to: point)
    }

    private func extendStroke(to point: CGPoint) {
        guard var live = liveStroke, bounds.width > 0 else { return }
        live.stroke.points.append(CGPoint(x: point.x / bounds.width, y: point.y / bounds.height))
        let path = StoryRenderer.path(for: live.stroke, in: bounds.size).cgPath
        // the path is set without an implicit animation, or every point lags
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in live.layers { shape.path = path }
        CATransaction.commit()
        liveStroke = live
    }

    private func finishStroke() {
        guard let live = liveStroke, var model else { return }
        liveStroke = nil
        model.strokes.append(live.stroke)
        strokeLayers[live.stroke.id] = live.layers
        self.model = model
        delegate?.canvas(didCommit: model)
    }
}

/// A layer's picture on the canvas; remembers what it was drawn from so an
/// unchanged layer is never drawn twice.
private final class LayerView: UIImageView {
    var rendered: StoryLayer.Appearance?
    var renderedWidth: CGFloat = 0

    init() {
        super.init(frame: .zero)
        contentMode = .center
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// The clip playing in a loop under the tools, filling the canvas.
private final class LoopingPlayerView: UIView {
    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }
    var paused = false {
        didSet { if paused { player.pause() } else if player.rate == 0, looper != nil { player.play() } }
    }

    override class var layerClass: AnyClass { AVPlayerLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let layer = layer as! AVPlayerLayer
        layer.player = player
        layer.videoGravity = .resizeAspectFill
    }

    required init?(coder: NSCoder) { fatalError() }

    func play(url: URL) {
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        if !paused { player.play() }
    }

    func stop() {
        player.pause()
        looper = nil
        player.removeAllItems()
    }
}
