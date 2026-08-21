import SwiftUI
import AVKit
import MsngrCore

/// Presents the viewer in its own UIWindow above the whole app UI: the window covers both
/// the chat's nav bar and the status bar.
@MainActor
enum MediaViewerPresenter {
    private static var window: UIWindow?
    private static weak var previousKeyWindow: UIWindow?

    static func present(message: Message, startIndex: Int) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }) else { return }
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let host = UIHostingController(
            rootView: MediaViewerView(message: message, startIndex: startIndex) { dismiss() })
        host.view.backgroundColor = .clear
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

/// Full-screen photo and video viewer: zoom, swipe down to close, paging through an album.
struct MediaViewerView: View {
    let message: Message
    let startIndex: Int
    let onDismiss: () -> Void
    @State private var index: Int
    @State private var dragOffset: CGSize = .zero

    init(message: Message, startIndex: Int, onDismiss: @escaping () -> Void) {
        self.message = message
        self.startIndex = startIndex
        self.onDismiss = onDismiss
        _index = State(initialValue: startIndex)
    }

    private var medias: [MediaInfo] {
        message.album ?? (message.media.map { [$0] } ?? [])
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - Double(abs(dragOffset.height)) / 500)
                .ignoresSafeArea()
            TabView(selection: $index) {
                ForEach(Array(medias.enumerated()), id: \.offset) { i, media in
                    MediaPage(media: media)
                        .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: medias.count > 1 ? .automatic : .never))
            .offset(dragOffset)
            .scaleEffect(1 - abs(dragOffset.height) / 1500)
            .gesture(
                DragGesture()
                    .onChanged { v in
                        if abs(v.translation.height) > abs(v.translation.width) {
                            dragOffset = v.translation
                        }
                    }
                    .onEnded { v in
                        if abs(v.translation.height) > 120 {
                            onDismiss()
                        } else {
                            withAnimation(Theme.springFast) { dragOffset = .zero }
                        }
                    }
            )

            VStack {
                HStack {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.glyph(17, max: 24).weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: TypeScale.scaled(40, max: 54),
                                   height: TypeScale.scaled(40, max: 54))
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    if let url = cachedURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                                .font(Theme.glyph(17, max: 24).weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: TypeScale.scaled(40, max: 54),
                                       height: TypeScale.scaled(40, max: 54))
                                .background(.black.opacity(0.4), in: Circle())
                        }
                    }
                }
                .padding()
                Spacer()
            }
            .opacity(dragOffset == .zero ? 1 : 0)
        }
        .statusBarHidden()
    }

    private var cachedURL: URL? {
        guard index < medias.count else { return nil }
        return AppState.shared.media?.cachedURL(for: medias[index].mediaId, mime: medias[index].mime)
    }
}

private struct MediaPage: View {
    let media: MediaInfo
    @State private var localURL: URL?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        Group {
            if media.type == "video" {
                if let url = localURL {
                    VideoPlayerPage(url: url)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let url = localURL, media.mime == "image/gif" {
                // a GIF is animated here as well: AsyncImage would show its first
                // frame and nothing else
                GIFPage(url: url)
            } else if let url = localURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { v in scale = max(1, lastScale * v) }
                                    .onEnded { _ in
                                        lastScale = scale
                                        if scale < 1.05 {
                                            withAnimation(Theme.springFast) { scale = 1; lastScale = 1 }
                                        }
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation(Theme.springFast) {
                                    scale = scale > 1 ? 1 : 2.5
                                    lastScale = scale
                                }
                            }
                    } else {
                        blurPlaceholder
                    }
                }
            } else {
                blurPlaceholder
            }
        }
        .task {
            localURL = try? await AppState.shared.media?.fetch(media)
        }
    }

    private var blurPlaceholder: some View {
        Group {
            if let bh = media.blurhash,
               let px = BlurHash.decodePixels(bh, width: 32, height: 32),
               let img = UIImage.fromRGBA(px, width: 32, height: 32) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
    }
}

/// An animated GIF at full screen, played by the same frame loop the feed uses.
private struct GIFPage: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        guard context.coordinator.shownURL != url else { return }
        context.coordinator.shownURL = url
        context.coordinator.animation?.stop()
        guard let data = try? Data(contentsOf: url) else { return }
        let animation = GIFAnimation(data: data, into: view)
        context.coordinator.animation = animation
        animation.start()
    }

    static func dismantleUIView(_ view: UIImageView, coordinator: Coordinator) {
        coordinator.animation?.stop()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var animation: GIFAnimation?
        var shownURL: URL?
    }
}

/// Video: the decrypted file is played from the media cache.
private struct VideoPlayerPage: View {
    let url: URL
    @State private var player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                player = AVPlayer(url: url)
                player?.play()
            }
            .onDisappear { player?.pause() }
    }
}
