import SwiftUI
import UIKit

/// Full-screen markup over one picture. `onDone` hands out the rendered
/// result; leaving through the cross discards every step.
struct MarkupEditorScreen: UIViewControllerRepresentable {
    let image: UIImage
    let onDone: (UIImage) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> MarkupEditorController {
        MarkupEditorController(image: image, onDone: onDone, onCancel: onCancel)
    }

    func updateUIViewController(_ vc: MarkupEditorController, context: Context) {}
}

final class MarkupEditorController: UIViewController, UIGestureRecognizerDelegate, UITextFieldDelegate {
    private let onDone: (UIImage) -> Void
    private let onCancel: () -> Void
    private let canvas: MarkupCanvasView

    private let topBar = UIStackView()
    private let bottomBar = UIStackView()
    private let cancelButton = UIButton(type: .system)
    private let undoButton = UIButton(type: .system)
    private let redoButton = UIButton(type: .system)
    private let rotateButton = UIButton(type: .system)
    private let cropButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private var toolButtons: [MarkupTool: UIButton] = [:]
    private var colorButtons: [UIButton] = []
    private let widthSlider = UISlider()
    private let cropOverlay = CropOverlayView()

    private var tool: MarkupTool = .pen { didSet { canvas.tool = tool; reflectTool() } }
    private static let palette: [UIColor] = [
        .white, .black, .systemRed, .systemOrange, .systemYellow,
        .systemGreen, .systemBlue, .systemPurple,
    ]
    private var color: UIColor = MarkupEditorController.palette[2] {
        didSet { canvas.color = color; reflectColor() }
    }

    /// The label being retyped, nil for a fresh one; with the anchor for a
    /// fresh label's placement.
    private var editingLabel: MarkupStroke?
    private var pendingTextPoint: CGPoint = .zero
    private var textField: UITextField?

    init(image: UIImage, onDone: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
        self.onDone = onDone
        self.onCancel = onCancel
        canvas = MarkupCanvasView(image: image)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(canvas)
        canvas.color = color
        canvas.lineWidth = 4
        canvas.onChange = { [weak self] in self?.reflectHistory() }
        canvas.onTextTap = { [weak self] p in self?.beginText(at: p, editing: nil) }
        canvas.onTextEdit = { [weak self] stroke in self?.beginText(at: .zero, editing: stroke) }

        let tap = UITapGestureRecognizer(target: canvas, action: #selector(MarkupCanvasView.handleTextTap(_:)))
        tap.delegate = self
        canvas.addGestureRecognizer(tap)

        buildBars()
        cropOverlay.isHidden = true
        cropOverlay.accessibilityIdentifier = "markup.cropOverlay"
        view.addSubview(cropOverlay)
        reflectTool()
        reflectColor()
        reflectHistory()
    }

    // the text tool commits taps through the gesture; every other tool draws dots
    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        tool == .text
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let safe = view.safeAreaInsets
        let barHeight: CGFloat = 44
        topBar.frame = CGRect(x: 12, y: safe.top + 4, width: view.bounds.width - 24, height: barHeight)
        let bottomHeight: CGFloat = 96
        bottomBar.frame = CGRect(x: 12, y: view.bounds.height - safe.bottom - bottomHeight,
                                 width: view.bounds.width - 24, height: bottomHeight)
        canvas.frame = CGRect(x: 0, y: topBar.frame.maxY + 4,
                              width: view.bounds.width,
                              height: bottomBar.frame.minY - topBar.frame.maxY - 8)
        cropOverlay.frame = canvas.frame
    }

    // MARK: - Bars

    private func buildBars() {
        func glyph(_ button: UIButton, _ name: String, id: String, action: @escaping () -> Void) {
            button.setImage(UIImage(systemName: name), for: .normal)
            button.tintColor = .white
            button.accessibilityIdentifier = id
            button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        }
        glyph(cancelButton, "xmark", id: "markup.cancel") { [weak self] in self?.cancelTapped() }
        glyph(undoButton, "arrow.uturn.backward", id: "markup.undo") { [weak self] in self?.canvas.undo() }
        glyph(redoButton, "arrow.uturn.forward", id: "markup.redo") { [weak self] in self?.canvas.redo() }
        glyph(rotateButton, "rotate.right", id: "markup.rotate") { [weak self] in
            guard let self else { return }
            // the crop frame was aimed at the old orientation
            if !cropOverlay.isHidden { exitCropMode(apply: false) }
            canvas.rotateClockwise()
        }
        glyph(cropButton, "crop", id: "markup.crop") { [weak self] in self?.toggleCrop() }
        doneButton.setTitle(String(localized: "Done"), for: .normal)
        doneButton.setTitleColor(.white, for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        doneButton.accessibilityIdentifier = "markup.done"
        doneButton.addAction(UIAction { [weak self] _ in self?.doneTapped() }, for: .touchUpInside)

        topBar.axis = .horizontal
        topBar.distribution = .equalSpacing
        [cancelButton, undoButton, redoButton, rotateButton, cropButton, doneButton]
            .forEach(topBar.addArrangedSubview)
        view.addSubview(topBar)

        // tools
        let tools = UIStackView()
        tools.axis = .horizontal
        tools.distribution = .equalSpacing
        let icons: [(MarkupTool, String, String)] = [
            (.pen, "scribble", "markup.tool.pen"),
            (.arrow, "arrow.up.right", "markup.tool.arrow"),
            (.line, "line.diagonal", "markup.tool.line"),
            (.rect, "rectangle", "markup.tool.rect"),
            (.ellipse, "circle", "markup.tool.ellipse"),
            (.blur, "eye.slash", "markup.tool.blur"),
            (.text, "textformat", "markup.tool.text"),
        ]
        for (t, name, id) in icons {
            let b = UIButton(type: .system)
            glyph(b, name, id: id) { [weak self] in self?.tool = t }
            toolButtons[t] = b
            tools.addArrangedSubview(b)
        }

        // colors and the width
        let colors = UIStackView()
        colors.axis = .horizontal
        colors.distribution = .equalSpacing
        for (i, c) in Self.palette.enumerated() {
            let b = UIButton(type: .custom)
            b.backgroundColor = c
            b.layer.cornerRadius = 12
            b.layer.borderColor = UIColor.white.cgColor
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 24).isActive = true
            b.heightAnchor.constraint(equalToConstant: 24).isActive = true
            b.accessibilityIdentifier = "markup.color.\(i)"
            b.addAction(UIAction { [weak self] _ in self?.color = c }, for: .touchUpInside)
            colorButtons.append(b)
            colors.addArrangedSubview(b)
        }
        widthSlider.minimumValue = 2
        widthSlider.maximumValue = 14
        widthSlider.value = 4
        widthSlider.accessibilityIdentifier = "markup.width"
        widthSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            canvas.lineWidth = CGFloat(widthSlider.value)
        }, for: .valueChanged)
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        colors.addArrangedSubview(widthSlider)

        bottomBar.axis = .vertical
        bottomBar.spacing = 10
        bottomBar.addArrangedSubview(colors)
        bottomBar.addArrangedSubview(tools)
        view.addSubview(bottomBar)
    }

    private func reflectTool() {
        for (t, b) in toolButtons {
            b.tintColor = t == tool ? view.tintColor : .white
        }
        if !cropOverlay.isHidden { exitCropMode(apply: false) }
    }

    private func reflectColor() {
        for (i, b) in colorButtons.enumerated() {
            b.layer.borderWidth = Self.palette[i] == color ? 2.5 : (Self.palette[i] == .black ? 0.5 : 0)
        }
    }

    private func reflectHistory() {
        undoButton.isEnabled = canvas.history.canUndo
        redoButton.isEnabled = canvas.history.canRedo
        cropOverlay.imageFrame = canvas.imageFrame
    }

    private func cancelTapped() {
        if canvas.history.canUndo {
            // leaving without saving drops every step: say so once
            let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
            sheet.addAction(UIAlertAction(title: String(localized: "Discard markup"),
                                          style: .destructive) { [weak self] _ in self?.onCancel() })
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = cancelButton
            present(sheet, animated: true)
        } else {
            onCancel()
        }
    }

    private func doneTapped() {
        if !cropOverlay.isHidden { exitCropMode(apply: true) }
        onDone(canvas.export())
    }

    // MARK: - Crop mode

    private func toggleCrop() {
        if cropOverlay.isHidden {
            cropOverlay.imageFrame = canvas.imageFrame
            cropOverlay.resetSelection()
            cropOverlay.isHidden = false
            canvas.isUserInteractionEnabled = false
            cropButton.tintColor = view.tintColor
        } else {
            exitCropMode(apply: true)
        }
    }

    private func exitCropMode(apply: Bool) {
        let selection = cropOverlay.selection
        let untouched = selection == cropOverlay.imageFrame
        cropOverlay.isHidden = true
        canvas.isUserInteractionEnabled = true
        cropButton.tintColor = .white
        if apply, !untouched {
            canvas.applyCrop(selection)
        }
    }

    // MARK: - Text entry

    private func beginText(at point: CGPoint, editing: MarkupStroke?) {
        guard textField == nil else { return }
        editingLabel = editing
        pendingTextPoint = point
        let field = UITextField()
        field.text = editing?.text
        field.textColor = .white
        field.tintColor = .white
        field.font = .systemFont(ofSize: 24, weight: .semibold)
        field.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        field.layer.cornerRadius = 10
        field.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 12, height: 1))
        field.leftViewMode = .always
        field.returnKeyType = .done
        field.delegate = self
        field.accessibilityIdentifier = "markup.textField"
        field.frame = CGRect(x: 24, y: canvas.frame.midY - 24, width: view.bounds.width - 48, height: 48)
        view.addSubview(field)
        textField = field
        field.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        commitText(field.text ?? "")
        return true
    }

    func textFieldDidEndEditing(_ field: UITextField) {
        commitText(field.text ?? "")
    }

    private func commitText(_ text: String) {
        guard let field = textField else { return }
        textField = nil
        field.resignFirstResponder()
        field.removeFromSuperview()
        if let editing = editingLabel {
            canvas.updateText(id: editing.id, to: text)
        } else {
            let size = max(18, canvas.lineWidth * 7)
            canvas.addText(text, at: pendingTextPoint, fontSize: size)
        }
        editingLabel = nil
    }
}

/// The crop frame: a dimmed field with a bright-cornered rectangle, corners
/// drag to resize, the middle drags to move.
final class CropOverlayView: UIView {
    var imageFrame: CGRect = .zero {
        didSet { if selection == .zero || oldValue == .zero { selection = imageFrame } }
    }
    private(set) var selection: CGRect = .zero { didSet { setNeedsDisplay() } }
    private enum Grip { case corner(Int), whole }
    private var drag: (grip: Grip, start: CGPoint, rect: CGRect)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func resetSelection() {
        selection = imageFrame
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(bounds)
        ctx.clear(selection)
        ctx.setStrokeColor(UIColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(selection)
        ctx.setLineWidth(4)
        let l: CGFloat = 22
        for corner in corners {
            let dx: CGFloat = corner.x < selection.midX ? 1 : -1
            let dy: CGFloat = corner.y < selection.midY ? 1 : -1
            ctx.move(to: CGPoint(x: corner.x + dx * l, y: corner.y))
            ctx.addLine(to: corner)
            ctx.addLine(to: CGPoint(x: corner.x, y: corner.y + dy * l))
            ctx.strokePath()
        }
    }

    private var corners: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self) else { return }
        if let (i, _) = corners.enumerated().min(by: {
            hypot($0.1.x - p.x, $0.1.y - p.y) < hypot($1.1.x - p.x, $1.1.y - p.y)
        }), hypot(corners[i].x - p.x, corners[i].y - p.y) < 36 {
            drag = (.corner(i), p, selection)
        } else if selection.contains(p) {
            drag = (.whole, p, selection)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self), let drag else { return }
        let dx = p.x - drag.start.x, dy = p.y - drag.start.y
        var r = drag.rect
        switch drag.grip {
        case .whole:
            r = r.offsetBy(dx: dx, dy: dy)
            r.origin.x = min(max(r.origin.x, imageFrame.minX), imageFrame.maxX - r.width)
            r.origin.y = min(max(r.origin.y, imageFrame.minY), imageFrame.maxY - r.height)
        case .corner(let i):
            var minX = r.minX, minY = r.minY, maxX = r.maxX, maxY = r.maxY
            if i == 0 || i == 2 { minX += dx } else { maxX += dx }
            if i == 0 || i == 1 { minY += dy } else { maxY += dy }
            minX = max(minX, imageFrame.minX); minY = max(minY, imageFrame.minY)
            maxX = min(maxX, imageFrame.maxX); maxY = min(maxY, imageFrame.maxY)
            guard maxX - minX > 40, maxY - minY > 40 else { return }
            r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        selection = r
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { drag = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { drag = nil }
}
