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
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if !model.searchText.isEmpty {
                    searchSection
                } else {
                    if !model.requests.isEmpty { requestsSection }
                    if !model.archived.isEmpty { archiveRow }
                    chatsSection
                }
            }
            .listStyle(.plain)
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
            .onAppear { model.start() }
            .onChange(of: app.ready) { _, ready in
                if ready { model.start() }
            }
        }
    }

    private var chatsSection: some View {
        ForEach(model.items) { item in
            ChatRow(chatId: item.chat.id) {
                ChatRowView(item: item, ownUserId: app.session?.userId ?? "")
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                Button { model.toggleArchive(item) } label: {
                    Label("Архив", systemImage: "archivebox.fill")
                }.tint(.gray)
                Button { model.toggleMute(item) } label: {
                    Label(item.chat.muted ? "Вкл. звук" : "Без звука",
                          systemImage: item.chat.muted ? "bell.fill" : "bell.slash.fill")
                }.tint(.indigo)
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button { model.togglePin(item) } label: {
                    Label(item.chat.pinned ? "Открепить" : "Закрепить",
                          systemImage: item.chat.pinned ? "pin.slash.fill" : "pin.fill")
                }.tint(.orange)
            }
        }
        .animation(Theme.springFast, value: model.items.map(\.id))
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
