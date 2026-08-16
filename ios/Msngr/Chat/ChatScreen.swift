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
    /// message whose text selection sheet is open
    @State private var selectingText: Message?
    /// message the delete confirmation is asked for
    @State private var deleteCandidate: Message?
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
                // pending request: a profile card with the two buttons stands in for the feed
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
                        .textRole(Theme.Text.headerTitle)
                        .accessibilityIdentifier("chat.selection.count")
                }
            } else {
                // own button instead of the system one: going back is the header's
                // primary action and has to read before anything else in it
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(Theme.glyph(22, max: 28).weight(.semibold))
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
            PerfTrace.shared.mark("chat.open")
            model.start()
            // the draft is restored only into an empty field: coming back from
            // ChatInfo the typed text is still in @State and must not be overwritten
            if text.isEmpty { text = model.chat?.draft ?? "" }
            NotificationCoordinator.shared.activeChatId = chatId
            // search opens the chat for one particular message; the request has been
            // waiting for this screen to appear
            if let request = MessageJump.take(chatId: chatId) { jump(to: request.msgId) }
        }
        // chat loads asynchronously and is still nil in onAppear, so the draft goes
        // in once the chat has actually arrived (and still only into an empty field)
        .onChange(of: model.chat?.id) { _, _ in
            if text.isEmpty, let draft = model.chat?.draft { text = draft }
        }
        .onDisappear {
            let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.saveDraft(draft.isEmpty ? nil : draft, immediately: true)
            // on a push deeper in (ChatInfo) the subscription stays and the active chat
            // is not cleared: otherwise the feed comes back dead and pushes from this
            // chat start showing up as banners
            guard !showChatInfo else { return }
            model.stop()
            NotificationCoordinator.shared.activeChatId = nil
        }
        .navigationDestination(isPresented: $showChatInfo) {
            ChatInfoView(model: model)
        }
        .onChange(of: model.editing?.id) { _, _ in
            // switching which message is edited (edit A → edit B included) puts its text in the field
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
        // palette change: bubble colours are read in the cell's configure, so force a reload
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
        // from the attachment gallery: the screens above the feed close and the feed
        // travels to the message, loading history first if it sits deeper than the window
        .onReceive(NotificationCenter.default.publisher(for: .showMessageInChat)) { note in
            guard let request = note.object as? MessageJump, request.chatId == chatId else { return }
            _ = MessageJump.take(chatId: chatId)
            jump(to: request.msgId)
        }
        .alert("Не отправлено", isPresented: sendFailureBinding) {
            Button("Понятно", role: .cancel) { model.sendFailure = nil }
        } message: {
            Text(model.sendFailure ?? "")
        }
        // deleting a single message from the context menu
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
        // deleting the messages picked in multi-select
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

    /// Multi-select action bar shown in place of the composer.
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
                Image(systemName: icon).font(Theme.glyph(20, max: 28))
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

    /// Empty chat: a centred hint instead of a bare background.
    private var emptyChatHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(Theme.glyph(34, max: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
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
                    // the toolbar can hand the principal view less than the ideal width,
                    // and even a short name gets truncated («4455…»). The text holds its
                    // ideal width (fixedSize), while genuinely long strings are shortened
                    // with an ellipsis up front to the width the nav bar has
                    Text(Self.fitted(model.headerTitle, font: Theme.Text.headerTitle.uiFont))
                        .textRole(Theme.Text.headerTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                    Text(Self.fitted(model.headerSubtitle, font: Theme.Text.headerSubtitle.uiFont))
                        .textRole(Theme.Text.headerSubtitle)
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

    /// Shortens a header string with an ellipsis to the width the principal view has
    /// (the screen minus the back button, the avatar and the padding).
    private static func fitted(_ s: String, font: UIFont) -> String {
        let maxWidth = UIScreen.main.bounds.width - 190
        guard s.size(withAttributes: [.font: font]).width > maxWidth else { return s }
        var t = s
        while !t.isEmpty, (t + "…").size(withAttributes: [.font: font]).width > maxWidth {
            t.removeLast()
        }
        return t + "…"
    }

    /// Carries the feed to a message: the screens above it close and history is
    /// loaded if the message sits deeper than the window.
    private func jump(to msgId: String) {
        showChatInfo = false
        PerfTrace.shared.mark("jump.begin")
        Task {
            guard await model.ensureLoaded(msgId: msgId) else {
                Haptics.rigid()
                return
            }
            PerfTrace.shared.mark("jump.loaded")
            MessagesView.scrollWhenReady(vc: messagesVC, msgId: msgId)
        }
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

    /// Pending request: the sender's profile and the decision instead of the feed.
    /// The messages are already in the database, they just never reach the screen.
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

    /// TOFU banner: the peer's key has changed, outgoing messages are blocked.
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

    /// A message scrolling away dissolves into the header instead of being clipped by
    /// it: the background tone builds up towards the top edge over the header's height.
    private var headerFade: some View {
        VStack(spacing: 0) {
            LinearGradient(stops: [
                // opaque down to the bottom edge of the header, then a long falloff:
                // a short gradient cuts the bubble with a visible edge instead of dissolving it
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
            // a window standing on a jump target has the newest messages above it, so
            // the way down is offered even when the loaded feed is scrolled to its end
            if showScrollDown || !model.atNewest {
                Button {
                    if model.atNewest {
                        messagesVC.scrollToBottom()
                    } else {
                        // the feed that arrives is a different stretch of the chat
                        model.returnToBottom()
                        messagesVC.showBottomOnNextUpdate()
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "chevron.down")
                            .font(Theme.glyph(17, max: 24).weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: TypeScale.scaled(40, max: 54),
                                   height: TypeScale.scaled(40, max: 54))
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
                .accessibilityIdentifier("chat.scrollDown")
            }
        }
        .animation(Theme.springFast, value: showScrollDown)
        .animation(Theme.springFast, value: model.atNewest)
    }

    // MARK: - Sending attachments

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

    /// Images pasted from the clipboard take the same path as ones chosen in the picker.
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

        // nothing is lost offline: the file goes to a permanent folder, the outbox worker uploads it
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

    /// Puts the attachment's source file into a permanent folder. nil means the write
    /// failed, and the user hears about it from an alert: an attachment dropped
    /// silently would look like nothing had happened.
    private func stash(_ data: Data, mime: String? = nil) -> String? {
        do {
            return try app.media.stash(data, mime: mime)
        } catch {
            MsngrLog.outbox.error("failed to stash attachment: \(error)")
            model.sendFailure = "Вложение не отправлено: не удалось сохранить его на устройстве"
            return nil
        }
    }

    private func sendVideo(_ url: URL) async {
        // compress into a progressive mp4, then take a poster frame
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).mp4")
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true // faststart
        await export.export()
        guard export.status == .completed, let data = try? Data(contentsOf: out),
              let localName = stash(data, mime: "video/mp4") else { return }

        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        var thumbLocal: String?
        var blurhash = ""
        var dims = CGSize(width: 16, height: 9)
        if let cg = try? gen.copyCGImage(at: .init(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
            dims = CGSize(width: cg.width, height: cg.height)
            let ui = UIImage(cgImage: cg)
            if let jpeg = ui.jpegData(compressionQuality: 0.7) {
                // the thumbnail is optional: without it the video goes out with the blurhash alone
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
        guard let localName = stash(data) else { return }  // a plain file: the extension does not matter
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

/// The UIKit message list wrapped for SwiftUI.
struct MessagesView: UIViewControllerRepresentable {
    let vc: MessagesViewController
    /// @ObservedObject is required: updateUIViewController runs when MessagesView itself
    /// is invalidated, and every stored field here is a stable reference, so without a
    /// subscription to the model SwiftUI sees an unchanged view and never hands the new
    /// feed to apply()
    @ObservedObject var model: ChatViewModel
    /// the feed is passed by value as well: changing the array changes the value of the
    /// represented view, so SwiftUI is guaranteed to call updateUIViewController
    let items: [ChatFeedItem]
    /// selection mode and contents are passed by value for the same reason as the feed
    let selecting: Bool
    let selectedIds: Set<String>
    var onTapMedia: (Message, Int, UIView) -> Void
    @Binding var selectingText: Message?
    @Binding var deleteCandidate: Message?
    @Binding var showScrollDown: Bool

    func makeUIViewController(context: Context) -> MessagesViewController {
        vc.onAtBottomChanged = { [weak model] atBottom in
            // newest messages off screen: show the scroll-down button, mark nothing read
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
        // tapping a quote jumps to the original; if it lies deeper than the loaded
        // page, history is fetched first
        vc.onTapReplyQuote = { [weak model, weak vc] msg in
            guard let vc, let targetId = msg.replyTo?.msgId else { return }
            if vc.scrollTo(msgId: targetId, highlight: true) { return }
            guard let model else { return }
            Task {
                guard await model.ensureLoaded(msgId: targetId) else {
                    Haptics.rigid()   // the original is out of reach
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
        // callbacks that capture bindings are reinstalled on every update: a binding
        // captured in makeUIViewController outlives the body that produced it
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

    /// Fetched history reaches the list through updateUIViewController, so the scroll
    /// happens as soon as the message shows up in the feed. The jump from the gallery
    /// arrives the same way, only there the screens on top have to close first.
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
