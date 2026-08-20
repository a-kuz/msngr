import SwiftUI

/// Top in-app banner for a new message: a separate UIWindow above the rest of
/// the UI, tap opens the chat, swipe up hides it, auto-hides after 3.5 s.
/// The window covers only the banner strip, so touches elsewhere on the screen
/// still reach the app.
@MainActor
enum InAppBannerPresenter {
    /// The window the banner lives in while it is on screen.
    private(set) static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(title: String, subtitle: String? = nil, body: String,
                     avatar: URL? = nil, chatId: String) {
        // a new banner replaces the previous one without the dismiss animation
        if window != nil { teardown() }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else { return }
        let host = UIHostingController(rootView: InAppBannerView(
            title: title, subtitle: subtitle, body: body, avatar: avatar,
            onTap: {
                dismiss(animated: false)
                NotificationCenter.default.post(name: .openChatRequested, object: chatId)
            },
            onSwipeUp: { dismiss(animated: true) }))
        host.view.backgroundColor = .clear
        // The window is the band the banner lives in and nothing more: the
        // hosting view takes every touch inside its own bounds, so a window over
        // the whole screen would leave the app untouchable. The band starts at
        // the top edge and covers the safe area as well as the banner, because
        // the layout puts the banner below the notch — a window that was only as
        // tall as the measured content ended with the banner drawn past its own
        // bounds, visible (a window does not clip) and taking no touches.
        // the content lays itself out from the window's own top edge; the window
        // is then placed below the notch. Left to its safe area, the banner was
        // pushed down inside a window only as tall as the content itself, and the
        // part below the window's edge stayed visible (a window does not clip)
        // while taking no touches at all
        host.safeAreaRegions = []
        let width = scene.screen.bounds.width
        let height = host.sizeThatFits(in: CGSize(width: width, height: 300)).height
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        w.rootViewController = host
        w.frame = CGRect(x: 0, y: 0, width: width, height: height)
        w.isHidden = false
        // the inset is read from the window itself: what the scene's other
        // windows report is not always this one's
        w.frame = CGRect(x: 0, y: w.safeAreaInsets.top, width: width, height: height)
        window = w
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled else { return }
            dismiss(animated: true)
        }
    }

    static func dismiss(animated: Bool) {
        guard let w = window else { return }
        hideTask?.cancel()
        hideTask = nil
        window = nil
        guard animated else {
            w.isHidden = true
            return
        }
        UIView.animate(withDuration: 0.25) {
            w.alpha = 0
        } completion: { _ in
            w.isHidden = true
        }
    }

    private static func teardown() {
        hideTask?.cancel()
        hideTask = nil
        window?.isHidden = true
        window = nil
    }
}

/// Banner contents: sender avatar and name, group title and a preview of the
/// decrypted text, the same as a system notification shows.
struct InAppBannerView: View {
    let title: String
    let subtitle: String?
    let avatar: URL?
    let body_: String
    let onTap: () -> Void
    let onSwipeUp: () -> Void
    @State private var appeared = false
    @State private var dragOffset: CGFloat = 0

    init(title: String, subtitle: String? = nil, body: String, avatar: URL? = nil,
         onTap: @escaping () -> Void, onSwipeUp: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.avatar = avatar
        self.body_ = body
        self.onTap = onTap
        self.onSwipeUp = onSwipeUp
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BannerAvatar(name: title, file: avatar)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(body_)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .offset(y: appeared ? min(dragOffset, 0) : -140)
            .onTapGesture(perform: onTap)
            .gesture(
                DragGesture()
                    .onChanged { v in dragOffset = v.translation.height }
                    .onEnded { v in
                        if v.translation.height < -20 {
                            onSwipeUp()
                        } else {
                            withAnimation(.spring(duration: 0.3)) { dragOffset = 0 }
                        }
                    })
            .accessibilityIdentifier("inapp.banner")
            Spacer(minLength: 0)
        }
        // the window is the whole screen, so the banner states that it lives at
        // the top of it rather than in the middle
        .frame(maxHeight: .infinity, alignment: .top)
        .onAppear {
            withAnimation(.spring(duration: 0.35)) { appeared = true }
        }
    }
}

/// Avatar from a local file, initials when there is no file.
struct BannerAvatar: View {
    let name: String
    let file: URL?

    var body: some View {
        Group {
            if let file, let image = UIImage(contentsOfFile: file.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                AvatarView(name: name, avatarId: nil)
            }
        }
        .clipShape(Circle())
    }
}
