import SwiftUI
import PhotosUI
import AVFoundation
import MsngrCore

struct ChatScreen: View {
    let chatId: String
    @StateObject private var model: ChatViewModel
    /// Search inside this chat: the field in the header, the matches over the feed.
    @StateObject private var search: ChatSearchSession
    @State private var searching = false
    @FocusState private var searchFocused: Bool
    /// The message the reader was looking at when search opened; nil means they
    /// were at the end of the conversation.
    @State private var searchReturn: String?
    /// A match was actually opened, so leaving search has somewhere to go back from.
    @State private var searchMoved = false
    @State private var text = ""
    /// What stood in the field before the edit mode took it over. Leaving the mode,
    /// by the cross or by sending the edit, puts it back.
    @State private var textBeforeEdit: String?
    @State private var showScrollDown = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showFilePicker = false
    @State private var forwardMessage: Message?
    @State private var forwardingSelection = false
    @State private var messagesVC = MessagesViewController()
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss

    init(chatId: String) {
        self.chatId = chatId
        _model = StateObject(wrappedValue: ChatViewModel(chatId: chatId))
        _search = StateObject(wrappedValue: ChatSearchSession(chatId: chatId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.chatBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                // pending request: a profile card with the two buttons stands in for the feed
                if model.contentHidden {
                    requestCard
                } else {
                    if searching { searchHeader }
                    if let pinned = model.pinnedMessage, !searching {
                        pinnedBar(pinned)
                    }
                    messagesList
                        // the feed runs under the header: a message leaving it
                        // dissolves in its band instead of breaking off at the
                        // edge. The feed's insets are still counted from the safe
                        // area, so at rest the messages stay below the header
                        .ignoresSafeArea(.container, edges: .top)
                        .overlay {
                            if model.chat != nil, model.feed.isEmpty {
                                emptyChatHint
                            }
                        }
                        .overlay {
                            if searching, search.resultsShown, !search.query.isEmpty {
                                searchResults
                            }
                        }
                    if model.keyChangePending && !model.selecting && !searching {
                        keyChangeBanner
                    }
                    if model.selecting {
                        if model.confirmingDelete {
                            deleteConfirmBar
                        } else {
                            selectionActionBar
                        }
                    } else if searching {
                        ChatSearchMatchBar(session: search, onStep: stepSearch,
                                           onShowList: { search.resultsShown = true })
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
            // the fade dissolves bubbles running under the navigation bar; while
            // searching the bar is gone and the field stands in its own row
            if !searching { headerFade }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        // the search field lives in the screen itself: focus does not reach a text
        // field hosted by the navigation bar, and the keyboard has to come up with it
        .toolbar(searching ? .hidden : .visible, for: .navigationBar)
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
            } else if !searching {
                // own button instead of the system one: going back is the header's
                // primary action and has to read before anything else in it
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.backward")
                            // the size of the other bar button: the chevron leads
                            // the header by position, not by being twice as big
                            .font(Theme.glyph(17, max: 19).weight(.medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Назад")
                    .accessibilityIdentifier("chat.back")
                }
                ToolbarItem(placement: .principal) { header }
                if !model.contentHidden {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { openSearch() } label: {
                            Image(systemName: "magnifyingglass")
                                .font(Theme.glyph(17, max: 24))
                        }
                        .accessibilityLabel("Поиск по чату")
                        .accessibilityIdentifier("chat.search.open")
                    }
                }
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
        // back into the field from a match: the matches are what the reader wants
        // to see again
        .onChange(of: searchFocused) { _, focused in
            if focused { search.resultsShown = true }
        }
        .onDisappear {
            let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.saveDraft(draft.isEmpty ? nil : draft)
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
            if let e = model.editing {
                // entering the mode, and switching which message is edited (A → B),
                // puts its text in the field; the draft that stood there waits
                if textBeforeEdit == nil { textBeforeEdit = text }
                text = e.text ?? ""
            } else {
                text = textBeforeEdit ?? ""
                textBeforeEdit = nil
            }
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
    }

    private var sendFailureBinding: Binding<Bool> {
        Binding(get: { model.sendFailure != nil },
                set: { if !$0 { model.sendFailure = nil } })
    }

    /// Подтверждение удаления: два действия внизу, сами сообщения видны и
    /// к выбору можно добавить ещё.
    private var deleteConfirmBar: some View {
        VStack(spacing: 8) {
            Text("Удалить " + MessageSelection.title(count: model.selection.count) + "?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.canDeleteSelectedForAll {
                Button("Удалить у всех", role: .destructive) {
                    withAnimation(Theme.springFast) { model.deleteSelected(forAll: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat.delete.forAll")
            }
            Button("Удалить у меня", role: .destructive) {
                withAnimation(Theme.springFast) { model.deleteSelected(forAll: false) }
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("chat.delete.forMe")
        }
        .disabled(model.selection.isEmpty)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    /// Multi-select action bar shown in place of the composer.
    private var selectionActionBar: some View {
        HStack(spacing: 0) {
            selectionAction("Удалить", icon: "trash", destructive: true) {
                withAnimation(Theme.springFast) { model.confirmingDelete = true }
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
                     sendTick: model.sendTick,
                     selecting: model.selecting, selectedIds: model.selection.ids,
                     onTapMedia: { (msg: Message, idx: Int, _: UIView) in
                         MediaViewerPresenter.present(message: msg, startIndex: idx)
                     },
                     showScrollDown: $showScrollDown,
                     onSwipeBack: { dismiss() })
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
                           // a group has no presence of its own, and with no
                           // connection presence is stale: the subtitle already
                           // says so, the dot must not claim otherwise
                           online: model.chat?.kind == .direct && model.connected
                                   && (model.peer?.online ?? false))
                    // the back chevron leads the header, so the avatar stays under it
                    .frame(width: 34, height: 34)
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
        .accessibilityIdentifier("chat.header")
    }

    /// Shortens a header string with an ellipsis to the width the principal view has
    /// (the screen minus the bar buttons, the avatar and the padding).
    private static func fitted(_ s: String, font: UIFont) -> String {
        // the bar keeps 16pt outside a 44pt button and the principal view is
        // centred, so that side costs it twice; 20pt more keeps the title clear
        // of the button's glass, and the avatar with its gap comes off the rest
        let side: CGFloat = 16 + 44 + 20
        let avatar: CGFloat = 34 + 8
        let maxWidth = UIScreen.main.bounds.width - side * 2 - avatar
        guard s.size(withAttributes: [.font: font]).width > maxWidth else { return s }
        var t = s
        while !t.isEmpty, (t + "…").size(withAttributes: [.font: font]).width > maxWidth {
            t.removeLast()
        }
        return t + "…"
    }

    // MARK: - Search inside the chat

    /// The header while the chat is being searched: the field takes the row it
    /// can, with only «Отмена» beside it.
    private var searchHeader: some View {
        HStack(spacing: 8) {
            ChatSearchField(text: $search.query, focused: $searchFocused)
            Button("Отмена") { closeSearch() }
                .textRole(Theme.Text.body)
                .tint(Theme.accent)
                .accessibilityIdentifier("chat.search.cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var searchResults: some View {
        ChatSearchResultsList(session: search, members: model.members,
                              ownUserId: model.ownUserId) { hit in
            search.select(hit)
            searchFocused = false
            show(hit)
        }
        .transition(.opacity)
    }

    /// Opening search remembers where the reader is, so that leaving it can put
    /// them back even after a walk through the whole conversation.
    private func openSearch() {
        searchReturn = messagesVC.topVisibleMessageId()
        searchMoved = false
        withAnimation(Theme.springFast) { searching = true }
    }

    /// Leaving search: the query goes, and the feed returns to the message the
    /// reader came from. Nothing is fetched for that — search only ever grew the
    /// window, so the message is still in it.
    private func closeSearch() {
        searchFocused = false
        withAnimation(Theme.springFast) { searching = false }
        search.reset()
        let anchor = searchReturn
        searchReturn = nil
        guard searchMoved else { return }
        searchMoved = false
        guard let anchor else {
            messagesVC.scrollToBottom(animated: false)
            return
        }
        if messagesVC.scrollTo(msgId: anchor, animated: false) { return }
        Task {
            guard await model.ensureLoaded(msgId: anchor) else { return }
            MessagesView.scrollWhenReady(vc: messagesVC, msgId: anchor, highlight: false)
        }
    }

    /// One step through the matches, back in time or towards the end.
    private func stepSearch(by offset: Int) {
        Task {
            guard let hit = await search.step(by: offset) else {
                Haptics.rigid()
                return
            }
            searchFocused = false
            show(hit)
        }
    }

    /// Shows a found message. A match already in the window costs a scroll and
    /// nothing else; only one that sits deeper makes the feed load history.
    private func show(_ hit: MessageSearchHit) {
        searchMoved = true
        if messagesVC.scrollTo(msgId: hit.messageId, highlight: true) { return }
        jump(to: hit.messageId)
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

    /// A message leaving the feed dissolves into the header instead of being cut by it.
    private var headerFade: some View {
        HeaderFade(tone: Theme.chatBackground)
            .ignoresSafeArea()
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
            }
        }
        .animation(Theme.springFast, value: showScrollDown)
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
    /// the count of our own sends, passed by value for the same reason as the feed
    let sendTick: Int
    /// selection mode and contents are passed by value for the same reason as the feed
    let selecting: Bool
    let selectedIds: Set<String>
    var onTapMedia: (Message, Int, UIView) -> Void
    @Binding var showScrollDown: Bool
    /// свайп от левой кромки: возврат к списку чатов
    var onSwipeBack: () -> Void

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
        // a status bar tap: to the start of the chat, loading everything the device holds
        vc.onScrollToStart = { [weak model, weak vc] in
            guard let model, let vc else { return }
            Haptics.light()
            Task {
                await model.loadDeviceHistory()
                // the window arrives through the database observation, so the feed gets it
                // a moment later; on a chat of tens of thousands that moment is seconds,
                // and scrolling before it lands leaves the reader in the middle
                for _ in 0..<160 {
                    if model.isAtDeviceStart { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                vc.scrollToStart()
            }
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
            case .edit: withAnimation(Theme.springFast) { model.editing = msg }
            case .pin: model.pin(msg)
            case .forward: NotificationCenter.default.post(name: .forwardRequested, object: msg)
            case .select: withAnimation(Theme.springFast) { model.beginSelection(with: msg) }
            // удаление начинается с выбора: сообщение видно, к нему можно
            // добавить ещё, подтверждение стоит внизу
            case .delete:
                withAnimation(Theme.springFast) {
                    model.beginSelection(with: msg, confirmingDelete: true)
                }
            }
        }
        // замыкание с dismiss живёт не дольше тела body — переустанавливаем
        vc.onSwipeBack = onSwipeBack
        vc.noteSendTick(sendTick)
        vc.apply(items)
        vc.setSelection(mode: selecting, ids: selectedIds)
    }

    /// Fetched history reaches the list through updateUIViewController, so the scroll
    /// happens as soon as the message shows up in the feed. The jump from the gallery
    /// arrives the same way, only there the screens on top have to close first.
    static func scrollWhenReady(vc: MessagesViewController, msgId: String,
                                highlight: Bool = true, attempts: Int = 16) {
        if vc.scrollTo(msgId: msgId, highlight: highlight) { return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scrollWhenReady(vc: vc, msgId: msgId, highlight: highlight, attempts: attempts - 1)
        }
    }
}

extension Notification.Name {
    static let forwardRequested = Notification.Name("forwardRequested")
}
