import SwiftUI
import AVKit
import MsngrCore

/// What the viewer flies out of: the tapped thumbnail's picture and where it
/// sits on the screen, so the hero transition starts and ends in that frame.
struct MediaViewerHero {
    let frame: CGRect
    let image: UIImage
    let cornerRadius: CGFloat
}

/// Presents the viewer in its own UIWindow above the whole app UI: the window covers both
/// the chat's nav bar and the status bar.
@MainActor
enum MediaViewerPresenter {
    private static var window: UIWindow?
    private static weak var previousKeyWindow: UIWindow?

    /// `sourceView` is the tapped thumbnail; when it carries a picture the
    /// viewer opens with a hero flight from its frame instead of a fade.
    /// `onEdited` arms the markup button on photos: the marked-up copy is
    /// handed back and the viewer closes.
    static func present(message: Message, startIndex: Int, from sourceView: UIView? = nil,
                        onEdited: ((UIImage) -> Void)? = nil) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                  .compactMap({ $0 as? UIWindowScene })
                  .first(where: { $0.activationState == .foregroundActive }) else { return }
        previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        var hero: MediaViewerHero?
        if let iv = sourceView as? UIImageView, let image = iv.image, let win = iv.window {
            hero = MediaViewerHero(frame: iv.convert(iv.bounds, to: win),
                                   image: image,
                                   cornerRadius: iv.layer.cornerRadius)
        }
        let host = UIHostingController(
            rootView: MediaViewerView(message: message, startIndex: startIndex, hero: hero,
                                      onEdited: onEdited)
            { animatedOut in dismiss(fade: !animatedOut) })
        host.view.backgroundColor = .clear
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        w.rootViewController = host
        w.makeKeyAndVisible()
        // with a hero the flight itself is the appearance; without one, a fade
        if hero == nil {
            w.alpha = 0
            UIView.animate(withDuration: 0.2) { w.alpha = 1 }
        }
        window = w
    }

    static func dismiss(fade: Bool = true) {
        guard let w = window else { return }
        window = nil
        if fade {
            UIView.animate(withDuration: 0.2) {
                w.alpha = 0
            } completion: { _ in
                w.isHidden = true
            }
        } else {
            w.isHidden = true
        }
        previousKeyWindow?.makeKey()
    }
}

/// Full-screen photo and video viewer: zoom, swipe down to close, paging through an album.
/// With a hero source the thumbnail's picture flies from its bubble frame into the fitted
/// full-screen frame on open, and back on close — including a close by the swipe down,
/// which returns from wherever the drag left the picture.
struct MediaViewerView: View {
    let message: Message
    let startIndex: Int
    let hero: MediaViewerHero?
    /// Set on photos opened from a chat: the marked-up copy goes here.
    let onEdited: ((UIImage) -> Void)?
    /// `true` — the hero already animated the window out; `false` — fade the window.
    let onDismiss: (Bool) -> Void
    @State private var index: Int
    @State private var dragOffset: CGSize = .zero
    /// The flight state: expanded means the picture stands at its full-screen frame.
    @State private var heroExpanded = false
    /// Once the flight in has finished, the real pages take over from the overlay.
    @State private var heroDone: Bool
    @State private var closing = false
    @State private var markingUp = false

    init(message: Message, startIndex: Int, hero: MediaViewerHero?,
         onEdited: ((UIImage) -> Void)? = nil, onDismiss: @escaping (Bool) -> Void) {
        self.message = message
        self.startIndex = startIndex
        self.hero = hero
        self.onEdited = onEdited
        self.onDismiss = onDismiss
        _index = State(initialValue: startIndex)
        _heroDone = State(initialValue: hero == nil)
    }

    private var medias: [MediaInfo] {
        message.album ?? (message.media.map { [$0] } ?? [])
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                    .opacity((hero == nil || heroExpanded ? 1 : 0) * (1 - Double(abs(dragOffset.height)) / 500))
                    .ignoresSafeArea()
                content
                    .opacity(heroDone && !closing ? 1 : 0)
                if let hero, !heroDone || closing {
                    heroOverlay(hero, in: geo)
                }
            }
            .onAppear {
                guard hero != nil else { return }
                withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) { heroExpanded = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) { heroDone = true }
            }
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    private var content: some View {
        ZStack {
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
                            close()
                        } else {
                            withAnimation(Theme.springFast) { dragOffset = .zero }
                        }
                    }
            )

            VStack {
                HStack {
                    Button {
                        close()
                    } label: {
                        Image(systemName: "xmark")
                            .font(Theme.glyph(17, max: 24).weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: TypeScale.scaled(40, max: 54),
                                   height: TypeScale.scaled(40, max: 54))
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    Spacer()
                    if onEdited != nil, let image = editableImage {
                        Button {
                            markingUp = true
                        } label: {
                            Image(systemName: "pencil.tip.crop.circle")
                                .font(Theme.glyph(17, max: 24).weight(.semibold))
                                .foregroundStyle(.white)
                                .frame(width: TypeScale.scaled(40, max: 54),
                                       height: TypeScale.scaled(40, max: 54))
                                .background(.black.opacity(0.4), in: Circle())
                        }
                        .accessibilityIdentifier("viewer.markup")
                        .fullScreenCover(isPresented: $markingUp) {
                            MarkupEditorScreen(image: image,
                                               onDone: { edited in
                                                   markingUp = false
                                                   onEdited?(edited)
                                                   onDismiss(false)
                                               },
                                               onCancel: { markingUp = false })
                                .ignoresSafeArea()
                        }
                    }
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
    }

    /// The shown photo as a picture for the markup editor: photos only — a
    /// video has no still to draw on and a GIF would lose its motion.
    private var editableImage: UIImage? {
        guard index < medias.count else { return nil }
        let media = medias[index]
        guard media.type == "photo", media.mime != "image/gif", let url = cachedURL else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// The flying picture: the thumbnail scaled between its bubble frame and the
    /// full-screen fit. While the drag is dismissing, the flight starts from the
    /// dragged position instead of the resting one.
    private func heroOverlay(_ hero: MediaViewerHero, in geo: GeometryProxy) -> some View {
        let container = geo.frame(in: .global)
        var rect: CGRect
        if heroExpanded {
            rect = Self.fitted(hero.image.size, in: container)
            if closing {
                rect = rect.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
                let s = 1 - abs(dragOffset.height) / 1500
                rect = CGRect(x: rect.midX - rect.width * s / 2, y: rect.midY - rect.height * s / 2,
                              width: rect.width * s, height: rect.height * s)
            }
        } else {
            rect = hero.frame
        }
        let local = rect.offsetBy(dx: -container.minX, dy: -container.minY)
        return Image(uiImage: hero.image)
            .resizable()
            .scaledToFill()
            .frame(width: local.width, height: local.height)
            .clipShape(RoundedRectangle(cornerRadius: heroExpanded ? 0 : hero.cornerRadius, style: .continuous))
            .position(x: local.midX, y: local.midY)
            .allowsHitTesting(false)
    }

    /// Aspect-fit of the picture in the container: where the full-screen page shows it.
    private static func fitted(_ size: CGSize, in container: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return container }
        let s = min(container.width / size.width, container.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: container.minX + (container.width - w) / 2,
                      y: container.minY + (container.height - h) / 2,
                      width: w, height: h)
    }

    /// Close with the hero flight back into the bubble when the picture on screen is
    /// still the one that flew in; otherwise the plain fade.
    private func close() {
        guard hero != nil, index == startIndex, !closing else {
            onDismiss(false)
            return
        }
        closing = true
        withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
            heroExpanded = false
            dragOffset = .zero
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) { onDismiss(true) }
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
/// The system player without picture-in-picture: its PiP glyph sits in the
/// top-left corner, exactly under the viewer's close button, and took the tap.
private struct VideoPlayerPage: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = AVPlayer(url: url)
        vc.allowsPictureInPicturePlayback = false
        vc.view.backgroundColor = .clear
        vc.player?.play()
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: ()) {
        vc.player?.pause()
    }
}
