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
    @State private var reactionRoster: ReactionRosterRequest?
    @State private var editHistoryMessage: Message?
    @State private var messagesVC = MessagesViewController()
    @EnvironmentObject var app: AppState
    @ObservedObject private var theme = ThemeStore.shared
    @Environment(\.dismiss) private var dismiss

    /// Esc walks back out: first the feed walk, then the edit, then the
    /// reply, then the chat itself.
    private func escapeWalksBack() {
        if messagesVC.clearKeyWalk() {
            // the walk is over; nothing else moves
        } else if model.editing != nil {
            withAnimation(Theme.springFast) { model.editing = nil }
        } else if model.replyingTo != nil {
            withAnimation(Theme.springFast) { model.replyingTo = nil }
        } else {
            dismiss()
        }
    }

    /// Cmd+↑: your newest own text message goes into the edit mode.
    private func editLastFromKeyboard() {
        guard let msg = messagesVC.lastOwnEditableMessage else { return }
        withAnimation(Theme.springFast) { model.editing = msg }
    }

    /// The composer's Ctrl+Tab / Cmd+[ ] name a direction; this screen adds
    /// which chat is being left, and the list does the swap.
    private func performChatSwitch(forward: Bool) {
        NotificationCenter.default.post(name: .chatSwitchPerform, object: nil,
                                        userInfo: ["chatId": model.chatId,
                                                   "forward": forward])
    }

    /// A hidden button takes Esc while nothing holds the keyboard; the focused
    /// composer forwards its own Esc through `.chatEscapePressed` instead.
    private var escapeShortcut: some View {
        Button("") { escapeWalksBack() }
            .keyboardShortcut(.cancelAction)
            .opacity(0)
            .accessibilityHidden(true)
    }

    init(chatId: String) {
        self.chatId = chatId
        _model = StateObject(wrappedValue: ChatViewModel(chatId: chatId))
        _search = StateObject(wrappedValue: ChatSearchSession(chatId: chatId))
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.chatBackground.ignoresSafeArea()
            // the chat's shader background, this device's own choice; it runs
            // only while the chat is in front
            if let background = surfaces.backgrounds[chatId] {
                // transparent, so the theme background stays under it while
                // the program compiles instead of a black flash on first open
                ShaderCanvasView(document: background, running: backgroundRunning, transparent: true, deviceInputs: true, priority: .background)
                    .ignoresSafeArea()
                    .id(background)
                    .accessibilityIdentifier("chat.shaderBackground")
            }
            VStack(spacing: 0) {
                // pending request: a profile card with the two buttons stands in for the feed
                if model.contentHidden {
                    requestCard
                        .transition(.dissolve)
                } else {
                  VStack(spacing: 0) {
                    if searching { searchHeader }
                    if !model.pinnedMessages.isEmpty, !searching {
                        pinnedBar
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
                    } else if !model.canSend {
                        readOnlyNote
                    } else {
                        InputBar(model: model, text: $text,
                                 onAttachPhoto: { photoPickerPresented = true },
                                 onAttachFile: { showFilePicker = true },
                                 onAttachShader: { shaderComposer = .message },
                                 onAttachSticker: { showStickers = true },
                                 onAttachBubbleShader: { shaderComposer = .bubble },
                                 onSendVoice: sendVoice,
                                 onSendImages: { images, caption in
                                     Task { await sendImages(images, caption: caption) }
                                 },
                                 onArrowKey: { up in messagesVC.moveKeyWalk(up: up) },
                                 onEmptyReturn: {
                                     guard let msg = messagesVC.keyWalkMessage else { return false }
                                     withAnimation(Theme.springFast) { model.replyingTo = msg }
                                     messagesVC.clearKeyWalk()
                                     return true
                                 })
                    }
                  }
                  .transition(.opacity)
                }
            }
            .animation(Theme.spring, value: model.contentHidden)
            if !model.selecting {
                scrollDownButton
                mentionJumpButton
            }
            // the fade dissolves bubbles running under the navigation bar; while
            // searching the bar is gone and the field stands in its own row
            if !searching { headerFade }
        }
        .navigationBarTitleDisplayMode(.inline)
        // the back button stays the system one. A leading item of our own in its
        // place left the list's bar in the pushed state on the way back — no
        // large title, both its glyphs washed out until the list was scrolled
        // (docs/qa/runs/2026-08-20-nav-bar/)
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
                ToolbarItem(placement: .principal) { header }
                if !model.contentHidden {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button { openSearch() } label: {
                            // the same colour as the back chevron beside it: the two
                            // header glyphs are one pair, and an accented one of them
                            // reads as the active control
                            Image(systemName: "magnifyingglass")
                                .font(Theme.glyph(17, max: 24))
                                .foregroundStyle(Color.primary)
                        }
                        .accessibilityLabel(String(localized: "Search this chat"))
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
            if let request = MessageJump.take(chatId: chatId) {
                // the reader came for one particular message; the stored reading
                // position yields to it
                model.suppressRestore()
                jump(to: request.id)
            }
        }
        // chat loads asynchronously and is still nil in onAppear, so the draft goes
        // in once the chat has actually arrived (and still only into an empty field)
        .onChange(of: model.chat?.id) { _, _ in
            if text.isEmpty, let draft = model.chat?.draft { text = draft }
        }
        // entering with nothing unread returns the feed to where the reader left
        // off; an explicit jump request (search) outranks it
        .onChange(of: model.restoreSeq) { _, seq in
            guard let seq else { return }
            if messagesVC.scrollTo(seq: seq, highlight: false, animated: false) { return }
            Task {
                guard await model.ensureLoaded(seq: seq) else { return }
                MessagesView.scrollWhenReady(vc: messagesVC, seq: seq, highlight: false)
            }
        }
        // back into the field from a match: the matches are what the reader wants
        // to see again
        .onChange(of: searchFocused) { _, focused in
            if focused { search.resultsShown = true }
        }
        .onDisappear {
            let draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
            model.saveDraft(draft.isEmpty ? nil : draft, immediately: true)
            // where the reader stood; nil at the bottom clears the stored position
            model.saveReadingPosition(messagesVC.readingPositionSeq())
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
        .background(escapeShortcut)
        .modifier(ChatKeyNotifications(onEscape: escapeWalksBack,
                                       onEditLast: editLastFromKeyboard,
                                       onSwitch: performChatSwitch))
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
        .sheet(item: $shaderComposer) { purpose in
            ShaderComposerScreen(purpose: purpose) { document in
                switch purpose {
                case .message: sendShader(document)
                case .bubble: withAnimation(Theme.springFast) { model.pendingBubbleShader = document }
                case .background: surfaces.setBackground(document, for: chatId)
                default: break
                }
            }
        }
        .sheet(isPresented: $showStickers) {
            StickerPanelSheet { document in sendSticker(document) }
        }
        .onAppear { backgroundRunning = true }
        .onDisappear { backgroundRunning = false }
        // palette change: bubble colours are read in the cell's configure, so force a reload
        .onReceive(NotificationCenter.default.publisher(for: .paletteChanged)) { _ in
            guard messagesVC.isViewLoaded else { return }
            messagesVC.collectionView.reloadData()
        }
        .sheet(item: $reactionRoster) { request in
            ReactionRosterSheet(sections: ReactionRoster.sections(
                reactions: request.message.reactions, users: model.members,
                tapped: request.emoji))
        }
        .sheet(item: $editHistoryMessage) { msg in
            EditHistorySheet(message: msg)
        }
        .sheet(isPresented: $showCalendar) {
            ChatCalendarSheet(chatId: chatId) { id in
                jump(to: id)
            }
        }
        .sheet(isPresented: $showPinList) {
            pinListSheet
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
        .onReceive(NotificationCenter.default.publisher(for: .editHistoryRequested)) { note in
            editHistoryMessage = note.object as? Message
        }
        // from the attachment gallery: the screens above the feed close and the feed
        // travels to the message, loading history first if it sits deeper than the window
        .onReceive(NotificationCenter.default.publisher(for: .showMessageInChat)) { note in
            guard let request = note.object as? MessageJump, request.chatId == chatId else { return }
            _ = MessageJump.take(chatId: chatId)
            jump(to: request.id)
        }
        .alert(String(localized: "Not sent"), isPresented: sendFailureBinding) {
            Button(String(localized: "OK"), role: .cancel) { model.sendFailure = nil }
        } message: {
            Text(model.sendFailure ?? "")
        }
    }

    private var sendFailureBinding: Binding<Bool> {
        Binding(get: { model.sendFailure != nil },
                set: { if !$0 { model.sendFailure = nil } })
    }

    private var deleteConfirmBar: some View {
        VStack(spacing: 8) {
            Text(String(localized: "Delete") + " " + MessageSelection.title(count: model.selection.count) + "?")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.canDeleteSelectedForAll {
                Button(String(localized: "Delete all"), role: .destructive) {
                    withAnimation(Theme.springFast) { model.deleteSelected(forAll: true) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier("chat.delete.forAll")
            }
            Button(String(localized: "Delete from me"), role: .destructive) {
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

    private var selectionActionBar: some View {
        HStack(spacing: 0) {
            selectionAction(String(localized: "Delete"), icon: "trash", destructive: true) {
                withAnimation(Theme.springFast) { model.confirmingDelete = true }
            }
            selectionAction(String(localized: "Forward"), icon: "arrowshape.turn.up.right") {
                forwardingSelection = true
            }
            selectionAction(String(localized: "Copy"), icon: "doc.on.doc") {
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
    /// the shader composer, open for a message, a bubble or the background
    @State private var shaderComposer: ShaderComposerPurpose?
    @State private var showStickers = false
    @ObservedObject private var surfaces = ShaderSurfaces.shared
    /// the background animates while the chat is the screen in front
    @State private var backgroundRunning = false
    @State private var showChatInfo = false
    /// the calendar over the history, opened from a date separator or the
    /// floating day capsule
    @State private var showCalendar = false
    /// the sheet with every pinned message, opened from the bar's list button
    @State private var showPinList = false

    private var messagesList: MessagesView {
        MessagesView(vc: messagesVC, model: model, items: model.feed,
                     sendTick: model.sendTick,
                     selecting: model.selecting, selectedIds: model.selection.ids,
                     onTapMedia: { (msg: Message, idx: Int, view: UIView) in
                         MediaViewerPresenter.present(message: msg, startIndex: idx, from: view)
                     },
                     onTapShader: { (msg: Message) in
                         if let document = msg.shader { ShaderPlayerPresenter.present(document: document) }
                     },
                     showScrollDown: $showScrollDown,
                     onSwipeBack: { dismiss() },
                     onCapsuleTap: { msg, emoji in
                         if model.chat?.kind == .group {
                             reactionRoster = ReactionRosterRequest(message: msg, emoji: emoji)
                         } else {
                             model.react(msg, emoji: emoji)
                         }
                     },
                     onDateTap: { showCalendar = true })
    }

    /// Empty chat: a centred hint instead of a bare background.
    private var emptyChatHint: some View {
        VStack(spacing: 8) {
            Image(systemName: model.isSavedChat ? AvatarStyle.savedGlyph : "bubble.left.and.bubble.right")
                .font(Theme.glyph(34, max: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(model.isSavedChat
                 ? String(localized: "Notes to yourself")
                 : String(localized: "Start a conversation"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Label(String(localized: "End-to-end encrypted"), systemImage: "lock.fill")
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
                                   && (model.peer?.online ?? false),
                           glyph: model.avatarGlyph)
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
                        .foregroundStyle(model.headerSubtitleAccented ? Theme.accent : .secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .animation(.easeInOut(duration: 0.15), value: model.headerSubtitle)
                }
            }
            // the feed runs under the bar, so the name needs a ground of its own:
            // without it the bubbles show through the title the way they do through
            // no other control in the bar
            .padding(.leading, 5)
            .padding(.trailing, 12)
            .padding(.vertical, 3)
            .background(.regularMaterial, in: Capsule())
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
    private var searchHeader: some View {
        HStack(spacing: 8) {
            ChatSearchField(text: $search.query, focused: $searchFocused)
            Button(String(localized: "Cancel")) { closeSearch() }
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
        if messagesVC.scrollTo(id: anchor, animated: false) { return }
        Task {
            guard await model.ensureLoaded(id: anchor) else { return }
            MessagesView.scrollWhenReady(vc: messagesVC, id: anchor, highlight: false)
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
        if messagesVC.scrollTo(id: hit.id, highlight: true) { return }
        jump(to: hit.id)
    }

    /// Carries the feed to a message: the screens above it close and history is
    /// loaded if the message sits deeper than the window.
    private func jump(to id: String) {
        showChatInfo = false
        PerfTrace.shared.mark("jump.begin")
        Task {
            guard await model.ensureLoaded(id: id) else {
                Haptics.rigid()
                return
            }
            PerfTrace.shared.mark("jump.loaded")
            MessagesView.scrollWhenReady(vc: messagesVC, id: id)
        }
    }

    /// One bar for any number of pins: it shows the focused pin (the newest
    /// after every change), a tap jumps to it and walks the focus to the
    /// previous one, wrapping at the oldest. With several pins the segmented
    /// rail counts them and the list button opens them all.
    private var pinnedBar: some View {
        let msgs = model.pinnedMessages
        let idx = min(model.pinnedFocus, msgs.count - 1)
        let msg = msgs[idx]
        return HStack(spacing: 8) {
            VStack(spacing: 2) {
                ForEach(msgs.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i == idx ? Theme.accent : Theme.accent.opacity(0.3))
                        .frame(width: 3)
                }
            }
            .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(msgs.count > 1
                     ? String(localized: "Pinned message \(idx + 1) of \(msgs.count)")
                     : String(localized: "Pinned message"))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text(ChatViewModel.previewText(msg))
                    .font(.footnote)
                    .lineLimit(1)
            }
            Spacer()
            if msgs.count > 1 {
                Button {
                    showPinList = true
                } label: {
                    Image(systemName: "list.bullet").font(.footnote).foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("chat.pins.list")
            } else {
                Button {
                    model.unpin(msg)
                } label: {
                    Image(systemName: "xmark").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture {
            // the pin can sit deeper than the window: the jump loads history
            // first; the next tap goes to the previous pin
            jump(to: msg.id)
            model.pinnedFocus = idx > 0 ? idx - 1 : msgs.count - 1
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Every pinned message at once; a row jumps, its button unpins.
    private var pinListSheet: some View {
        NavigationStack {
            List(model.pinnedMessages.reversed()) { msg in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ChatViewModel.previewText(msg))
                            .font(.subheadline)
                            .lineLimit(2)
                        Text(Date(timeIntervalSince1970: msg.sentAt), style: .time)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        model.unpin(msg)
                    } label: {
                        Image(systemName: "pin.slash").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    showPinList = false
                    jump(to: msg.id)
                }
            }
            .navigationTitle(String(localized: "Pinned messages"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
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
                    Text(model.peer?.displayName ?? String(localized: "User"))
                        .font(.title3.weight(.semibold))
                    if let username = model.peer?.username, !username.isEmpty {
                        Text("@" + username)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(String(localized: "wants to write to you"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Label(String(localized: "Messages will be revealed after confirmation"), systemImage: "eye.slash")
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
                    Text(String(localized: "Accept")).fontWeight(.semibold).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("request.accept")
                Button(role: .destructive) {
                    model.blockRequest()
                    dismiss()
                } label: {
                    Text(String(localized: "Block")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                // a destructive action carries its own colour: the app accent
                // painted it orange-on-brown in the dark appearance
                .tint(.red)
                .controlSize(.large)
                .accessibilityIdentifier("request.block")
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var keyChangeBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "The safety code has changed"))
                    .font(.footnote.weight(.semibold))
                Text(String(localized: "Message delivery has stopped until you accept the new key"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(String(localized: "Accept")) {
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

    private var readOnlyNote: some View {
        Text(String(localized: "Only admins can write to this group"))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.bar)
            .accessibilityIdentifier("chat.readOnly")
    }

    /// A message leaving the feed dissolves into the header instead of being cut by it.
    private var headerFade: some View {
        HeaderFade(tone: Theme.chatBackground)
            .ignoresSafeArea()
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

    /// The «@» button above the way down: unread messages mention you, a tap
    /// lands the feed on the earliest of them.
    private var mentionJumpButton: some View {
        Group {
            if let mentions = model.unreadMentions {
                Button {
                    MessageJump.request(chatId: chatId, id: mentions.earliestId)
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Text("@")
                            .font(Theme.glyph(17, max: 24).weight(.semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: TypeScale.scaled(40, max: 54),
                                   height: TypeScale.scaled(40, max: 54))
                            .background(.regularMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
                        if mentions.count > 1 {
                            Text("\(mentions.count)")
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
                .padding(.bottom, 68 + TypeScale.scaled(40, max: 54) + 10)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .transition(.scale.combined(with: .opacity))
                .accessibilityIdentifier("chat.mentionJump")
            }
        }
        .animation(Theme.springFast, value: model.unreadMentions?.count)
    }

    // MARK: - Sending attachments

    /// Retries until the operation succeeds: a picked attachment never
    /// disappears from the chat and never raises an alert over a preparation
    /// failure — only how long it takes to get there is in question, the same
    /// rule the outbox already follows once a message is queued.
    private func retrying<T>(_ label: String, _ operation: @escaping () async -> T?) async -> T {
        var delaySeconds: UInt64 = 1
        while true {
            if let result = await operation() { return result }
            MsngrLog.outbox.error("\(label) failed, retrying in \(delaySeconds)s")
            try? await Task.sleep(nanoseconds: delaySeconds * 1_000_000_000)
            delaySeconds = min(delaySeconds * 2, 30)
        }
    }

    private static func blankPhoto() -> MediaInfo {
        MediaInfo(type: "photo", mediaId: "", key: "", hash: "", size: 0, mime: "image/jpeg")
    }

    /// One pick is one message: a row with a typed placeholder per item goes
    /// into the chat before the library has handed over a single byte, and
    /// every slot fills in on its own timeline. Photos and videos share the
    /// album; a video's export progress goes to the tile as it runs.
    private func sendPicked(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        let kinds: [PickedBatch.Item] = items.map {
            $0.supportedContentTypes.contains { $0.conforms(to: .movie) } ? .video : .photo
        }
        let clientMsgId = UUID().uuidString
        let kind = PickedBatch.kind(of: kinds)
        let blanks = PickedBatch.blanks(for: kinds)
        let isAlbum = kind == .album
        await model.beginMedia(clientMsgId: clientMsgId, kind: kind, text: nil,
                               media: isAlbum ? nil : blanks[0], album: isAlbum ? blanks : nil)

        let finals = await withTaskGroup(of: (Int, MediaInfo).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask {
                    let slot = isAlbum ? index : nil
                    switch kinds[index] {
                    case .video:
                        let movie = await retrying("load picked video") {
                            try? await item.loadTransferable(type: VideoTransferable.self)
                        }
                        return (index, await processVideo(url: movie.url, clientMsgId: clientMsgId, index: slot))
                    case .photo:
                        let media = await processPhotoSource({ try? await item.loadTransferable(type: Data.self) },
                                                             clientMsgId: clientMsgId, index: slot)
                        return (index, media)
                    }
                }
            }
            var finals = blanks
            for await (index, media) in group { finals[index] = media }
            return finals
        }

        var c = ContentPayload(kind: kind.rawValue)
        if isAlbum { c.album = finals } else { c.media = finals[0] }
        try? await app.engine.finalizeMedia(chatId: chatId, clientMsgId: clientMsgId, content: c)
    }

    /// Images pasted from the clipboard take the same path as ones chosen in the picker.
    private func sendImages(_ images: [UIImage], caption: String) async {
        guard !images.isEmpty else { return }
        let sources: [() async -> Data?] = images.map { image in { image.jpegData(compressionQuality: 0.95) } }
        await sendPhotoSources(sources, caption: caption.isEmpty ? nil : caption)
    }

    /// One row appears the instant the selection is known — a blurred tile per
    /// source, in a frame of default aspect — and every tile fills in on its
    /// own timeline as its data loads and compresses. The row is queued for
    /// sending only once every tile is ready, since an album travels as one
    /// `album: [MediaInfo]`.
    private func sendPhotoSources(_ sources: [() async -> Data?], caption: String?) async {
        let clientMsgId = UUID().uuidString
        let isAlbum = sources.count > 1
        await model.beginMedia(clientMsgId: clientMsgId, kind: isAlbum ? .album : .photo, text: caption,
                               media: isAlbum ? nil : Self.blankPhoto(),
                               album: isAlbum ? Array(repeating: Self.blankPhoto(), count: sources.count) : nil)

        let finals = await withTaskGroup(of: (Int, MediaInfo).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let media = await processPhotoSource(source, clientMsgId: clientMsgId,
                                                          index: isAlbum ? index : nil)
                    return (index, media)
                }
            }
            var finals = Array(repeating: Self.blankPhoto(), count: sources.count)
            for await (index, media) in group { finals[index] = media }
            return finals
        }

        var c = ContentPayload(kind: isAlbum ? "album" : "photo")
        c.text = caption
        if isAlbum { c.album = finals } else { c.media = finals.first }
        try? await app.engine.finalizeMedia(chatId: chatId, clientMsgId: clientMsgId, content: c)
    }

    /// One picked photo, quick pass then heavy pass. `index` is the album slot
    /// to update, nil for a single-photo send.
    private func processPhotoSource(_ source: @escaping () async -> Data?, clientMsgId: String,
                                    index: Int?) async -> MediaInfo {
        func publish(_ media: MediaInfo) async {
            if let index {
                try? await app.engine.updateAlbumItemPreview(clientMsgId: clientMsgId, index: index, media: media)
            } else {
                try? await app.engine.updateMediaPreview(clientMsgId: clientMsgId, media: media, album: nil)
            }
        }

        let data = await retrying("load picked photo") { await source() }
        var info = Self.blankPhoto()

        // quick pass: a fast BlurHash and its own thumbnail's aspect stand in
        // for the real preview while the heavy pass below is still running
        if let px = ImageProcessor.rgbaPixels(data) {
            info.blurhash = BlurHash.encode(pixels: px.pixels, width: px.width, height: px.height)
            info.w = px.width
            info.h = px.height
            await publish(info)
        }

        // an animated GIF travels as it came: the JPEG pass keeps one frame, and
        // one frame is not what was sent
        if ImageProcessor.isAnimatedGIF(data) {
            info.mime = "image/gif"
            if let size = ImageProcessor.pixelSize(data) {
                info.w = Int(size.width)
                info.h = Int(size.height)
            }
            info.size = data.count
            info.localPath = await retrying("stash gif") { try? app.media.stash(data, mime: "image/gif") }
            await publish(info)
            return info
        }

        // heavy pass: compress for sending and stash to disk — gating steps,
        // retried until they succeed
        let prepared = await retrying("compress photo") { ImageProcessor.prepareForSending(data) }
        let localName = await retrying("stash photo") { try? app.media.stash(prepared.data, mime: "image/jpeg") }
        info.localPath = localName
        info.size = prepared.data.count
        info.w = Int(prepared.size.width)
        info.h = Int(prepared.size.height)
        await publish(info)
        return info
    }

    /// One picked video, quick pass then the transcode. `index` is the album
    /// slot to update, nil for a single-video send. The transcode is the long
    /// part of a send, so its progress goes to the tile as the first half of
    /// the ring; the upload fills the second.
    private func processVideo(url: URL, clientMsgId: String, index: Int?) async -> MediaInfo {
        func publish(_ media: MediaInfo) async {
            if let index {
                try? await app.engine.updateAlbumItemPreview(clientMsgId: clientMsgId, index: index, media: media)
            } else {
                try? await app.engine.updateMediaPreview(clientMsgId: clientMsgId, media: media, album: nil)
            }
        }
        let asset = AVURLAsset(url: url)
        var info = PickedBatch.blankVideo()

        // quick pass: the track's real aspect, a poster frame and its BlurHash —
        // all far cheaper than the transcode below, so the bubble firms up long
        // before the video itself is ready to send
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let size = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            let real = CGRect(origin: .zero, size: size).applying(transform)
            info.w = Int(abs(real.width))
            info.h = Int(abs(real.height))
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        if let cg = try? gen.copyCGImage(at: .init(seconds: 0.1, preferredTimescale: 600), actualTime: nil) {
            if info.w == nil { info.w = cg.width; info.h = cg.height }
            let ui = UIImage(cgImage: cg)
            if let jpeg = ui.jpegData(compressionQuality: 0.7) {
                if let px = ImageProcessor.rgbaPixels(jpeg) {
                    info.blurhash = BlurHash.encode(pixels: px.pixels, width: px.width, height: px.height)
                }
                // the thumbnail is optional: without it the video goes out with the blurhash alone
                info.thumbLocalPath = try? app.media.stash(jpeg, mime: "image/jpeg")
            }
        }
        await publish(info)

        // heavy pass: compress into a progressive mp4 — a gating step, retried until it succeeds
        let progress = MediaProgress.shared
        let data: Data = await retrying("export video") {
            guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else { return nil }
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("v-\(UUID().uuidString).mp4")
            export.outputURL = out
            export.outputFileType = .mp4
            export.shouldOptimizeForNetworkUse = true // faststart
            // the session reports its progress only when asked, so it is asked
            // a few times a second for as long as it runs
            let poll = Task {
                while !Task.isCancelled {
                    progress.set(clientMsgId, index: index, fraction: Double(export.progress) * 0.5)
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            await export.export()
            poll.cancel()
            defer { try? FileManager.default.removeItem(at: out) }
            guard export.status == .completed else { return nil }
            return try? Data(contentsOf: out)
        }
        progress.set(clientMsgId, index: index, fraction: 0.5)
        let localName = await retrying("stash video") { try? app.media.stash(data, mime: "video/mp4") }
        info.localPath = localName
        info.size = data.count
        if let d = try? await asset.load(.duration) { info.dur = d.seconds }
        await publish(info)
        try? FileManager.default.removeItem(at: url)
        return info
    }

    /// Puts the attachment's source file into a permanent folder. nil means the write
    /// failed, and the user hears about it from an alert: an attachment dropped
    /// silently would look like nothing had happened.
    private func stash(_ data: Data, mime: String? = nil) -> String? {
        do {
            return try app.media.stash(data, mime: mime)
        } catch {
            MsngrLog.outbox.error("failed to stash attachment: \(error)")
            model.sendFailure = String(localized: "Attachment not sent: could not save to device")
            return nil
        }
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

    /// A shader is text-sized and needs no upload: the document goes straight
    /// into the send queue.
    private func sendShader(_ document: ShaderDocument) {
        var c = ContentPayload(kind: "shader")
        c.shader = document
        model.enqueue(c)
        Haptics.light()
    }

    private func sendSticker(_ document: ShaderDocument) {
        var c = ContentPayload(kind: "sticker")
        c.shader = document
        model.enqueue(c)
        Haptics.light()
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
    var onTapShader: (Message) -> Void
    @Binding var showScrollDown: Bool
    var onSwipeBack: () -> Void
    var onCapsuleTap: (Message, String) -> Void
    var onDateTap: () -> Void

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
        vc.onTapShader = onTapShader
        // tapping a quote jumps to the original; if it lies deeper than the loaded
        // page, history is fetched first
        vc.onTapReplyQuote = { [weak model, weak vc] msg in
            guard let vc, let targetSeq = msg.replyTo?.seq else { return }
            if vc.scrollTo(seq: targetSeq, highlight: true) { return }
            guard let model else { return }
            Task {
                guard await model.ensureLoaded(seq: targetSeq) else {
                    Haptics.rigid()   // the original is out of reach
                    return
                }
                Self.scrollWhenReady(vc: vc, seq: targetSeq)
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
            case .editHistory: NotificationCenter.default.post(name: .editHistoryRequested, object: msg)
            case .pin: model.pin(msg)
            case .unpin: model.unpin(msg)
            case .forward: NotificationCenter.default.post(name: .forwardRequested, object: msg)
            case .select: withAnimation(Theme.springFast) { model.beginSelection(with: msg) }
            case .resend: model.resend(msg)
            case .setBackground:
                if let doc = msg.shader {
                    ShaderSurfaces.shared.setBackground(doc, for: msg.chatId)
                    Haptics.success()
                }
            case .saveSticker:
                if let doc = msg.shader {
                    ShaderSurfaces.shared.addSticker(doc)
                    Haptics.success()
                }
            case .delete:
                withAnimation(Theme.springFast) {
                    model.beginSelection(with: msg, confirmingDelete: true)
                }
            }
        }
        vc.onSwipeBack = onSwipeBack
        vc.onReactionCapsuleTap = onCapsuleTap
        vc.onDateTap = onDateTap
        vc.pinnedSeqs = Set(model.chat?.pinnedSeqs ?? [])
        vc.ownUserId = model.ownUserId
        vc.noteSendTick(sendTick)
        vc.apply(items)
        vc.setSelection(mode: selecting, ids: selectedIds)
    }

    /// Fetched history reaches the list through updateUIViewController, so the scroll
    /// happens as soon as the message shows up in the feed. The jump from the gallery
    /// arrives the same way, only there the screens on top have to close first.
    static func scrollWhenReady(vc: MessagesViewController, id: String,
                                highlight: Bool = true, attempts: Int = 16) {
        if vc.scrollTo(id: id, highlight: highlight) { return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scrollWhenReady(vc: vc, id: id, highlight: highlight, attempts: attempts - 1)
        }
    }

    /// Same, for a target a quote names by seq.
    static func scrollWhenReady(vc: MessagesViewController, seq: Int,
                                highlight: Bool = true, attempts: Int = 16) {
        if vc.scrollTo(seq: seq, highlight: highlight) { return }
        guard attempts > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            scrollWhenReady(vc: vc, seq: seq, highlight: highlight, attempts: attempts - 1)
        }
    }
}

extension Notification.Name {
    static let forwardRequested = Notification.Name("forwardRequested")
    static let editHistoryRequested = Notification.Name("editHistoryRequested")
}

/// The composer's hardware-key notifications, gathered off the screen's body:
/// the chain of onReceive closures inline was what pushed the body past the
/// type-checker's time budget.
private struct ChatKeyNotifications: ViewModifier {
    let onEscape: () -> Void
    let onEditLast: () -> Void
    let onSwitch: (Bool) -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .chatEscapePressed)) { _ in
                onEscape()
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatEditLastRequested)) { _ in
                onEditLast()
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatSwitchRequested)) { note in
                guard let forward = note.userInfo?["forward"] as? Bool else { return }
                onSwitch(forward)
            }
    }
}
