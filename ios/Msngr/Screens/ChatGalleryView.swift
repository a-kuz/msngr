import SwiftUI
import SafariServices
import GRDB
import MsngrCore

/// Вложения чата: сетка медиа, списки файлов, голосовых и ссылок.
///
/// Страницы читаются по запросу и складываются в массив — наблюдения за базой
/// здесь нет намеренно: любое изменение чата перечитывало бы всю набранную
/// историю целиком. Экран открывается заново — набирается заново.
@MainActor
final class ChatGalleryModel: ObservableObject {
    let chatId: String
    @Published var tab: GalleryTab = .media {
        didSet { load(tab) }
    }
    @Published private(set) var entries: [GalleryTab: [GalleryEntry]] = [:]
    /// Вкладки, у которых первая страница уже прочитана: до этого пусто —
    /// состояние загрузки, а не «ничего нет».
    @Published private(set) var opened: Set<GalleryTab> = []

    private var cursors: [GalleryTab: GalleryCursor] = [:]
    private var finished: Set<GalleryTab> = []
    private var loading: Set<GalleryTab> = []

    init(chatId: String) {
        self.chatId = chatId
    }

    func items(_ tab: GalleryTab) -> [GalleryEntry] { entries[tab] ?? [] }

    /// Догрузка на подходе к концу списка: вызывается ячейками у нижнего края.
    func loadMoreIfNeeded(_ tab: GalleryTab, at entry: GalleryEntry) {
        let items = items(tab)
        guard let index = items.firstIndex(where: { $0.id == entry.id }),
              index >= items.count - ChatGallery.pageSize / 3 else { return }
        load(tab)
    }

    /// Следующая страница вкладки. Повторный вызов во время чтения и вызов на
    /// исчерпанной вкладке ничего не делают.
    func load(_ tab: GalleryTab) {
        guard !loading.contains(tab), !finished.contains(tab),
              let db = AppState.shared.db else { return }
        loading.insert(tab)
        let chatId = self.chatId
        let cursor = cursors[tab]
        Task { [weak self] in
            let page = try? await db.read { dbc in
                try ChatGallery.page(dbc, chatId: chatId, tab: tab, after: cursor)
            }
            guard let self else { return }
            self.loading.remove(tab)
            self.opened.insert(tab)
            guard let page else { return }
            self.entries[tab, default: []] += page.entries
            self.cursors[tab] = page.cursor
            if page.reachedEnd { self.finished.insert(tab) }
        }
    }

    /// Сообщение, которому принадлежит запись: просмотрщик и переход в ленту
    /// работают с ним, а не с записью галереи.
    func message(_ entry: GalleryEntry) async -> Message? {
        guard let db = AppState.shared.db else { return nil }
        return try? await db.read { [chatId] dbc in
            try Message.fetchOne(dbc, sql: """
                SELECT * FROM message WHERE chatId = ? AND (msgId = ? OR id = ?) LIMIT 1
                """, arguments: [chatId, entry.messageId, entry.messageId])
        }
    }
}

struct ChatGalleryView: View {
    let chatId: String
    @StateObject private var model: ChatGalleryModel
    /// Строка голосового показывает, играет ли оно сейчас.
    @ObservedObject private var voice = VoicePlayer.shared

    init(chatId: String) {
        self.chatId = chatId
        _model = StateObject(wrappedValue: ChatGalleryModel(chatId: chatId))
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.tab) {
                ForEach(GalleryTab.allCases, id: \.self) { tab in
                    Text(Self.title(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .accessibilityIdentifier("gallery.tabs")

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.chatBackground.ignoresSafeArea())
        .navigationTitle("Вложения")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.load(model.tab) }
    }

    @ViewBuilder
    private var content: some View {
        let items = model.items(model.tab)
        if items.isEmpty {
            emptyState(model.tab, ready: model.opened.contains(model.tab))
        } else if model.tab == .media {
            mediaGrid(items)
        } else {
            list(items)
        }
    }

    // MARK: - Медиа

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)
    }

    private func mediaGrid(_ items: [GalleryEntry]) -> some View {
        GeometryReader { geo in
            let side = (geo.size.width - 4) / 3
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(items) { entry in
                        GalleryThumbView(entry: entry, side: side)
                            .frame(width: side, height: side)
                            .clipped()
                            .contentShape(Rectangle())
                            .onTapGesture { open(entry) }
                            .contextMenu { menu(entry) }
                            .onAppear { model.loadMoreIfNeeded(.media, at: entry) }
                    }
                }
                .padding(.horizontal, 1)
            }
            .accessibilityIdentifier("gallery.grid")
        }
    }

    // MARK: - Списки

    private func list(_ items: [GalleryEntry]) -> some View {
        List(items) { entry in
            row(entry)
                .contentShape(Rectangle())
                .onTapGesture { open(entry) }
                .listRowBackground(Color.clear)
                .contextMenu { menu(entry) }
                .onAppear { model.loadMoreIfNeeded(model.tab, at: entry) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityIdentifier("gallery.list")
    }

    @ViewBuilder
    private func row(_ entry: GalleryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(entry))
                .font(Theme.glyph(17, max: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: TypeScale.scaled(38, max: 52), height: TypeScale.scaled(38, max: 52))
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.primary(entry))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(Self.secondary(entry))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }

    private func icon(_ entry: GalleryEntry) -> String {
        switch entry.kind {
        case .voice: return voice.playingMsgId == entry.messageId ? "pause.fill" : "play.fill"
        case .text: return "link"
        default: return "doc.fill"
        }
    }

    private static func primary(_ entry: GalleryEntry) -> String {
        switch entry.kind {
        case .voice: return duration(entry.media?.dur ?? 0)
        case .text: return entry.link.map(host) ?? ""
        default: return entry.media?.name ?? "Файл"
        }
    }

    private static func secondary(_ entry: GalleryEntry) -> String {
        let date = dateLabel(entry.sentAt)
        switch entry.kind {
        case .voice: return date
        case .text: return entry.linkContext ?? date
        default:
            let size = ByteCountFormatter.string(fromByteCount: Int64(entry.media?.size ?? 0),
                                                 countStyle: .file)
            return size + " · " + date
        }
    }

    private static func host(_ link: String) -> String {
        URL(string: link)?.host.map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 } ?? link
    }

    private static func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d", value / 60, value % 60)
    }

    static func dateLabel(_ sentAt: Double) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "ru_RU")
        fmt.dateFormat = Calendar.current.isDate(Date(timeIntervalSince1970: sentAt),
                                                 equalTo: Date(), toGranularity: .year)
            ? "d MMMM" : "d MMMM yyyy"
        return fmt.string(from: Date(timeIntervalSince1970: sentAt))
    }

    // MARK: - Действия

    @ViewBuilder
    private func menu(_ entry: GalleryEntry) -> some View {
        Button {
            showInChat(entry)
        } label: {
            Label("Показать в чате", systemImage: "bubble.left.and.text.bubble.right")
        }
        if let link = entry.link {
            Button {
                UIPasteboard.general.string = link
            } label: {
                Label("Скопировать ссылку", systemImage: "doc.on.doc")
            }
        }
    }

    /// Открытие записи: фото и видео — в просмотрщике, файл — в QuickLook,
    /// голосовое играет на месте, ссылка открывается во встроенном браузере.
    private func open(_ entry: GalleryEntry) {
        if let link = entry.link, let url = URL(string: link) {
            WebPresenter.present(url)
            return
        }
        Haptics.light()
        Task {
            guard let msg = await model.message(entry) else { return }
            switch entry.kind {
            case .file:
                FilePreviewPresenter.present(message: msg)
            case .voice:
                playVoice(msg)
            default:
                MediaViewerPresenter.present(message: msg, startIndex: entry.index)
            }
        }
    }

    private func playVoice(_ msg: Message) {
        guard let media = msg.media else { return }
        Task {
            guard let mm = AppState.shared.media, let url = try? await mm.fetch(media) else { return }
            VoicePlayer.shared.toggle(msgId: msg.msgId ?? msg.id, url: url)
        }
    }

    /// Переход к сообщению: экран галереи и инфо о чате закрываются, лента
    /// доезжает до баббла (догрузив историю, если он глубже окна).
    private func showInChat(_ entry: GalleryEntry) {
        Haptics.light()
        MessageJump.request(chatId: chatId, msgId: entry.messageId)
    }

    // MARK: - Пустые вкладки

    private func emptyState(_ tab: GalleryTab, ready: Bool) -> some View {
        VStack(spacing: 8) {
            if ready {
                Image(systemName: Self.emptyIcon(tab))
                    .font(.system(size: 32))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text(Self.emptyText(tab))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("gallery.empty")
    }

    static func title(_ tab: GalleryTab) -> String {
        switch tab {
        case .media: return "Медиа"
        case .files: return "Файлы"
        case .voice: return "Голосовые"
        case .links: return "Ссылки"
        }
    }

    static func emptyText(_ tab: GalleryTab) -> String {
        switch tab {
        case .media: return "Фото и видео этого чата собираются здесь"
        case .files: return "Файлы этого чата собираются здесь"
        case .voice: return "Голосовые сообщения этого чата собираются здесь"
        case .links: return "Ссылки из переписки собираются здесь"
        }
    }

    private static func emptyIcon(_ tab: GalleryTab) -> String {
        switch tab {
        case .media: return "photo.on.rectangle"
        case .files: return "doc"
        case .voice: return "waveform"
        case .links: return "link"
        }
    }
}

/// Квадрат сетки: blurhash сразу, потом картинка из кэша или скачанная.
private struct GalleryThumbView: View {
    let entry: GalleryEntry
    let side: CGFloat
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if let placeholder = blurhash {
                Image(uiImage: placeholder)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: entry.kind == .video ? "film" : "photo")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            if entry.kind == .video {
                VStack {
                    Spacer()
                    HStack(spacing: 3) {
                        Image(systemName: "play.fill").font(Theme.glyph(9, max: 13))
                        if let dur = entry.media?.dur {
                            Text(Self.duration(dur)).textRole(Theme.Text.thumbnailCaption)
                        }
                        Spacer()
                    }
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                    .padding(5)
                }
            }
        }
        .task(id: entry.id) { await load() }
    }

    private var blurhash: UIImage? {
        guard let bh = entry.media?.blurhash,
              let px = BlurHash.decodePixels(bh, width: 32, height: 32) else { return nil }
        return UIImage.fromRGBA(px, width: 32, height: 32)
    }

    /// У видео превью — отдельный блоб; у фото картинка сама. Уже показанное в
    /// ленте лежит в кэше, остальное скачивается по мере прокрутки.
    private func load() async {
        guard let media = entry.media, let mm = AppState.shared.media else { return }
        let source: MediaInfo = {
            guard media.type == "video",
                  media.thumbMediaId != nil || media.thumbLocalPath != nil else { return media }
            var thumb = MediaInfo(type: "photo", mediaId: media.thumbMediaId ?? "",
                                  key: media.thumbKey ?? "", hash: media.thumbHash ?? "",
                                  size: 0, mime: "image/jpeg")
            thumb.localPath = media.thumbLocalPath
            return thumb
        }()
        guard let url = try? await mm.fetch(source) else { return }
        let scale = UIScreen.main.scale
        let cg = await ImagePipeline.shared.image(
            at: url, targetPixelSize: CGSize(width: side * scale, height: side * scale))
        guard let cg else { return }
        await MainActor.run { image = UIImage(cgImage: cg) }
    }

    private static func duration(_ seconds: Double) -> String {
        let value = Int(seconds.rounded())
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}

/// Ссылка открывается во встроенном браузере: приложение остаётся на экране.
@MainActor
enum WebPresenter {
    static func present(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let top = TopViewController.current() else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = UIColor(Theme.accent)
        top.present(safari, animated: true)
    }
}
