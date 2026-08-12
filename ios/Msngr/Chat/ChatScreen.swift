import SwiftUI
import PhotosUI
import AVFoundation
import MsngrCore

struct ChatScreen: View {
    let chatId: String
    @StateObject private var model: ChatViewModel
    @State private var text = ""
    @State private var showScrollDown = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    @State private var forwardMessage: Message?
    @State private var viewerMedia: (Message, Int)?
    @State private var messagesVC = MessagesViewController()
    @EnvironmentObject var app: AppState

    init(chatId: String) {
        self.chatId = chatId
        _model = StateObject(wrappedValue: ChatViewModel(chatId: chatId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                if let pinned = model.pinnedMessage {
                    pinnedBar(pinned)
                }
                MessagesView(vc: messagesVC, model: model,
                             onTapMedia: { msg, idx, _ in viewerMedia = (msg, idx) },
                             showScrollDown: $showScrollDown)
                if model.keyChangePending {
                    keyChangeBanner
                }
                if model.chat?.isRequest == true {
                    requestBanner
                } else {
                    InputBar(model: model, text: $text,
                             onAttachPhoto: { photoPickerPresented = true },
                             onAttachFile: { showFilePicker = true },
                             onSendVoice: sendVoice)
                }
            }
            scrollDownButton
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
        }
        .onAppear {
            model.start()
            // черновик восстанавливаем только в пустое поле: при возврате из ChatInfo
            // набранный текст остаётся в @State и не должен затираться
            if text.isEmpty { text = model.chat?.draft ?? "" }
            NotificationCoordinator.shared.activeChatId = chatId
        }
        // chat грузится асинхронно: в onAppear он ещё nil — черновик заливаем,
        // когда чат реально появился (и только в пустое поле)
        .onChange(of: model.chat?.id) { _, _ in
            if text.isEmpty, let draft = model.chat?.draft { text = draft }
        }
        .onDisappear {
            let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.saveDraft(draft.isEmpty ? nil : draft)
            // push вглубь (ChatInfo) — не рвём подписку и не сбрасываем активный чат,
            // иначе при возврате лента мертва, а пуши этого чата показываются баннером
            guard !showChatInfo else { return }
            model.stop()
            NotificationCoordinator.shared.activeChatId = nil
        }
        .navigationDestination(isPresented: $showChatInfo) {
            ChatInfoView(model: model)
        }
        .onChange(of: model.editing?.id) { _, _ in
            // смена редактируемого сообщения (в т.ч. edit A → edit B) — поле показывает его текст
            if let e = model.editing { text = e.text ?? "" }
        }
        .photosPicker(isPresented: $photoPickerPresented, selection: $photoItems,
                      maxSelectionCount: 10, matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPicked(items) }
        }
        .fileImporter(isPresented: $showFilePicker, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result {
                Task { await sendFile(url) }
            }
        }
        .sheet(item: $forwardMessage) { msg in
            ForwardPickerView { targetChatId in
                model.forward(msg, to: targetChatId)
                forwardMessage = nil
            }
        }
        .fullScreenCover(isPresented: Binding(get: { viewerMedia != nil },
                                              set: { if !$0 { viewerMedia = nil } })) {
            if let (msg, idx) = viewerMedia {
                MediaViewerView(message: msg, startIndex: idx)
            }
        }
    }

    @State private var photoPickerPresented = false
    @State private var showChatInfo = false

    private var header: some View {
        Button {
            showChatInfo = true
        } label: {
            HStack(spacing: 8) {
                AvatarView(name: model.headerTitle,
                           avatarId: model.chat?.kind == .group ? model.chat?.avatarId : model.peer?.avatarId,
                           online: model.peer?.online ?? false)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.headerTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(model.headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(model.headerSubtitle.contains("печатает") || model.headerSubtitle == "в сети"
                                         ? Theme.accent : .secondary)
                        .lineLimit(1)
                        .animation(.easeInOut(duration: 0.15), value: model.headerSubtitle)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func pinnedBar(_ msg: Message) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.accent).frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Закреплённое сообщение")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(ChatViewModel.previewText(msg))
                    .font(.footnote)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                model.pin(nil)
            } label: {
                Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .onTapGesture {
            if let id = msg.msgId ?? msg.clientMsgId {
                messagesVC.scrollTo(msgId: id)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var requestBanner: some View {
        VStack(spacing: 10) {
            Text("\(model.peer?.displayName ?? "Пользователь") хочет вам написать")
                .font(.subheadline)
            HStack(spacing: 12) {
                Button("Заблокировать", role: .destructive) {
                    Task {
                        if let peer = model.peer {
                            try? await app.api.setBlocked(peer.id, blocked: true)
                        }
                    }
                }
                .buttonStyle(.bordered)
                Button("Принять") {
                    withAnimation(Theme.spring) { model.acceptRequest() }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// TOFU-баннер: ключ собеседника сменился, исходящие заблокированы.
    private var keyChangeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Код безопасности изменился")
                    .font(.footnote.weight(.semibold))
                Text("Сообщения не отправляются, пока вы не примете новый ключ")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Принять") {
                withAnimation(Theme.springFast) { model.acceptKeyChange() }
            }
            .font(.footnote.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var scrollDownButton: some View {
        Group {
            if showScrollDown {
                Button {
                    messagesVC.scrollToBottom()
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        if let unread = model.chat?.unreadCount, unread > 0 {
                            Text("\(unread)")
                                .font(.caption2.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 17, minHeight: 17)
                                .background(Theme.accent, in: Capsule())
                                .offset(x: 4, y: -4)
                        }
                    }
                }
                .padding(.trailing, 10)
                .padding(.bottom, 68)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(Theme.springFast, value: showScrollDown)
    }

    // MARK: - Отправка вложений

    private func sendPicked(_ items: [PhotosPickerItem]) async {
        var photos: [(Data, CGSize, String)] = [] // (jpeg, size, blurhash)
        for item in items {
            if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                if let movie = try? await item.loadTransferable(type: VideoTransferable.self) {
                    await sendVideo(movie.url)
                }
            } else if let data = try? await item.loadTransferable(type: Data.self),
                      let prepared = ImageProcessor.prepareForSending(data) {
                let bh = ImageProcessor.rgbaPixels(prepared.data).flatMap {
                    BlurHash.encode(pixels: $0.pixels, width: $0.width, height: $0.height)
                } ?? ""
                photos.append((prepared.data, prepared.size, bh))
            }
        }
        guard !photos.isEmpty else { return }

        // без сети не теряется: файл в постоянную папку, аплоад делает outbox-воркер
        var infos: [MediaInfo] = []
        for (jpeg, size, bh) in photos {
            guard let localName = try? app.media.stash(jpeg, mime: "image/jpeg") else { continue }
            var info = MediaInfo(type: "photo", mediaId: "", key: "",
                                 hash: "", size: jpeg.count, mime: "image/jpeg")
            info.localPath = localName
            info.w = Int(size.width)
            info.h = Int(size.height)
            info.blurhash = bh
            infos.append(info)
        }
        guard !infos.isEmpty else { return }
        if infos.count == 1 {
            var c = ContentPayload(kind: "photo")
            c.media = infos[0]
            try? await app.engine.enqueue(content: c, chatId: chatId)
        } else {
            var c = ContentPayload(kind: "album")
            c.album = infos
            try? await app.engine.enqueue(content: c, chatId: chatId)
        }
    }

    private func sendVideo(_ url: URL) async {
        // компрессия в прогрессивный mp4 + превью-кадр
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true // faststart
        await export.export()
        guard export.status == .completed, let data = try? Data(contentsOf: out),
              let localName = try? app.media.stash(data, mime: "video/mp4") else { return }

        // превью-кадр
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        var thumbLocal: String?
        var blurhash = ""
        var dims = CGSize(width: 16, height: 9)
        if let cg = try? gen.copyCGImage(at: .init(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
            dims = CGSize(width: cg.width, height: cg.height)
            let ui = UIImage(cgImage: cg)
            if let jpeg = ui.jpegData(compressionQuality: 0.7) {
                thumbLocal = try? app.media.stash(jpeg, mime: "image/jpeg")
                if let px = ImageProcessor.rgbaPixels(jpeg) {
                    blurhash = BlurHash.encode(pixels: px.pixels, width: px.width, height: px.height) ?? ""
                }
            }
        }
        var info = MediaInfo(type: "video", mediaId: "", key: "",
                             hash: "", size: data.count, mime: "video/mp4")
        info.localPath = localName
        info.thumbLocalPath = thumbLocal
        info.w = Int(dims.width)
        info.h = Int(dims.height)
        if let d = try? await asset.load(.duration) { info.dur = d.seconds }
        info.blurhash = blurhash
        var c = ContentPayload(kind: "video")
        c.media = info
        try? await app.engine.enqueue(content: c, chatId: chatId)
        try? FileManager.default.removeItem(at: out)
    }

    private func sendFile(_ url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 100_000_000 else { return }
        guard let localName = try? app.media.stash(data) else { return }  // файл: расширение не критично
        var info = MediaInfo(type: "file", mediaId: "", key: "",
                             hash: "", size: data.count,
                             mime: "application/octet-stream")
        info.localPath = localName
        info.name = url.lastPathComponent
        var c = ContentPayload(kind: "file")
        c.media = info
        try? await app.engine.enqueue(content: c, chatId: chatId)
    }

    private func sendVoice(_ url: URL, duration: TimeInterval, waveform: [Int]) {
        Task {
            guard let data = try? Data(contentsOf: url),
                  let localName = try? app.media.stash(data, mime: "audio/mp4") else { return }
            var info = MediaInfo(type: "voice", mediaId: "", key: "",
                                 hash: "", size: data.count, mime: "audio/mp4")
            info.localPath = localName
            info.dur = duration
            info.waveform = waveform
            var c = ContentPayload(kind: "voice")
            c.media = info
            try? await app.engine.enqueue(content: c, chatId: chatId)
            try? FileManager.default.removeItem(at: url)
        }
    }
}

struct VideoTransferable: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { transferable in
            SentTransferredFile(transferable.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("in-\(UUID().uuidString).mov")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return VideoTransferable(url: copy)
        }
    }
}

/// Обёртка UIKit-списка сообщений.
struct MessagesView: UIViewControllerRepresentable {
    let vc: MessagesViewController
    let model: ChatViewModel
    var onTapMedia: (Message, Int, UIView) -> Void
    @Binding var showScrollDown: Bool

    func makeUIViewController(context: Context) -> MessagesViewController {
        vc.onVisibleTopChanged = { [weak model] show in
            if showScrollDown != show { showScrollDown = show }
            // проскроллено вверх → новейшие не видны → не отмечаем прочтение
            model?.isViewingBottom = !show
            if !show { model?.markVisibleRead() }
        }
        vc.onNeedOlder = { [weak model] in model?.loadOlder() }
        vc.onReply = { [weak model] msg in
            withAnimation(Theme.springFast) { model?.replyingTo = msg }
        }
        vc.onReact = { [weak model] msg, emoji in model?.react(msg, emoji: emoji) }
        vc.onTapMedia = onTapMedia
        vc.onContextAction = { [weak model] msg, action in
            guard let model else { return }
            switch action {
            case .reply: withAnimation(Theme.springFast) { model.replyingTo = msg }
            case .copy: UIPasteboard.general.string = msg.text
            case .edit: withAnimation(Theme.springFast) { model.editing = msg }
            case .pin: model.pin(msg)
            case .forward: NotificationCenter.default.post(name: .forwardRequested, object: msg)
            case .deleteForMe: model.delete(msg, forAll: false)
            case .deleteForAll: model.delete(msg, forAll: true)
            }
        }
        return vc
    }

    func updateUIViewController(_ vc: MessagesViewController, context: Context) {
        vc.apply(model.feed)
    }
}

extension Notification.Name {
    static let forwardRequested = Notification.Name("forwardRequested")
}
