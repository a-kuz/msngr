import SwiftUI
import MsngrCore

/// What the shader written in the composer is for. The purpose sets the
/// preview's shape, the title and the word on the action button; the code
/// and the verdict are the same for all of them.
enum ShaderComposerPurpose: Hashable, Identifiable {
    case message
    case bubble
    case sticker
    case background
    case effect(ShaderSurfaces.Effect)
    case avatar

    var id: Self { self }

    var title: String {
        switch self {
        case .message: return String(localized: "Shader")
        case .bubble: return String(localized: "Bubble shader")
        case .sticker: return String(localized: "Shader sticker")
        case .background: return String(localized: "Chat background")
        case .effect(.send): return String(localized: "Send effect")
        case .effect(.reaction): return String(localized: "Reaction effect")
        case .avatar: return String(localized: "Shader avatar")
        }
    }

    var action: String {
        switch self {
        case .message: return String(localized: "Send")
        case .bubble: return String(localized: "Attach")
        case .sticker: return String(localized: "Save")
        case .background, .avatar: return String(localized: "Set")
        case .effect: return String(localized: "Use")
        }
    }

    /// The preview's aspect: a bubble is a wide picture, a sticker and an
    /// avatar are square, the background is a phone screen.
    var aspect: CGFloat {
        switch self {
        case .message, .bubble: return 16.0 / 9.0
        case .sticker, .avatar: return 1
        case .background, .effect: return 9.0 / 16.0
        }
    }

    /// Transparent surfaces show the chat under the preview, so `O.a` reads.
    var transparent: Bool {
        switch self {
        case .sticker, .effect: return true
        default: return false
        }
    }

    var hint: String {
        switch self {
        case .message, .bubble, .background, .avatar:
            return String(localized: "Shadertoy code or a Shadertoy JSON export. iTime, iResolution, iMouse, iChannel0–3, Buffer A–D.")
        case .sticker:
            return String(localized: "Shadertoy code. Write the alpha you want into O.a: where it is 0 the chat shows through.")
        case .effect:
            return String(localized: "Shadertoy code with alpha in O.a. iMouse.xy is where the event happened; the effect lasts about a second.")
        }
    }
}

/// Where a shader is written or pasted before it is used: the live preview on
/// top, the code below, the compiler's verdict between them. The action opens
/// once the program compiled on this device.
struct ShaderComposerScreen: View {
    var purpose: ShaderComposerPurpose = .message
    /// Code to start from, when the composer edits something that exists.
    var initial: ShaderDocument? = nil
    let onDone: (ShaderDocument) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var document: ShaderDocument?
    @State private var parseError: String?
    @State private var state: ShaderProgram.State = .compiling
    @State private var parseTask: Task<Void, Never>?
    @FocusState private var editing: Bool

    private var ready: Bool {
        if document == nil { return false }
        if case .ready = state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                preview
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 320)
                    .aspectRatio(purpose.aspect, contentMode: .fit)
                    .background(previewBackdrop)
                    .clipShape(previewShape)
                    .padding(.horizontal, purpose.aspect == 1 || purpose.aspect < 1 ? 60 : 0)
                    .padding(.vertical, purpose.aspect == 1 || purpose.aspect < 1 ? 8 : 0)
                verdict
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                editor
            }
            .navigationTitle(document?.name ?? purpose.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let document else { return }
                        onDone(document)
                        dismiss()
                    } label: {
                        Text(purpose.action).bold()
                    }
                    .disabled(!ready)
                    .accessibilityIdentifier("shader.composer.send")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    Spacer()
                    Button(String(localized: "Done")) { editing = false }
                }
            }
        }
        .onAppear {
            if let initial, text.isEmpty {
                text = initial.passes.count == 1 ? initial.displaySource : Self.json(initial)
                reparse()
                return
            }
            // the usual way in: the code is already on the clipboard
            if text.isEmpty, let clip = UIPasteboard.general.string,
               clip.contains("mainImage") || clip.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                text = clip
                reparse()
            }
        }
        .onChange(of: text) { _, _ in reparse(debounced: true) }
    }

    @ViewBuilder
    private var previewBackdrop: some View {
        if purpose.transparent {
            // a checkerboard shows where the shader left the alpha at zero
            Checkerboard().foregroundStyle(.secondary.opacity(0.25))
        } else {
            Color.black
        }
    }

    private var previewShape: AnyShape {
        switch purpose {
        case .avatar: return AnyShape(Circle())
        case .sticker, .bubble: return AnyShape(RoundedRectangle(cornerRadius: Theme.bubbleCorner, style: .continuous))
        case .background: return AnyShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        case .message, .effect: return AnyShape(Rectangle())
        }
    }

    @ViewBuilder
    private var preview: some View {
        if let document {
            ShaderCanvasView(document: document, running: true, acceptsTouches: true,
                             transparent: purpose.transparent, deviceInputs: true, priority: .focus,
                             onState: { state = $0 })
                .id(document)
                .accessibilityIdentifier("shader.composer.preview")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(Theme.glyph(34, max: 44))
                Text(purpose.hint)
                    .font(Theme.Text.caption.font)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shader.composer.paste")
            }
            .foregroundStyle(purpose.transparent ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white.opacity(0.8)))
        }
    }

    @ViewBuilder
    private var verdict: some View {
        if let parseError {
            Label(parseError, systemImage: "exclamationmark.triangle")
                .font(Theme.Text.caption.font).foregroundStyle(.red).lineLimit(2)
        } else if document != nil {
            switch state {
            case .compiling:
                Label("Compiling…", systemImage: "hourglass").font(Theme.Text.caption.font).foregroundStyle(.secondary)
            case .ready:
                Label(passesLine, systemImage: "checkmark.circle").font(Theme.Text.caption.font).foregroundStyle(.green)
            case .failed(let reason):
                Label(reason, systemImage: "xmark.octagon").font(Theme.Text.caption.font).foregroundStyle(.red).lineLimit(3)
            }
        } else {
            Text(" ").font(Theme.Text.caption.font)
        }
    }

    /// The passes, and the device inputs the code reads, so the author sees
    /// what the shader will ask the phone for.
    private var passesLine: String {
        guard let document else { return "" }
        var parts = document.passes.map(\.title)
        let feeds = DeviceInputs.feeds(for: document)
        if feeds.contains(.motion) { parts.append(String(localized: "motion")) }
        if feeds.contains(.location) { parts.append(String(localized: "location")) }
        if feeds.contains(.mic) { parts.append(String(localized: "microphone")) }
        if feeds.contains(.camera(front: false)) || feeds.contains(.camera(front: true)) { parts.append(String(localized: "camera")) }
        if feeds.contains(.keyboard) { parts.append(String(localized: "keyboard")) }
        if document.haptics == true { parts.append(String(localized: "haptics")) }
        return parts.joined(separator: " · ")
    }

    private var editor: some View {
        TextEditor(text: $text)
            .font(Theme.Text.monospacedTag.font)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .focused($editing)
            .accessibilityIdentifier("shader.composer.code")
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Paste shader code")
                        .font(Theme.Text.monospacedTag.font)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .allowsHitTesting(false)
                }
            }
    }

    private func paste() {
        guard let clip = UIPasteboard.general.string, !clip.isEmpty else { return }
        text = clip
        reparse()
    }

    /// The document is rebuilt after a pause in typing; a pasted text is
    /// parsed at once.
    private func reparse(debounced: Bool = false) {
        parseTask?.cancel()
        parseTask = Task {
            if debounced { try? await Task.sleep(for: .milliseconds(400)) }
            guard !Task.isCancelled else { return }
            let source = text
            guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                document = nil
                parseError = nil
                return
            }
            do {
                let doc = try ShaderDocument.parse(source)
                parseError = nil
                if doc != document {
                    state = .compiling
                    document = doc
                }
            } catch {
                parseError = "\(error)"
                document = nil
            }
        }
    }

    static func json(_ document: ShaderDocument) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? document.displaySource
    }
}

/// Squares behind a transparent preview.
struct Checkerboard: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s: CGFloat = 12
        var y = rect.minY
        var row = 0
        while y < rect.maxY {
            var x = rect.minX + (row % 2 == 0 ? 0 : s)
            while x < rect.maxX {
                p.addRect(CGRect(x: x, y: y, width: s, height: s))
                x += 2 * s
            }
            y += s
            row += 1
        }
        return p
    }
}
