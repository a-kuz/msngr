import UIKit
import MetalKit
import MsngrCore

/// A live `MTKView` driven by a `ShaderRenderer`, with the touches of the view
/// fed to the shader as `iMouse`. Shared by the bubble, the player and the
/// composer preview.
final class ShaderCanvas: UIView {
    let metalView = MTKView()
    private(set) var renderer: ShaderRenderer?
    private var observer: UUID?
    private var program: ShaderProgram?
    /// Whether touches reach the shader; off in the feed, where they scroll.
    var acceptsTouches = false
    var onState: ((ShaderProgram.State) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        metalView.device = ShaderGPU.shared.device
        metalView.colorPixelFormat = ShaderRenderer.imageFormat
        metalView.framebufferOnly = false
        metalView.preferredFramesPerSecond = 60
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.backgroundColor = .clear
        metalView.isOpaque = true
        metalView.isUserInteractionEnabled = false
        addSubview(metalView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
    }

    /// Rendering happens at the view's own scale: a phone draws every pixel.
    var isRunning: Bool { !metalView.isPaused }

    func show(_ document: ShaderDocument) {
        if program?.document == document { return }
        if let observer, let program { program.unobserve(observer) }
        let p = ShaderProgram.program(for: document)
        program = p
        let r = ShaderRenderer(program: p)
        renderer = r
        metalView.delegate = r
        observer = p.observe { [weak self] state in
            guard let self else { return }
            self.onState?(state)
            if case .failed = state { self.setRunning(false) }
        }
    }

    func clear() {
        if let observer, let program { program.unobserve(observer) }
        observer = nil
        program = nil
        renderer = nil
        metalView.delegate = nil
        metalView.isPaused = true
    }

    func setRunning(_ running: Bool) {
        if running, let program, case .failed = program.state { return }
        renderer?.setPaused(!running)
        metalView.isPaused = !running
    }

    deinit {
        if let observer, let program { program.unobserve(observer) }
    }

    // MARK: touches → iMouse

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches, let t = touches.first else { return super.touchesBegan(touches, with: event) }
        renderer?.touch(t.location(in: self), in: bounds.size, scale: metalView.contentScaleFactor, began: true)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches, let t = touches.first else { return super.touchesMoved(touches, with: event) }
        renderer?.touch(t.location(in: self), in: bounds.size, scale: metalView.contentScaleFactor, began: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesEnded(touches, with: event) }
        renderer?.touch(nil, in: bounds.size, scale: metalView.contentScaleFactor, began: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsTouches else { return super.touchesCancelled(touches, with: event) }
        renderer?.touch(nil, in: bounds.size, scale: metalView.contentScaleFactor, began: false)
    }
}

/// The shader inside a bubble: the canvas, and over it the state while the
/// program compiles or once it has failed. Runs only while its cell is on
/// screen; the collection view drives that through `setActive`.
final class ShaderMessageView: UIView {
    private let canvas = ShaderCanvas()
    private let stateLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let nameLabel = UILabel()
    private var active = false
    private var failed = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = Theme.bubbleCorner
        layer.cornerCurve = .continuous
        backgroundColor = .black
        addSubview(canvas)

        stateLabel.textAlignment = .center
        stateLabel.textColor = .white.withAlphaComponent(0.85)
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

    func configure(document: ShaderDocument) {
        stateLabel.font = Theme.Text.feedNote.uiFont
        nameLabel.font = Theme.Text.thumbnailCaption.uiFont
        nameLabel.text = document.name
        nameLabel.isHidden = document.name == nil
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
