import SwiftUI
import MsngrCore

/// Выдача поиска одним списком: чаты появляются на первом же символе, сообщения
/// и люди подъезжают ниже, когда их найдут.
struct ChatSearchResults: View {
    @ObservedObject var list: ChatListModel
    @ObservedObject var search: ChatSearchModel
    let ownUserId: String
    /// Тап по найденному сообщению: чат открывается на этом сообщении.
    var onOpenMessage: (MessageSearchHit) -> Void
    var onOpenPerson: (APIClient.UserDTO) -> Void

    var body: some View {
        List {
            if !list.searchResults.isEmpty {
                Section("Чаты") {
                    ForEach(list.searchResults) { item in
                        ChatRow(chatId: item.chat.id) {
                            ChatRowView(item: item, ownUserId: ownUserId)
                        }
                    }
                }
            }
            messagesSection
            peopleSection
        }
        .listStyle(.plain)
        .overlay { if showsEmptyState { emptyState } }
    }

    // MARK: - Сообщения

    @ViewBuilder
    private var messagesSection: some View {
        if !search.hits.isEmpty {
            Section("Сообщения") {
                ForEach(search.hits) { hit in
                    Button { onOpenMessage(hit) } label: {
                        MessageHitRow(hit: hit, chat: list.item(for: hit.chatId))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .onAppear { search.loadMoreIfNeeded(at: hit) }
                }
            }
            .accessibilityIdentifier("search.messages")
        } else if search.searchingMessages {
            // чаты уже на экране — состояние объясняет, чего ещё ждать
            Section("Сообщения") {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Ищем в переписке…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("search.messages.progress")
            }
        }
    }

    // MARK: - Люди

    @ViewBuilder
    private var peopleSection: some View {
        if !search.people.isEmpty {
            Section("Люди") {
                ForEach(search.people, id: \.id) { user in
                    Button { onOpenPerson(user) } label: {
                        HStack(spacing: 10) {
                            AvatarView(name: user.display_name, avatarId: user.avatar_id)
                                .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.display_name)
                                    .font(.system(size: 16, weight: .semibold))
                                Text("@\(user.username)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .accessibilityIdentifier("search.people")
        }
    }

    // MARK: - Пусто

    /// Пусто показывается, только когда искать уже нечего: пока идут сообщения
    /// или люди, на экране состояние поиска, а не его итог.
    private var showsEmptyState: Bool {
        list.searchResults.isEmpty && search.hits.isEmpty && search.people.isEmpty
            && !search.searchingMessages && !search.searchingPeople && search.messagesReady
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("Ничего не нашлось")
                .font(.system(size: 17, weight: .semibold))
            Text("Поищем по названию чата, тексту сообщения\nили юзернейму")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 40)
        .accessibilityIdentifier("search.empty")
    }
}

/// Строка найденного сообщения: чей чат, кусок текста с подсвеченным словом и
/// когда это было написано.
struct MessageHitRow: View {
    let hit: MessageSearchHit
    let chat: ChatListItem?

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: title, avatarId: avatarId)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatRowView.timeLabel(hit.sortedAt))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 4) {
                    // подпись под вложением ищется как обычный текст, но строка
                    // должна показывать, что нашлась не переписка, а фото или файл
                    if let icon = Self.kindIcon(hit.kind) {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                    }
                    Text(Self.highlighted(hit.snippet))
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var title: String { chat?.title ?? "Чат" }

    private var avatarId: String? {
        guard let chat else { return nil }
        return chat.chat.kind == .direct ? chat.peer?.avatarId : chat.chat.avatarId
    }

    static func kindIcon(_ kind: MessageKind) -> String? {
        switch kind {
        case .photo: return "photo"
        case .video: return "video.fill"
        case .file: return "doc.fill"
        case .album: return "photo.on.rectangle"
        case .voice: return "mic.fill"
        default: return nil
        }
    }

    /// Найденные слова выделяются прямо в куске текста: так видно, за что
    /// строка попала в выдачу.
    static func highlighted(_ snippet: MessageSearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            text[lower..<upper].font = .system(size: 15, weight: .semibold)
            text[lower..<upper].foregroundColor = Theme.accent
        }
        return text
    }
}
