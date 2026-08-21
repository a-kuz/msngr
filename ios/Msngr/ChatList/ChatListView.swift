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

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = ChatListModel()
    @StateObject private var search = ChatSearchModel()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path = NavigationPath()
    /// chat whose deletion is waiting for confirmation
    @State private var deleteCandidate: ChatListItem?
    @State private var showFolders = false
    /// which way the list slides when the tab changes: forward along the bar or back
    @State private var slideForward = true
    /// folder opened for editing straight from the list
    @State private var editingFolder: ChatFolder?

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
                    VStack(spacing: 0) {
                        ChatFolderBar(folders: model.folders, unread: model.folderUnread,
                                      selection: tabSelection,
                                      onManage: { showFolders = true },
                                      onEdit: { editingFolder = $0 })
                        folderPages
                    }
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
            .searchable(text: $model.searchText, prompt: "Search")
            // chats are filtered in place, messages and people are searched at their own pace
            .onChange(of: model.searchText) { _, text in
                model.updateSearch()
                search.update(text)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNewChat = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityIdentifier("chatlist.new")
                }
            }
            .navigationDestination(for: String.self) { chatId in
                ChatScreen(chatId: chatId)
            }
            .navigationDestination(for: ArchiveRoute.self) { _ in
                ArchiveView(model: model)
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
        return List {
            if folder == nil {
                if !model.requests.isEmpty { requestsSection }
                if !model.archived.isEmpty { archiveRow }
            }
            chatsSection(items, folder: folder)
        }
        .listStyle(.plain)
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

    private func chatsSection(_ items: [ChatListItem], folder: ChatFolder?) -> some View {
        ForEach(items) { item in
            ChatRow(chatId: item.chat.id) {
                ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
            }
            .contextMenu { folderMenu(item) }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let folder {
                    Button { model.setChat(item.id, inFolder: folder, included: false) } label: {
                        Label("Remove from folder", systemImage: "folder.badge.minus")
                    }.tint(.teal)
                }
                Button { model.toggleArchive(item) } label: {
                    Label("Archive", systemImage: "archivebox.fill")
                }.tint(.gray)
                Button { model.toggleMute(item) } label: {
                    let muted = MuteState.isMuted(muted: item.chat.muted, mutedUntil: item.chat.mutedUntil)
                    Label(muted ? "Unmute" : "Mute",
                          systemImage: muted ? "bell.fill" : "bell.slash.fill")
                }.tint(.indigo)
                // delete comes last, further from the edge
                Button(role: .destructive) { deleteCandidate = item } label: {
                    Label("Delete", systemImage: "trash.fill")
                }
                .accessibilityIdentifier("chatlist.delete")
            }
            .swipeActions(edge: .leading, allowsFullSwipe: false) {
                Button { model.togglePin(item) } label: {
                    Label(item.chat.pinned ? "Unpin" : "Pin",
                          systemImage: item.chat.pinned ? "pin.slash.fill" : "pin.fill")
                }.tint(.orange)
            }
        }
        .animation(Theme.springFast, value: items.map(\.id))
    }

    /// Sorts the chat into folders without opening the settings; the checkmark
    /// shows where it already sits, whether by rule or put there by hand.
    @ViewBuilder
    private func folderMenu(_ item: ChatListItem) -> some View {
        if model.folders.isEmpty {
            Button { showFolders = true } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }
        } else {
            let containing = model.folders(containing: item.id)
            ForEach(model.folders) { folder in
                let inside = containing.contains(folder.id)
                Button { model.setChat(item.id, inFolder: folder, included: !inside) } label: {
                    Label(folder.title, systemImage: inside ? "checkmark" : "folder")
                }
            }
        }
    }

    private var requestsSection: some View {
        Section {
            ForEach(model.requests) { item in
                ChatRow(chatId: item.chat.id) {
                    ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
                }
                // no full swipe: the same distance switches the tab, and blocking
                // by accident takes the chat away for good
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button { model.blockRequest(item) } label: {
                        Label("Block", systemImage: "hand.raised.fill")
                    }.tint(.red)
                    Button { model.acceptRequest(item) } label: {
                        Label("Accept", systemImage: "checkmark")
                    }.tint(.green)
                }
            }
        } header: {
            Text("Message requests")
        }
    }

    /// The archive goes onto the same path as the chats: a link that carries its
    /// destination in itself puts the stack out of step with the path, and a chat
    /// opened out of the archive then arrives one tap late or not at all.
    private var archiveRow: some View {
        NavigationLink(value: ArchiveRoute()) {
            HStack {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                Text("Archive").foregroundStyle(.secondary)
                Spacer()
                Text("\(model.archived.count)").foregroundStyle(.secondary).font(.subheadline)
            }
        }
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
