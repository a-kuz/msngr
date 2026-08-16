import SwiftUI
import MsngrCore

/// Выдача поиска одним списком: чаты появляются на первом же символе, сообщения
/// и люди подъезжают ниже, когда их найдут.
struct ChatSearchResults: View {
    @ObservedObject var list: ChatListModel
    @ObservedObject var search: ChatSearchModel
    let ownUserId: String
    @Environment(\.dynamicTypeSize) private var typeSize
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
                                .frame(width: personAvatarSide, height: personAvatarSide)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.display_name)
                                    .textRole(Theme.Text.rowTitle)
                                Text("@\(user.username)")
                                    .textRole(Theme.Text.rowTime)
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
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text("Ничего не нашлось")
                .font(.title3.weight(.semibold))
            Text("Поищем по названию чата, тексту сообщения\nили юзернейму")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 40)
        .accessibilityIdentifier("search.empty")
    }

    /// Аватар человека тянется за размером текста, как строка чата рядом.
    private var personAvatarSide: CGFloat {
        typeSize.scaled(40, relativeTo: .subheadline, max: 58)
    }
}

/// Строка найденного сообщения: чей чат, кусок текста с подсвеченным словом и
/// когда это было написано.
struct MessageHitRow: View {
    let hit: MessageSearchHit
    let chat: ChatListItem?
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(name: title, avatarId: avatarId)
                .frame(width: avatarSide, height: avatarSide)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(title)
                        .textRole(Theme.Text.rowTitle)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(ChatRowView.timeLabel(hit.sortedAt))
                        .textRole(Theme.Text.rowTime)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .layoutPriority(1)
                }
                HStack(alignment: .top, spacing: 4) {
                    // подпись под вложением ищется как обычный текст, но строка
                    // должна показывать, что нашлась не переписка, а фото или файл
                    if let icon = Self.kindIcon(hit.kind) {
                        Image(systemName: icon)
                            .font(Theme.glyph(12, max: 18))
                            .foregroundStyle(Theme.accent)
                            .padding(.top, 2)
                            .accessibilityHidden(true)
                    }
                    Text(Self.highlighted(hit.snippet))
                        .textRole(Theme.Text.rowPreview)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var avatarSide: CGFloat { typeSize.scaled(44, relativeTo: .subheadline, max: 62) }

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
            // выделение задаётся ролью текста, а не своим размером: строка
            // целиком должна тянуться за системным размером шрифта
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            text[lower..<upper].foregroundColor = Theme.accent
        }
        return text
    }
}
