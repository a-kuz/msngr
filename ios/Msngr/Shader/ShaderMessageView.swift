import UIKit
import MetalKit
import MsngrCore

/// A live `MTKView` driven by a `ShaderRenderer`, with the touches of the view
/// fed to the shader as `iMouse`. Shared by the bubble, the player, the
/// composer preview, the chat background, stickers and avatars.
///
/// `setRunning` is the owner's wish; whether the canvas animates is decided by
/// `ShaderBudget`, which hands out the live slots and tells the rest to hold a
/// frame.
final class ShaderCanvas: UIView {
    /// Who gives way when the budget is short: an avatar before a message, a
    /// message before the background, and the shader the user opened last.
    enum Priority: Int { case avatar, feed, background, focus }

    let metalView = MTKView()
    private(set) var renderer: ShaderRenderer?
    private var observer: UUID?
    private var program: ShaderProgram?
    /// Whether touches reach the shader; off for a shader message in the feed,
    /// where they scroll, on for a sticker, the player and the composer.
    var acceptsTouches = false
    /// Whether the canvas also takes the keyboard (the keyboard feed). Off in
    /// the feed: becoming first responder there would dismiss the composer.
    var acceptsKeys = true
    /// Whether the shader may read the device (sensors, location, microphone,
    /// cameras, keyboard). On for the user's own documents: the pack, the
    /// surfaces, the composer and the player they opened. Off for a peer's
    /// document in the feed, which is what the renderer defaults to.
    var deviceInputs = false
    var priority: Priority = .feed
    var onState: ((ShaderProgram.State) -> Void)?
    /// The owner asked for frames; the budget decides whether they come.
    private(set) var wantsLive = false
    private(set) var isLive = false
    /// A held canvas has drawn the one frame it shows.
    private var heldFrameDrawn = false

    /// `transparent` keeps the drawable's alpha, so a sticker or an effect
    /// shows what is under it where the shader writes `O.a < 1`.
    init(transparent: Bool = false) {
        super.init(frame: .zero)
        metalView.device = ShaderGPU.shared.device
        metalView.colorPixelFormat = ShaderRenderer.imageFormat
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.autoResizeDrawable = false
        metalView.backgroundColor = .clear
        metalView.isOpaque = !transparent
        metalView.layer.isOpaque = !transparent
        metalView.isUserInteractionEnabled = false
        isOpaque = !transparent
        isMultipleTouchEnabled = true
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Metal refuses a texture over 8192 px a side, with an assertion that
    /// takes the process down. A cell mid-layout can hand the canvas a frame
    /// thousands of points tall for a frame, so the drawable is sized here,
    /// never past the ceiling, and a degenerate frame draws nothing.
    static let maxDrawableSide: CGFloat = 8192
    /// A lower ceiling for a canvas whose picture is a backdrop: the shader
    /// behind a long text does not need a texel per pixel down its whole height.
    var drawableCeiling: CGFloat = ShaderCanvas.maxDrawableSide

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        let scale = metalView.contentScaleFactor
        let ceiling = min(drawableCeiling, Self.maxDrawableSide)
        var w = max(bounds.width * scale, 0), h = max(bounds.height * scale, 0)
        // over the ceiling the drawable keeps its aspect and the layer stretches it
        let over = max(w, h) / ceiling
        if over > 1 { w /= over; h /= over }
        let size = CGSize(width: floor(w), height: floor(h))
        if metalView.drawableSize != size { metalView.drawableSize = size }
        // a canvas denied a slot before it had a size draws its held frame now
        if wantsLive, !isLive { holdFrame() }
    }

    /// Rendering happens at the view's own scale: a phone draws every pixel.
    var isRunning: Bool { !metalView.isPaused }

    func show(_ document: ShaderDocument) {
        if program?.document == document, renderer?.deviceInputs == deviceInputs { return }
        if let observer, let program { program.unobserve(observer) }
        let p = ShaderProgram.program(for: document)
        program = p
        let r = ShaderRenderer(program: p, deviceInputs: deviceInputs)
        r.host = self
        renderer = r
        heldFrameDrawn = false
        metalView.delegate = r
        observer = p.observe { [weak self] state in
            guard let self else { return }
            self.onState?(state)
            switch state {
            case .failed: self.setRunning(false)
            case .ready: if self.wantsLive, !self.isLive { self.holdFrame() }
            case .compiling: break
            }
        }
    }

    func clear() {
        setRunning(false)
        if let observer, let program { program.unobserve(observer) }
        observer = nil
        program = nil
        renderer = nil
        metalView.delegate = nil
        metalView.isPaused = true
    }

    func setRunning(_ running: Bool) {
        if running, let program, case .failed = program.state { return }
        wantsLive = running
        if running {
            ShaderBudget.shared.request(self)
        } else {
            ShaderBudget.shared.release(self)
            applyBudget(live: false)
        }
    }

    /// The budget's verdict: animate, or stop and show one frame.
    func applyBudget(live: Bool) {
        let run = live && wantsLive
        if run != isLive || run != !metalView.isPaused {
            isLive = run
            // a canvas coming back from live holds a fresh frame next time
            if run { heldFrameDrawn = false }
            renderer?.setPaused(!run)
            metalView.isPaused = !run
        }
        if !run, wantsLive { holdFrame() }
    }

    /// One frame for a canvas that wants to run but has no slot: the shader
    /// is seen standing still instead of as a black rectangle.
    private func holdFrame() {
        guard !heldFrameDrawn, let renderer, case .ready = program?.state ?? .compiling,
              bounds.width > 0, bounds.height > 0 else { return }
        heldFrameDrawn = true
        renderer.setPaused(false)
        metalView.draw()
        renderer.setPaused(true)
    }

    deinit {
        if let observer, let program { program.unobserve(observer) }
    }

    // MARK: touches → iMouse, iTouch, iPencil; keys → the keyboard texture

    override var canBecomeFirstResponder: Bool { acceptsTouches && acceptsKeys }

    /// Every finger down on the canvas right now.
    private var fingers: [UITouch] = []
    private lazy var hover: UIHoverGestureRecognizer = {
        let h = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        return h
    }()

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // off the window a canvas gives its slot back; on it again, it asks anew
        if wantsLive {
            if window == nil {
                ShaderBudget.shared.release(self)
                applyBudget(live: false)
            } else {
                ShaderBudget.shared.request(self)
            }
        }
        if window != nil, acceptsTouches {
            if hover.view == nil { addGestureRecognizer(hover) }
            if acceptsKeys { becomeFirstResponder() }
        }
    }

    private func feedTouches() {
        let scale = metalView.contentScaleFactor
        let list = fingers.filter { $0.phase != .ended && $0.phase != .cancelled }.map {
            (id: ObjectIdentifier($0), point: $0.location(in: self),
             force: Float($0.maximumPossibleForce > 0 ? $0.force / $0.maximumPossibleForce : 1))
        }
        renderer?.touches(list, in: bounds.size, scale: scale)
        if let p = fingers.first(where: { $0.type == .pencil && $0.phase != .ended && $0.phase != .cancelled }) {
            renderer?.pencil(p.location(in: self), force: Float(p.maximumPossibleForce > 0 ? p.force / p.maximumPossibleForce : 0),
                             altitude: Float(p.altitudeAngle), azimuth: Float(p.azimuthAngle(in: self)),
                             in: bounds.size, scale: scale)
        } else {
            renderer?.pencil(nil, force: 0, altitude: 0, azimuth: 0, in: bounds.size, scale: scale)
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesBegan(touches, with: event) }
        for t in touches where !fingers.contains(t) { fingers.append(t) }
        if let t = fingers.first {
            renderer?.touch(t.location(in: self), in: bounds.size, scale: metalView.contentScaleFactor, began: touches.contains(t))
        }
        feedTouches()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesMoved(touches, with: event) }
        if let t = fingers.first {
            renderer?.touch(t.location(in: self), in: bounds.size, scale: metalView.contentScaleFactor, began: false)
        }
        feedTouches()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesEnded(touches, with: event) }
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesCancelled(touches, with: event) }
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        let liftedFirst = fingers.first.map(touches.contains) ?? false
        fingers.removeAll(where: touches.contains)
        if liftedFirst || fingers.isEmpty {
            renderer?.touch(nil, in: bounds.size, scale: metalView.contentScaleFactor, began: false)
        }
        feedTouches()
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        let scale = metalView.contentScaleFactor
        switch g.state {
        case .began, .changed:
            renderer?.pencilHover(g.location(in: self), zOffset: Float(g.zOffset), in: bounds.size, scale: scale)
        default:
            renderer?.pencilHover(nil, zOffset: -1, in: bounds.size, scale: scale)
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsTouches else { return super.pressesBegan(presses, with: event) }
        for p in presses { DeviceInputs.shared.keyboard.keyDown(p) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsTouches else { return super.pressesEnded(presses, with: event) }
        for p in presses { DeviceInputs.shared.keyboard.keyUp(p) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard acceptsTouches else { return super.pressesCancelled(presses, with: event) }
        for p in presses { DeviceInputs.shared.keyboard.keyUp(p) }
    }
}

/// The shader inside a bubble: the canvas, and over it the state while the
/// program compiles or once it has failed. Runs only while its cell is on
/// screen; the collection view drives that through `setActive`.
final class ShaderMessageView: UIView {
    private let canvas: ShaderCanvas
    private let stateLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let nameLabel = UILabel()
    private var active = false
    private var failed = false

    /// A transparent view is a sticker: no black behind the shader, and the
    /// state label reads over the chat instead of over black.
    init(transparent: Bool = false) {
        canvas = ShaderCanvas(transparent: transparent)
        // a sticker reacts to the finger; a shader message opens on a tap instead
        canvas.acceptsTouches = transparent
        canvas.acceptsKeys = false
        super.init(frame: .zero)
        clipsToBounds = true
        layer.cornerRadius = transparent ? 0 : Theme.bubbleCorner
        layer.cornerCurve = .continuous
        backgroundColor = transparent ? .clear : .black
        addSubview(canvas)

        stateLabel.textAlignment = .center
        stateLabel.textColor = transparent ? .secondaryLabel : .white.withAlphaComponent(0.85)
        stateLabel.numberOfLines = 2
        stateLabel.isHidden = true
        addSubview(stateLabel)

        spinner.color = .white.withAlphaComponent(0.7)
        spinner.hidesWhenStopped = true
        addSubview(spinner)

        nameLabel.textColor = .white
        nameLabel.layer.shadowColor = UIColor.black.cgColor
        nameLabel.layer.shadowOpacity = 0.8
        nameLabel.layer.shadowRadius = 3
        nameLabel.layer.shadowOffset = .zero
        addSubview(nameLabel)

        canvas.onState = { [weak self] state in self?.apply(state) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        canvas.frame = bounds
        stateLabel.frame = bounds.insetBy(dx: 12, dy: 0)
        spinner.center = CGPoint(x: bounds.midX, y: bounds.midY)
        nameLabel.frame = CGRect(x: 10, y: 8, width: bounds.width - 20, height: 18)
    }

    /// `deviceInputs` opens the sensors to the shader; the feed passes it for
    /// a sticker of the user's own pack and leaves it off for a peer's document.
    func configure(document: ShaderDocument, deviceInputs: Bool = false) {
        stateLabel.font = Theme.Text.feedNote.uiFont
        nameLabel.font = Theme.Text.thumbnailCaption.uiFont
        nameLabel.text = document.name
        nameLabel.isHidden = document.name == nil
        canvas.deviceInputs = deviceInputs
        canvas.show(document)
        canvas.setRunning(active)
    }

    /// Off-screen cells stop drawing; the feed calls this from
    /// willDisplay / didEndDisplaying and prepareForReuse.
    func setActive(_ on: Bool) {
        active = on
        canvas.setRunning(on && !failed)
    }

    private func apply(_ state: ShaderProgram.State) {
        switch state {
        case .compiling:
            failed = false
            spinner.startAnimating()
            stateLabel.isHidden = true
        case .ready:
            failed = false
            spinner.stopAnimating()
            stateLabel.isHidden = true
            canvas.setRunning(active)
        case .failed:
            failed = true
            spinner.stopAnimating()
            stateLabel.text = String(localized: "Could not be shown")
            stateLabel.isHidden = false
            canvas.setRunning(false)
        }
    }
}
