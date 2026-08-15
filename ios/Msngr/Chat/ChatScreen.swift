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
    /// сообщение, для которого открыт режим выделения текста
    @State private var selectingText: Message?
    /// сообщение, для которого спрошено подтверждение удаления
    @State private var deleteCandidate: Message?
    /// подтверждение удаления выбранных в мультивыборе
    @State private var confirmDeleteSelection = false
    @State private var forwardingSelection = false
    @State private var messagesVC = MessagesViewController()
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss

    init(chatId: String) {
        self.chatId = chatId
        _model = StateObject(wrappedValue: ChatViewModel(chatId: chatId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // заявка до принятия: вместо ленты карточка с профилем и кнопками
                if model.contentHidden {
                    requestCard
                } else {
                    if let pinned = model.pinnedMessage {
                        pinnedBar(pinned)
                    }
                    messagesList
                        .overlay {
                            if model.chat != nil, model.feed.isEmpty {
                                emptyChatHint
                            }
                        }
                    if model.keyChangePending && !model.selecting {
                        keyChangeBanner
                    }
                    if model.selecting {
                        selectionActionBar
                    } else {
                        InputBar(model: model, text: $text,
                                 onAttachPhoto: { photoPickerPresented = true },
                                 onAttachFile: { showFilePicker = true },
                                 onSendVoice: sendVoice,
                                 onSendImages: { images, caption in
                                     Task { await sendImages(images, caption: caption) }
                                 })
                    }
                }
            }
            if !model.selecting { scrollDownButton }
            headerFade
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            if model.selecting {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(Theme.springFast) { model.endSelection() }
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("chat.selection.close")
                }
                ToolbarItem(placement: .principal) {
                    Text(MessageSelection.title(count: model.selection.count))
                        .font(.system(size: 16, weight: .semibold))
                        .accessibilityIdentifier("chat.selection.count")
                }
            } else {
                // своя кнопка вместо системной: возврат — главное действие шапки,
                // и оно должно читаться раньше остальных её элементов
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Назад")
                    .accessibilityIdentifier("chat.back")
                }
                ToolbarItem(placement: .principal) { header }
            }
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
        // смена палитры: цвета бабблов читаются в configure ячеек — форсируем reload
        .onReceive(NotificationCenter.default.publisher(for: .paletteChanged)) { _ in
            guard messagesVC.isViewLoaded else { return }
            messagesVC.collectionView.reloadData()
        }
        .sheet(item: $forwardMessage) { msg in
            ForwardPickerView { targetChatId in
                model.forward(msg, to: targetChatId)
                forwardMessage = nil
            }
        }
        .sheet(isPresented: $forwardingSelection) {
            ForwardPickerView { targetChatId in
                model.forwardSelected(to: targetChatId)
                forwardingSelection = false
            }
        }
        .sheet(item: $selectingText) { msg in
            TextSelectionView(text: msg.text ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .forwardRequested)) { note in
            forwardMessage = note.object as? Message
        }
        // из галереи вложений: экраны поверх ленты закрываются, лента доезжает
        // до сообщения — догрузив историю, если оно глубже окна
        .onReceive(NotificationCenter.default.publisher(for: .showMessageInChat)) { note in
            guard let jump = note.object as? MessageJump, jump.chatId == chatId else { return }
            showChatInfo = false
            Task {
                guard await model.ensureLoaded(msgId: jump.msgId) else {
                    Haptics.rigid()
                    return
                }
                MessagesView.scrollWhenReady(vc: messagesVC, msgId: jump.msgId)
            }
        }
        .alert("Не отправлено", isPresented: sendFailureBinding) {
            Button("Понятно", role: .cancel) { model.sendFailure = nil }
        } message: {
            Text(model.sendFailure ?? "")
        }
        // удаление одного сообщения из контекстного меню
        .confirmationDialog("Удалить сообщение?", isPresented: deleteCandidateBinding,
                            titleVisibility: .visible) {
            if deleteCandidate?.isOutgoing == true {
                Button("Удалить у всех", role: .destructive) {
                    if let msg = deleteCandidate { model.delete(msg, forAll: true) }
                    deleteCandidate = nil
                }
            }
            Button("Удалить у меня", role: .destructive) {
                if let msg = deleteCandidate { model.delete(msg, forAll: false) }
                deleteCandidate = nil
            }
            Button("Отмена", role: .cancel) { deleteCandidate = nil }
        }
        // удаление выбранных в мультивыборе
        .confirmationDialog(deleteSelectionTitle, isPresented: $confirmDeleteSelection,
                            titleVisibility: .visible) {
            if model.canDeleteSelectedForAll {
                Button("Удалить у всех", role: .destructive) {
                    withAnimation(Theme.springFast) { model.deleteSelected(forAll: true) }
                }
            }
            Button("Удалить у меня", role: .destructive) {
                withAnimation(Theme.springFast) { model.deleteSelected(forAll: false) }
            }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var sendFailureBinding: Binding<Bool> {
        Binding(get: { model.sendFailure != nil },
                set: { if !$0 { model.sendFailure = nil } })
    }

    private var deleteCandidateBinding: Binding<Bool> {
        Binding(get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } })
    }

    private var deleteSelectionTitle: String {
        "Удалить " + MessageSelection.title(count: model.selection.count) + "?"
    }

    /// Панель действий мультивыбора вместо поля ввода.
    private var selectionActionBar: some View {
        HStack(spacing: 0) {
            selectionAction("Удалить", icon: "trash", destructive: true) {
                confirmDeleteSelection = true
            }
            selectionAction("Переслать", icon: "arrowshape.turn.up.right") {
                forwardingSelection = true
            }
            selectionAction("Копировать", icon: "doc.on.doc") {
                withAnimation(Theme.springFast) { model.copySelected() }
            }
        }
        .padding(.top, 6)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    private func selectionAction(_ title: String, icon: String,
                                 destructive: Bool = false,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 20))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .tint(destructive ? .red : Theme.accent)
        .disabled(model.selection.isEmpty)
        .accessibilityIdentifier("chat.selection." + icon)
    }

    @State private var photoPickerPresented = false
    @State private var showChatInfo = false

    private var messagesList: MessagesView {
        MessagesView(vc: messagesVC, model: model, items: model.feed,
                     selecting: model.selecting, selectedIds: model.selection.ids,
                     onTapMedia: { (msg: Message, idx: Int, _: UIView) in
                         MediaViewerPresenter.present(message: msg, startIndex: idx)
                     },
                     selectingText: $selectingText, deleteCandidate: $deleteCandidate,
                     showScrollDown: $showScrollDown)
    }

    /// Пустой чат: центрированная подсказка вместо голого фона.
    private var emptyChatHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("Напишите первое сообщение")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Label("Сквозное шифрование", systemImage: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 24)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }

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
                    // тулбар может предложить principal-вью ширину меньше идеальной —
                    // короткое имя обрезается («4455…»). Текст держит идеальную ширину
                    // (fixedSize), а реально длинные строки заранее укорачиваются
                    // с многоточием под доступную ширину навбара
                    Text(Self.fitted(model.headerTitle,
                                     font: .systemFont(ofSize: 16, weight: .semibold)))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(Self.fitted(model.headerSubtitle, font: .systemFont(ofSize: 12)))
                        .font(.system(size: 12))
                        .foregroundStyle(model.headerSubtitle.contains("печатает") || model.headerSubtitle == "в сети"
                                         ? Theme.accent : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .animation(.easeInOut(duration: 0.15), value: model.headerSubtitle)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Укорачивает строку шапки с многоточием под ширину, доступную principal-вью
    /// (экран минус кнопка «назад», аватар и отступы).
    private static func fitted(_ s: String, font: UIFont) -> String {
        let maxWidth = UIScreen.main.bounds.width - 190
        guard s.size(withAttributes: [.font: font]).width > maxWidth else { return s }
        var t = s
        while !t.isEmpty, (t + "…").size(withAttributes: [.font: font]).width > maxWidth {
            t.removeLast()
        }
        return t + "…"
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
                messagesVC.scrollTo(msgId: id, highlight: true)
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Заявка до принятия: вместо ленты — профиль отправителя и решение.
    /// Сообщения уже лежат в БД, но на экран не попадают.
    private var requestCard: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                AvatarView(name: model.headerTitle, avatarId: model.peer?.avatarId)
                    .frame(width: 96, height: 96)
                VStack(spacing: 4) {
                    Text(model.peer?.displayName ?? "Пользователь")
                        .font(.title3.weight(.semibold))
                    if let username = model.peer?.username, !username.isEmpty {
                        Text("@" + username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("хочет вам написать")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label("Сообщения откроются после принятия", systemImage: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)
            Spacer()
            VStack(spacing: 10) {
                Button {
                    withAnimation(Theme.spring) { model.acceptRequest() }
                } label: {
                    Text("Принять").fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("request.accept")
                Button(role: .destructive) {
                    model.blockRequest()
                    dismiss()
                } label: {
                    Text("Заблокировать").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("request.block")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// Уходящее сообщение растворяется в шапке, а не обрезается об неё: тон фона
    /// набирается к верхнему краю на высоту шапки.
    private var headerFade: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                // до нижнего края шапки фон непрозрачен, дальше долгий спад:
                // короткий градиент режет баббл кромкой вместо растворения
                .init(color: Theme.chatBackground, location: 0),
                .init(color: Theme.chatBackground, location: 0.42),
                .init(color: Theme.chatBackground.opacity(0.75), location: 0.62),
                .init(color: Theme.chatBackground.opacity(0.3), location: 0.82),
                .init(color: Theme.chatBackground.opacity(0), location: 1),
            ], startPoint: .top, endPoint: .bottom)
                .frame(height: 150)
            Spacer()
        }
        .ignoresSafeArea(edges: .top)
        .allowsHitTesting(false)
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
        await sendPhotos(photos, caption: nil)
    }

    /// Вставленные из буфера картинки — тем же путём, что и выбранные в пикере.
    private func sendImages(_ images: [UIImage], caption: String) async {
        var photos: [(Data, CGSize, String)] = []
        for image in images {
            guard let data = image.jpegData(compressionQuality: 0.95),
                  let prepared = ImageProcessor.prepareForSending(data) else { continue }
            let bh = ImageProcessor.rgbaPixels(prepared.data).flatMap {
                BlurHash.encode(pixels: $0.pixels, width: $0.width, height: $0.height)
            } ?? ""
            photos.append((prepared.data, prepared.size, bh))
        }
        await sendPhotos(photos, caption: caption.isEmpty ? nil : caption)
    }

    private func sendPhotos(_ photos: [(Data, CGSize, String)], caption: String?) async {
        guard !photos.isEmpty else { return }

        // без сети не теряется: файл в постоянную папку, аплоад делает outbox-воркер
        var infos: [MediaInfo] = []
        for (jpeg, size, bh) in photos {
            guard let localName = stash(jpeg, mime: "image/jpeg") else { return }
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
            c.text = caption
            model.enqueue(c)
        } else {
            var c = ContentPayload(kind: "album")
            c.album = infos
            c.text = caption
            model.enqueue(c)
        }
    }

    /// Кладёт исходник вложения в постоянную папку. nil — отказ записи, о котором
    /// пользователь узнаёт из алерта: молча пропущенное вложение выглядело бы как
    /// «ничего не произошло».
    private func stash(_ data: Data, mime: String? = nil) -> String? {
        do {
            return try app.media.stash(data, mime: mime)
        } catch {
            MsngrLog.outbox.error("не удалось сохранить вложение: \(error)")
            model.sendFailure = "Вложение не отправлено: не удалось сохранить его на устройстве"
            return nil
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
              let localName = stash(data, mime: "video/mp4") else { return }

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
                // превью не критично: без него видео уходит с одним blurhash
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
        model.enqueue(c)
        try? FileManager.default.removeItem(at: out)
    }

    private func sendFile(_ url: URL) async {
        let secured = url.startAccessingSecurityScopedResource()
        defer { if secured { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url), data.count < 100_000_000 else { return }
        guard let localName = stash(data) else { return }  // файл: расширение не критично
        var info = MediaInfo(type: "file", mediaId: "", key: "",
                             hash: "", size: data.count,
                             mime: "application/octet-stream")
        info.localPath = localName
        info.name = url.lastPathComponent
        var c = ContentPayload(kind: "file")
        c.media = info
        model.enqueue(c)
    }

    private func sendVoice(_ url: URL, duration: TimeInterval, waveform: [Int]) {
        Task {
            guard let data = try? Data(contentsOf: url),
                  let localName = stash(data, mime: "audio/mp4") else { return }
            var info = MediaInfo(type: "voice", mediaId: "", key: "",
                                 hash: "", size: data.count, mime: "audio/mp4")
            info.localPath = localName
            info.dur = duration
            info.waveform = waveform
            var c = ContentPayload(kind: "voice")
            c.media = info
            model.enqueue(c)
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
    /// @ObservedObject обязателен: updateUIViewController вызывается по инвалидации
    /// самого MessagesView, а все его stored-поля — стабильные ссылки, SwiftUI без
    /// подписки на model считает view неизменным и не прокидывает новый feed в apply()
    @ObservedObject var model: ChatViewModel
    /// feed передаётся и значением: изменение массива меняет value представляемого
    /// view — SwiftUI гарантированно зовёт updateUIViewController
    let items: [ChatFeedItem]
    /// режим и состав выбора передаются значением по той же причине, что и feed
    let selecting: Bool
    let selectedIds: Set<String>
    var onTapMedia: (Message, Int, UIView) -> Void
    @Binding var selectingText: Message?
    @Binding var deleteCandidate: Message?
    @Binding var showScrollDown: Bool

    func makeUIViewController(context: Context) -> MessagesViewController {
        vc.onAtBottomChanged = { [weak model] atBottom in
            // самые новые сообщения не на экране → кнопка «вниз», прочтение не отмечаем
            if showScrollDown == atBottom { showScrollDown = !atBottom }
            model?.isViewingBottom = atBottom
            if atBottom { model?.markVisibleRead() }
        }
        vc.onNeedOlder = { [weak model] in model?.loadOlder() }
        vc.onReply = { [weak model] msg in
            withAnimation(Theme.springFast) { model?.replyingTo = msg }
        }
        vc.onReact = { [weak model] msg, emoji in model?.react(msg, emoji: emoji) }
        vc.onTapMedia = onTapMedia
        // тап по цитате — переход к оригиналу; если он глубже загруженной
        // страницы, сначала догружаем историю
        vc.onTapReplyQuote = { [weak model, weak vc] msg in
            guard let vc, let targetId = msg.replyTo?.msgId else { return }
            if vc.scrollTo(msgId: targetId, highlight: true) { return }
            guard let model else { return }
            Task {
                guard await model.ensureLoaded(msgId: targetId) else {
                    Haptics.rigid()   // оригинал недоступен
                    return
                }
                Self.scrollWhenReady(vc: vc, msgId: targetId)
            }
        }
        vc.onToggleSelection = { [weak model] msg in
            withAnimation(Theme.springFast) { model?.toggleSelection(msg) }
        }
        return vc
    }

    func updateUIViewController(_ vc: MessagesViewController, context: Context) {
        // колбэки с биндингами переустанавливаются на каждом апдейте: снимок
        // биндинга из makeUIViewController живёт дольше, чем породившее его тело
        vc.onContextAction = { [weak model] msg, action in
            guard let model else { return }
            switch action {
            case .reply: withAnimation(Theme.springFast) { model.replyingTo = msg }
            case .copy: MessageClipboard.copy(msg)
            case .selectText: selectingText = msg
            case .edit: withAnimation(Theme.springFast) { model.editing = msg }
            case .pin: model.pin(msg)
            case .forward: NotificationCenter.default.post(name: .forwardRequested, object: msg)
            case .select: withAnimation(Theme.springFast) { model.beginSelection(with: msg) }
            case .delete: deleteCandidate = msg
            }
        }
        vc.apply(items)
        vc.setSelection(mode: selecting, ids: selectedIds)
    }

    /// Догруженная история попадает в список через updateUIViewController —
    /// скроллим, как только сообщение появилось в ленте. Тем же путём доезжает
    /// переход из галереи: там ждать приходится ещё и закрытия экранов поверх.
    static func scrollWhenReady(vc: MessagesViewController, msgId: String, attempts: Int = 16) {
        if vc.scrollTo(msgId: msgId, highlight: true) { return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scrollWhenReady(vc: vc, msgId: msgId, attempts: attempts - 1)
        }
    }
}

extension Notification.Name {
    static let forwardRequested = Notification.Name("forwardRequested")
}
