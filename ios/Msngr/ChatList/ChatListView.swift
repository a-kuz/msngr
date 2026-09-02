import SwiftUI
import MsngrCore

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ChatListView()
    }
}

/// The archive as a point on the navigation path; a chat is a String there, so
/// the archive needs a type of its own.
struct ArchiveRoute: Hashable {}

/// The calls list as a point on the navigation path.
struct CallsRoute: Hashable {}

/// Cmd+F moves focus into the search field where the system allows it;
/// on earlier systems the shortcut is simply inert.
private struct SearchFocusIfAvailable: ViewModifier {
    var focused: FocusState<Bool>.Binding
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.searchFocused(focused)
        } else {
            content
        }
    }
}

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = ChatListModel()
    @StateObject private var search = ChatSearchModel()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var showStoryComposer = false
    /// The author whose stories are being watched, if any.
    @State private var watchingStories: StoriesModel.Author?
    @ObservedObject private var stories = StoriesModel.shared
    /// The tray over the list is a row of small rings until the reader pulls
    /// the list down; a scroll up folds it again. The follower moves it with
    /// the finger.
    @StateObject private var tray = StoriesTrayFollower()
    /// The folder bar's measured height: with the tray's resting height it is
    /// the room the list keeps clear under the header.
    @State private var folderBarHeight: CGFloat = 0
    @State private var path = NavigationPath()
    /// chat whose deletion is waiting for confirmation
    @State private var deleteCandidate: ChatListItem?
    @State private var showFolders = false
    /// which way the list slides when the tab changes: forward along the bar or back
    @State private var slideForward = true
    /// folder opened for editing straight from the list
    @State private var editingFolder: ChatFolder?
    /// the row a hardware keyboard walks with the arrows; Enter opens it
    @State private var keySelection: String?
    @FocusState private var searchFocused: Bool

    private var deleteConfirmPresented: Binding<Bool> {
        Binding(get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } })
    }

    private var deleteTitle: String {
        guard let item = deleteCandidate else { return "" }
        return item.chat.kind == .group
            ? String(localized: "Leave group?")
            : String(localized: "Delete chat “\(item.title)”?")
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.searchText.isEmpty {
                    // the header is drawn over the list, inside the room the
                    // list keeps clear at its top: the list's frame then never
                    // changes under a finger, and its own bounce carries the
                    // tray open and shut
                    ZStack(alignment: .top) {
                        folderPages
                        VStack(spacing: 0) {
                            StoriesTray(progress: tray.progress,
                                        onCompose: { showStoryComposer = true },
                                        onOpen: { watchingStories = $0 })
                            // with no folders there are no tabs to show: the first
                            // folder is made from a row's context menu
                            if !model.folders.isEmpty {
                                ChatFolderBar(folders: model.folders, unread: model.folderUnread,
                                              selection: tabSelection,
                                              onManage: { showFolders = true },
                                              onEdit: { editingFolder = $0 })
                                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                                        folderBarHeight = $0
                                    }
                            }
                        }
                        .background(Color(.systemBackground))
                    }
                    // the list now stands right under the bottom search bar, and
                    // the soft edge the system gives a scroll view there fades a
                    // tall band of rows; the bar keeps to a strip with a hard edge
                    .scrollEdgeEffectStyle(.hard, for: .bottom)
                } else {
                    ChatSearchResults(list: model, search: search,
                                      ownUserId: app.session?.userId ?? "",
                                      onOpenMessage: openMessage,
                                      onOpenPerson: openPerson)
                }
            }
            // "we are on the chat list" is checked by this identifier rather
            // than by the title: the navigation title never reaches the
            // accessibility tree while the list is empty and an overlay covers it
            .accessibilityIdentifier("chatlist.root")
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $model.searchText, prompt: "Search")
            .modifier(SearchFocusIfAvailable(focused: $searchFocused))
            .background(keyShortcuts)
            // chats are filtered in place, messages and people are searched at their own pace
            .onChange(of: model.searchText) { _, text in
                model.updateSearch()
                search.update(text)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel(Text("Settings"))
                        .accessibilityIdentifier("chatlist.settings")
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { path.append(CallsRoute()) } label: { Image(systemName: "phone") }
                        .accessibilityLabel(Text("Calls"))
                        .accessibilityIdentifier("chatlist.calls")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(Text("New chat"))
                        .accessibilityIdentifier("chatlist.new")
                        .keyboardShortcut("n", modifiers: .command)
                }
            }
            .navigationDestination(for: String.self) { chatId in
                ChatScreen(chatId: chatId)
            }
            .navigationDestination(for: ArchiveRoute.self) { _ in
                ArchiveView(model: model)
            }
            .navigationDestination(for: CallsRoute.self) { _ in
                CallsListView()
            }
            .sheet(isPresented: $showNewChat) {
                NewChatView { chatId in
                    showNewChat = false
                    path.append(chatId)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .fullScreenCover(isPresented: $showStoryComposer) {
                StoryComposerView { _ in }
            }
            .fullScreenCover(item: $watchingStories) { author in
                StoryViewerView(authors: StoriesModel.shared.authors, start: author) { watchingStories = nil }
                    // the list shows through while the viewer is pulled down
                    .presentationBackground(.clear)
            }
            .sheet(isPresented: $showFolders) {
                ChatFoldersView(model: model)
            }
            .sheet(item: $editingFolder) { folder in
                ChatFolderEditorView(model: model, folder: folder)
            }
            .onAppear { model.start() }
            .onChange(of: app.ready) { _, ready in
                if ready { model.start() }
            }
            // a tap on a push or an in-app banner opens the chat
            .onReceive(NotificationCenter.default.publisher(for: .openChatRequested)) { note in
                guard let chatId = note.object as? String,
                      NotificationCoordinator.shared.activeChatId != chatId else { return }
                path.append(chatId)
            }
            // the chat was deleted from its own screen, so come back to the list
            .onReceive(NotificationCenter.default.publisher(for: .chatDeleted)) { _ in
                path = NavigationPath()
            }
            // Ctrl+Tab / Cmd+[ ] in the open chat: swap it for its neighbour
            // in the current tab, keeping whatever sits under it on the path
            .onReceive(NotificationCenter.default.publisher(for: .chatSwitchPerform)) { note in
                guard !path.isEmpty,
                      let chatId = note.userInfo?["chatId"] as? String,
                      let forward = note.userInfo?["forward"] as? Bool,
                      let target = Self.switchTarget(
                          from: chatId,
                          in: model.items(in: model.selectedFolderId).map { $0.chat.id },
                          forward: forward)
                else { return }
                path.removeLast()
                path.append(target)
                keySelection = target
            }
            .confirmationDialog(deleteTitle, isPresented: deleteConfirmPresented,
                                titleVisibility: .visible) {
                let isGroup = deleteCandidate?.chat.kind == .group
                Button(isGroup ? "Leave" : "Delete", role: .destructive) {
                    if let item = deleteCandidate { model.deleteChat(item) }
                    deleteCandidate = nil
                }
                Button("Cancel", role: .cancel) { deleteCandidate = nil }
            } message: {
                Text(deleteCandidate?.chat.kind == .group
                     ? "You will leave the group, and its messages will be deleted from this device."
                     : "The chat and its messages will be deleted from this device. The other person keeps the conversation.")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.decorativeGlyph)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("No chats")
                    .font(.title3.weight(.semibold))
                Text("Find someone by username\nor from your address book")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showNewChat = true
            } label: {
                Text("Start a conversation")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chatlist.empty.start")
        }
        .padding(.bottom, 40)
    }

    /// A paging scroll view is no good for switching tabs: its scrolling takes
    /// every horizontal movement for itself, and the row's swipe actions
    /// (archive, pin, delete) stop opening. Hence a gesture with a distance
    /// threshold instead.
    /// The bare-key navigation works only while the list itself is what the
    /// keyboard addresses: no chat pushed, no sheet up, no search in
    /// progress — otherwise Enter belongs to whatever is in front.
    private var keyNavigationActive: Bool {
        path.isEmpty && model.searchText.isEmpty && !showNewChat && !showSettings
            && !showFolders && editingFolder == nil && deleteCandidate == nil
    }

    /// Buttons that exist only for their shortcuts: a keyboardShortcut fires
    /// without focus, which is what a hardware keyboard expects of Cmd-keys —
    /// and, gated by `keyNavigationActive`, of the bare arrows too.
    private var keyShortcuts: some View {
        Group {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            // Cmd+1 is «Все», the folders follow in bar order
            ForEach(Array(([nil] + model.folders.map { Optional($0.id) }).prefix(9).enumerated()),
                    id: \.offset) { index, id in
                Button("") { tabSelection.wrappedValue = id }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            if keyNavigationActive {
                Button("") { moveKeySelection(by: -1) }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { moveKeySelection(by: 1) }
                    .keyboardShortcut(.downArrow, modifiers: [])
                Button("") { openKeySelection() }
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// One arrow step through the visible rows; with nothing selected the
    /// arrows enter the list at its top.
    private func moveKeySelection(by offset: Int) {
        let ids = model.items(in: model.selectedFolderId).map { $0.chat.id }
        guard !ids.isEmpty else { return }
        guard let current = keySelection, let at = ids.firstIndex(of: current) else {
            keySelection = ids.first
            return
        }
        let next = at + offset
        guard ids.indices.contains(next) else { return }
        keySelection = ids[next]
    }

    private func openKeySelection() {
        guard let id = keySelection else { return }
        path.append(id)
    }

    /// The neighbour Ctrl+Tab and Cmd+[ ] move to: the next or previous chat
    /// of the tab's rows, nil at the list's edge and for a chat the tab does
    /// not hold (one opened out of the archive or a search).
    static func switchTarget(from id: String, in ids: [String], forward: Bool) -> String? {
        guard let at = ids.firstIndex(of: id) else { return nil }
        let next = at + (forward ? 1 : -1)
        return ids.indices.contains(next) ? ids[next] : nil
    }

    private var folderPages: some View {
        page(for: selectedFolder)
            .id(model.selectedFolderId ?? "")
            .transition(.asymmetric(
                insertion: .move(edge: slideForward ? .trailing : .leading),
                removal: .move(edge: slideForward ? .leading : .trailing)))
            .simultaneousGesture(
                DragGesture(minimumDistance: 120)
                    .onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5
                        else { return }
                        switchTab(by: value.translation.width < 0 ? 1 : -1)
                    })
    }

    /// Tab selection by tap; it also records which way the list should slide.
    private var tabSelection: Binding<String?> {
        Binding(get: { model.selectedFolderId },
                set: { new in
                    let ids: [String?] = [nil] + model.folders.map { $0.id }
                    let from = ids.firstIndex(of: model.selectedFolderId) ?? 0
                    let to = ids.firstIndex(of: new) ?? 0
                    slideForward = to >= from
                    model.selectedFolderId = new
                })
    }

    private var selectedFolder: ChatFolder? {
        model.folders.first { $0.id == model.selectedFolderId }
    }

    /// The neighbouring tab in the direction of the swipe: the "all" tab comes first,
    /// then the folders in their own order. There is nowhere to go past the ends.
    private func switchTab(by offset: Int) {
        let ids: [String?] = [nil] + model.folders.map { $0.id }
        guard let current = ids.firstIndex(of: model.selectedFolderId) else { return }
        let next = current + offset
        guard ids.indices.contains(next) else { return }
        Haptics.light()
        slideForward = offset > 0
        withAnimation(Theme.springFast) { model.selectedFolderId = ids[next] }
    }

    private func page(for folder: ChatFolder?) -> some View {
        let items = model.items(in: folder?.id)
        return ChatListCollection(model: model, folder: folder, items: items,
                                  keySelection: keySelection,
                                  ownUserId: app.session?.userId ?? "",
                                  onOpen: { path.append($0) },
                                  onOpenArchive: { path.append(ArchiveRoute()) },
                                  onDelete: { deleteCandidate = $0 },
                                  onNewFolder: { showFolders = true },
                                  onOpenStories: { watchingStories = $0 },
                                  onScroll: { tray.didScroll($0) },
                                  onWillEndDragging: { tray.willEndDragging($0, velocity: $1, target: $2) },
                                  topInset: StoriesTray.foldedHeight
                                      + (tray.expanded ? StoriesTray.unfoldDelta : 0)
                                      + (model.folders.isEmpty ? 0 : folderBarHeight))
        .overlay {
            if model.loaded, let folder, items.isEmpty {
                folderEmptyState(folder)
            } else if model.loaded, folder == nil, items.isEmpty,
                      model.requests.isEmpty, model.archived.isEmpty {
                emptyState
            }
        }
    }

    /// An empty folder is a state, not a failure: the rule brings nothing in
    /// yet, and the way to change that sits right next to it.
    private func folderEmptyState(_ folder: ChatFolder) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 46))
                .foregroundStyle(Theme.decorativeGlyph)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text("The folder “\(folder.title)” is empty")
                    .font(.title3.weight(.semibold))
                Text("Chats matching the folder's rule\nand ones you add yourself will land here")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button { editingFolder = folder } label: {
                Text("Edit folder")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chatlist.folder.empty.setup")
        }
        .padding(.bottom, 40)
    }


    /// A search hit: the chat opens and scrolls to the message rather than
    /// stopping at the bottom of the feed.
    private func openMessage(_ hit: MessageSearchHit) {
        MessageJump.request(chatId: hit.chatId, id: hit.id)
        path.append(hit.chatId)
    }

    /// A found person: the direct chat either already exists or is created.
    private func openPerson(_ user: APIClient.UserDTO) {
        Task {
            guard let chatId = await DirectChat.open(userId: user.id) else { return }
            path.append(chatId)
        }
    }
}

/// Chat list row: navigation goes through a NavigationLink, but the link is
/// hidden under the content so that List doesn't draw its own chevron.
struct ChatRow<Content: View>: View {
    let chatId: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            NavigationLink(value: chatId) { EmptyView() }.opacity(0)
            content()
        }
        // the row answers across its whole width: the link carries no label of
        // its own, and without a shape only the letters and the avatar of the
        // content are hit-tested — a tap in the gap beside them does nothing
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

struct ArchiveView: View {
    @ObservedObject var model: ChatListModel
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            ForEach(model.archived) { item in
                ChatRow(chatId: item.chat.id) {
                    ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { model.toggleArchive(item) } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up.fill")
                    }.tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if model.archived.isEmpty {
                ContentUnavailableView {
                    Label("Archive is empty", systemImage: "archivebox")
                } description: {
                    Text("Chats you archive will be here")
                }
            }
        }
        .navigationTitle("Archive")
    }
}
