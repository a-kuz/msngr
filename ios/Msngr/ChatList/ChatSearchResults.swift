import SwiftUI
import MsngrCore

/// Search results in one list: chats show up on the very first character,
/// messages and people arrive below them as they are found.
struct ChatSearchResults: View {
    @ObservedObject var list: ChatListModel
    @ObservedObject var search: ChatSearchModel
    let ownUserId: String
    @Environment(\.dynamicTypeSize) private var typeSize
    /// A tap on a found message opens the chat at that message.
    var onOpenMessage: (MessageSearchHit) -> Void
    var onOpenPerson: (APIClient.UserDTO) -> Void

    var body: some View {
        List {
            if !list.searchResults.isEmpty {
                Section("Chats") {
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

    // MARK: - Messages

    @ViewBuilder
    private var messagesSection: some View {
        if !search.hits.isEmpty {
            Section("Messages") {
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
            // the chats are already on screen; this says what else is still coming
            Section("Messages") {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Searching messages…").foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("search.messages.progress")
            }
        }
    }

    // MARK: - People

    @ViewBuilder
    private var peopleSection: some View {
        if !search.people.isEmpty {
            Section("People") {
                ForEach(search.people, id: \.id) { user in
                    Button { onOpenPerson(user) } label: {
                        HStack(spacing: 10) {
                            AvatarView(name: user.display_name, avatarId: user.avatar_id)
                                .frame(width: personAvatarSide, height: personAvatarSide)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(user.display_name)
                                    .textRole(Theme.Text.rowTitle)
                                Text("@\(user.username)")
                                    .textRole(Theme.Text.personHandle)
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

    // MARK: - Empty

    /// The empty state appears only when there is nothing left to find: while
    /// messages or people are still coming the screen shows the search running,
    /// not its outcome.
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
            Text("Nothing found")
                .font(.title3.weight(.semibold))
            Text("Search by chat name, message text\nor username")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 40)
        .accessibilityIdentifier("search.empty")
    }

    /// A person's avatar scales with the text size, like the chat row beside it.
    private var personAvatarSide: CGFloat {
        typeSize.scaled(40, relativeTo: .subheadline, max: 58)
    }
}

/// A found message as a row: whose chat it is, the snippet with the matched
/// word highlighted, and when it was written.
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
                    // an attachment caption is searched as ordinary text, but the
                    // row has to show the hit is a photo or a file, not a message
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

    private var title: String { chat?.title ?? String(localized: "Chat") }

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

    /// The matched words are emphasised inside the snippet itself, so it is
    /// visible what put the row in the results.
    static func highlighted(_ snippet: MessageSearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        for range in snippet.matches {
            guard let lower = AttributedString.Index(range.lowerBound, within: text),
                  let upper = AttributedString.Index(range.upperBound, within: text) else { continue }
            // the emphasis comes from the text role rather than a size of its
            // own: the whole row has to follow the system font size
            text[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
            text[lower..<upper].foregroundColor = Theme.accent
        }
        return text
    }
}
