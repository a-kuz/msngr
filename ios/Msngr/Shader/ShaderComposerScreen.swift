import SwiftUI
import MsngrCore

/// Where a shader is written or pasted before it is sent: the live preview on
/// top, the code below, the compiler's verdict between them. «Send» opens
/// once the program compiled on this device.
struct ShaderComposerScreen: View {
    let onSend: (ShaderDocument) -> Void
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
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .background(Color.black)
                verdict
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                editor
            }
            .navigationTitle(document?.name ?? String(localized: "Shader"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        guard let document else { return }
                        onSend(document)
                        dismiss()
                    } label: {
                        Text("Send").bold()
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
    private var preview: some View {
        if let document {
            ShaderCanvasView(document: document, running: true, acceptsTouches: true,
                             onState: { state = $0 })
                .id(document)
                .accessibilityIdentifier("shader.composer.preview")
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sparkles").font(Theme.glyph(34, max: 44))
                Text("Shadertoy code or a Shadertoy JSON export. iTime, iResolution, iMouse, iChannel0–3, Buffer A–D.")
                    .font(Theme.Text.caption.font)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("shader.composer.paste")
            }
            .foregroundStyle(.white.opacity(0.8))
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

    private var passesLine: String {
        guard let document else { return "" }
        return document.passes.map(\.title).joined(separator: " · ")
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
}
