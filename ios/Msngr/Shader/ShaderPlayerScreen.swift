import SwiftUI
import UIKit
import MsngrCore

/// The full-screen player, in a window of its own above the status bar like
/// the media viewer: the shader takes the whole screen, touches become
/// `iMouse`, the controls fade in on a tap.
@MainActor
enum ShaderPlayerPresenter {
    private static var window: UIWindow?
    private static var previousKeyWindow: UIWindow?

    static func present(document: ShaderDocument) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }) else { return }
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(rootView: ShaderPlayerScreen(document: document) { dismiss() })
        host.view.backgroundColor = .black
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        w.rootViewController = host
        w.alpha = 0
        w.makeKeyAndVisible()
        UIView.animate(withDuration: 0.2) { w.alpha = 1 }
        window = w
    }

    static func dismiss() {
        guard let w = window else { return }
        window = nil
        UIView.animate(withDuration: 0.2) {
            w.alpha = 0
        } completion: { _ in
            w.isHidden = true
        }
        previousKeyWindow?.makeKey()
    }
}

/// SwiftUI face of `ShaderCanvas`. `running` starts and stops the frames;
/// `restartToken` changing puts the shader back to frame zero.
struct ShaderCanvasView: UIViewRepresentable {
    let document: ShaderDocument
    var running: Bool = true
    var acceptsTouches: Bool = false
    var transparent: Bool = false
    var priority: ShaderCanvas.Priority = .focus
    var restartToken: Int = 0
    var onState: ((ShaderProgram.State) -> Void)? = nil
    var onFrame: ((Float) -> Void)? = nil

    func makeUIView(context: Context) -> ShaderCanvas {
        let v = ShaderCanvas(transparent: transparent)
        v.backgroundColor = transparent ? .clear : .black
        v.priority = priority
        v.acceptsTouches = acceptsTouches
        context.coordinator.restartToken = restartToken
        return v
    }

    func updateUIView(_ v: ShaderCanvas, context: Context) {
        v.acceptsTouches = acceptsTouches
        v.priority = priority
        v.onState = onState
        v.show(document)
        v.renderer?.onFrame = onFrame
        if context.coordinator.restartToken != restartToken {
            context.coordinator.restartToken = restartToken
            v.renderer?.restart()
        }
        v.setRunning(running)
    }

    static func dismantleUIView(_ v: ShaderCanvas, coordinator: Coordinator) {
        v.clear()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var restartToken = 0 }
}

struct ShaderPlayerScreen: View {
    let document: ShaderDocument
    let onClose: () -> Void

    @State private var running = true
    @State private var controlsShown = true
    @State private var restartToken = 0
    @State private var time: Float = 0
    @State private var state: ShaderProgram.State = .compiling
    @State private var showSource = false

    var body: some View {
        ZStack {
            ShaderCanvasView(document: document, running: running, acceptsTouches: true,
                             restartToken: restartToken,
                             onState: { state = $0 },
                             onFrame: { t in time = t })
                .ignoresSafeArea()
                .accessibilityIdentifier("shader.player.canvas")
            if case .failed(let reason) = state {
                VStack(spacing: 8) {
                    Text("Could not be shown").font(Theme.Text.body.font).foregroundStyle(.white)
                    Text(reason).font(Theme.Text.monospacedTag.font).foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            } else if case .compiling = state {
                ProgressView().tint(.white)
            }
            controls
                .opacity(controlsShown ? 1 : 0)
                .animation(.easeInOut(duration: 0.2), value: controlsShown)
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .onTapGesture { controlsShown.toggle() }
        .sheet(isPresented: $showSource) {
            ShaderSourceSheet(document: document)
        }
        .statusBarHidden(true)
    }

    private var controls: some View {
        VStack {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(Theme.glyph(17, max: 24)).padding(10)
                }
                .accessibilityIdentifier("shader.player.close")
                Spacer()
                if let name = document.name {
                    Text(name).font(Theme.Text.headerTitle.font).lineLimit(1)
                }
                Spacer()
                Button { showSource = true } label: {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .font(Theme.glyph(17, max: 24)).padding(10)
                }
                .accessibilityIdentifier("shader.player.source")
            }
            .padding(.horizontal, 8)
            .padding(.top, 8)
            Spacer()
            HStack(spacing: 24) {
                Button { restartToken &+= 1 } label: {
                    Image(systemName: "arrow.counterclockwise").font(Theme.glyph(20, max: 28))
                }
                Button { running.toggle() } label: {
                    Image(systemName: running ? "pause.fill" : "play.fill").font(Theme.glyph(24, max: 32))
                }
                .accessibilityIdentifier("shader.player.pause")
                Text(Self.clock(time))
                    .font(Theme.Text.recordTimer.font)
                    .monospacedDigit()
                    .frame(minWidth: 64, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.black.opacity(0.45), in: Capsule())
            .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .tint(.white)
        .padding(.top, 44)
    }

    static func clock(_ t: Float) -> String {
        let s = Int(t)
        return String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Float(s)) * 10))
    }
}

/// The code of the shader, pass by pass, with a copy action.
struct ShaderSourceSheet: View {
    let document: ShaderDocument
    @State private var copied = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.vertical, .horizontal]) {
                Text(document.displaySource)
                    .font(Theme.Text.monospacedTag.font)
                    .textSelection(.enabled)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(document.name ?? String(localized: "Source"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = document.passes.count == 1
                            ? document.displaySource : exportJSON
                        copied = true
                        Haptics.light()
                    } label: {
                        Label(copied ? String(localized: "Copied") : String(localized: "Copy"),
                              systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .accessibilityIdentifier("shader.source.copy")
                }
            }
        }
    }

    /// A multipass shader is copied as the document itself, which the
    /// composer accepts back as it is.
    private var exportJSON: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(document)).flatMap { String(data: $0, encoding: .utf8) } ?? document.displaySource
    }
}
