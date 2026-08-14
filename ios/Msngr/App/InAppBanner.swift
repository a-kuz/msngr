import SwiftUI

/// Верхний in-app баннер о новом сообщении (как в Telegram): отдельный UIWindow
/// поверх всего UI, тап — переход в чат, свайп вверх — скрыть, автоскрытие 3.5 с.
/// Окно занимает только полосу баннера — касания остального экрана идут в приложение.
@MainActor
enum InAppBannerPresenter {
    private static var window: UIWindow?
    private static var hideTask: Task<Void, Never>?

    static func show(title: String, subtitle: String? = nil, body: String,
                     avatar: URL? = nil, chatId: String) {
        // новый баннер замещает предыдущий без анимации ухода
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
        let width = scene.screen.bounds.width
        let topInset = scene.windows.first?.safeAreaInsets.top ?? 59
        let height = host.sizeThatFits(in: CGSize(width: width, height: 300)).height
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.statusBar.rawValue + 1)
        w.rootViewController = host
        w.frame = CGRect(x: 0, y: topInset, width: width, height: height)
        w.isHidden = false
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

/// Содержимое баннера: аватар и имя отправителя, название группы и превью
/// расшифрованного текста — то же, что видно в системном уведомлении.
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
        }
        .onAppear {
            withAnimation(.spring(duration: 0.35)) { appeared = true }
        }
    }
}

/// Аватар из локального файла; файла нет — инициалы.
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
