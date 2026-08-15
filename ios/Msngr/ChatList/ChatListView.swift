import SwiftUI
import MsngrCore

struct RootView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ChatListView()
    }
}

struct ChatListView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = ChatListModel()
    @ObservedObject private var theme = ThemeStore.shared
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path = NavigationPath()
    /// чат, для которого спрошено подтверждение удаления
    @State private var deleteCandidate: ChatListItem?
    @State private var showFolders = false
    /// папка, открытая на настройку прямо из списка
    @State private var editingFolder: ChatFolder?

    private var deleteConfirmPresented: Binding<Bool> {
        Binding(get: { deleteCandidate != nil },
                set: { if !$0 { deleteCandidate = nil } })
    }

    private var deleteTitle: String {
        guard let item = deleteCandidate else { return "" }
        return item.chat.kind == .group ? "Покинуть группу?" : "Удалить чат «\(item.title)»?"
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.searchText.isEmpty {
                    VStack(spacing: 0) {
                        ChatFolderBar(folders: model.folders, unread: model.folderUnread,
                                      selection: $model.selectedFolderId,
                                      onManage: { showFolders = true },
                                      onEdit: { editingFolder = $0 })
                        folderPages
                    }
                } else {
                    List { searchSection }.listStyle(.plain)
                }
            }
            // «пришли на список чатов» — по идентификатору списка, а не по
            // заголовку: заголовок навигации в дерево доступности не попадает,
            // когда список пуст и его закрывает overlay
            .accessibilityIdentifier("chatlist.root")
            .navigationTitle("Чаты")
            .searchable(text: $model.searchText, prompt: "Поиск")
            .onChange(of: model.searchText) { _, _ in model.updateSearch() }
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
            // тап по пушу или in-app баннеру → переход в чат
            .onReceive(NotificationCenter.default.publisher(for: .openChatRequested)) { note in
                guard let chatId = note.object as? String,
                      NotificationCoordinator.shared.activeChatId != chatId else { return }
                path.append(chatId)
            }
            // чат удалён из своего же экрана — возвращаемся к списку
            .onReceive(NotificationCenter.default.publisher(for: .chatDeleted)) { _ in
                path = NavigationPath()
            }
            .confirmationDialog(deleteTitle, isPresented: deleteConfirmPresented,
                                titleVisibility: .visible) {
                let isGroup = deleteCandidate?.chat.kind == .group
                Button(isGroup ? "Покинуть" : "Удалить", role: .destructive) {
                    if let item = deleteCandidate { model.deleteChat(item) }
                    deleteCandidate = nil
                }
                Button("Отмена", role: .cancel) { deleteCandidate = nil }
            } message: {
                Text(deleteCandidate?.chat.kind == .group
                     ? "Вы выйдете из группы, её сообщения удалятся с этого устройства."
                     : "Чат и его сообщения удалятся с этого устройства. У собеседника переписка останется.")
            }
        }
    }

    /// Пустой список: иконка, текст и кнопка, открывающая NewChat.
    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 52))
                .foregroundStyle(Theme.accent.opacity(0.55))
            VStack(spacing: 5) {
                Text("Нет чатов")
                    .font(.title3.weight(.semibold))
                Text("Найдите собеседника по юзернейму\nили из адресной книги")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                showNewChat = true
            } label: {
                Text("Начать переписку")
                    .fontWeight(.semibold)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("chatlist.empty.start")
        }
        .padding(.bottom, 40)
    }

    /// Вкладки листаются свайпом: у каждой свой список, соседние страницы
    /// собираются из уже посчитанного состава папок.
    private var folderPages: some View {
        TabView(selection: pageSelection) {
            page(for: nil).tag("")
            ForEach(model.folders) { folder in
                page(for: folder).tag(folder.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var pageSelection: Binding<String> {
        Binding(get: { model.selectedFolderId ?? "" },
                set: { model.selectedFolderId = $0.isEmpty ? nil : $0 })
    }

    private func page(for folder: ChatFolder?) -> some View {
        let items = model.items(in: folder?.id)
        return List {
            // архив и заявки — состояния входящего потока, а не тема
            // переписки: они остаются наверху «Всех» и в папки не переезжают
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

    /// Пустая папка: правило пока ничего не приносит — это состояние, и рядом
    /// лежит то, чем его меняют.
    private func folderEmptyState(_ folder: ChatFolder) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "folder")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent.opacity(0.55))
            VStack(spacing: 5) {
                Text("В папке «\(folder.title)» пусто")
                    .font(.title3.weight(.semibold))
                Text("Сюда попадут чаты по правилу папки\nи те, что вы добавите сами")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button { editingFolder = folder } label: {
                Text("Настроить папку")
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
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let folder {
                    Button { model.setChat(item.id, inFolder: folder, included: false) } label: {
                        Label("Из папки", systemImage: "folder.badge.minus")
                    }.tint(.teal)
                }
                Button { model.toggleArchive(item) } label: {
                    Label("Архив", systemImage: "archivebox.fill")
                }.tint(.gray)
                Button { model.toggleMute(item) } label: {
                    let muted = MuteState.isMuted(muted: item.chat.muted, mutedUntil: item.chat.mutedUntil)
                    Label(muted ? "Вкл. звук" : "Без звука",
                          systemImage: muted ? "bell.fill" : "bell.slash.fill")
                }.tint(.indigo)
                // удаление стоит последним: полный свайп архивирует, а не удаляет
                Button(role: .destructive) { deleteCandidate = item } label: {
                    Label("Удалить", systemImage: "trash.fill")
                }
                .accessibilityIdentifier("chatlist.delete")
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { model.togglePin(item) } label: {
                    Label(item.chat.pinned ? "Открепить" : "Закрепить",
                          systemImage: item.chat.pinned ? "pin.slash.fill" : "pin.fill")
                }.tint(.orange)
            }
        }
        .animation(Theme.springFast, value: items.map(\.id))
    }

    /// Разложить чат по папкам, не открывая настройки: галочка показывает, где
    /// он уже лежит — по правилу или руками.
    @ViewBuilder
    private func folderMenu(_ item: ChatListItem) -> some View {
        if model.folders.isEmpty {
            Button { showFolders = true } label: {
                Label("Создать папку", systemImage: "folder.badge.plus")
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
                .swipeActions(edge: .trailing) {
                    Button { model.blockRequest(item) } label: {
                        Label("Заблокировать", systemImage: "hand.raised.fill")
                    }.tint(.red)
                    Button { model.acceptRequest(item) } label: {
                        Label("Принять", systemImage: "checkmark")
                    }.tint(.green)
                }
            }
        } header: {
            Text("Заявки на переписку")
        }
    }

    private var archiveRow: some View {
        NavigationLink {
            ArchiveView(model: model)
        } label: {
            HStack {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                    .frame(width: 52, height: 52)
                Text("Архив").foregroundStyle(.secondary)
                Spacer()
                Text("\(model.archived.count)").foregroundStyle(.secondary).font(.subheadline)
            }
        }
    }

    private var searchSection: some View {
        ForEach(model.searchResults) { item in
            ChatRow(chatId: item.chat.id) {
                ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
            }
        }
    }
}

/// Строка чат-листа: навигация через NavigationLink (надёжно открывает чат),
/// но скрытая под контентом — так List не рисует свой шеврон-индикатор.
struct ChatRow<Content: View>: View {
    let chatId: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            NavigationLink(value: chatId) { EmptyView() }.opacity(0)
            content()
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}

struct ArchiveView: View {
    @ObservedObject var model: ChatListModel
    @EnvironmentObject var app: AppState

    var body: some View {
        List {
            ForEach(model.archived) { item in
                NavigationLink(value: item.chat.id) {
                    ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
                }
                .swipeActions(edge: .trailing) {
                    Button { model.toggleArchive(item) } label: {
                        Label("Из архива", systemImage: "tray.and.arrow.up.fill")
                    }.tint(.blue)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Архив")
    }
}
