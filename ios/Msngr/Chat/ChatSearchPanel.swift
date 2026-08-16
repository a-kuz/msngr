import SwiftUI
import MsngrCore

/// The field search inside a chat is typed into. It stands in the header's place,
/// so the screen keeps a single line of chrome above the feed.
struct ChatSearchField: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    /// The keyboard belongs to the field and can only be asked for once the field
    /// is on screen: the screen opening search is a run loop too early for it.
    @State private var keyboardAsked = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(Theme.glyph(14, max: 20))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Поиск по чату", text: $text)
                .textRole(Theme.Text.body)
                .focused($focused)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("chat.search.field")
            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(Theme.glyph(15, max: 21))
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel("Очистить")
                .accessibilityIdentifier("chat.search.clear")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .frame(maxWidth: .infinity)
        // the keyboard is raised once, when search opens; a reader who put it away
        // to read the matches keeps it away
        .onAppear {
            guard !keyboardAsked else { return }
            keyboardAsked = true
            focused = true
        }
    }
}

/// The matches over the feed: each row carries the piece of text the match sits
/// in, so it is readable without opening the message.
struct ChatSearchResultsList: View {
    @ObservedObject var session: ChatSearchSession
    let members: [User]
    let ownUserId: String
    var onOpen: (MessageSearchHit) -> Void

    var body: some View {
        List {
            ForEach(session.hits) { hit in
                Button { onOpen(hit) } label: {
                    ChatSearchHitRow(hit: hit, author: author(of: hit))
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .onAppear { session.results.loadMoreIfNeeded(at: hit) }
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.interactively)
        .background(Color(.systemBackground))
        .overlay { if session.hits.isEmpty { state } }
        .accessibilityIdentifier("chat.search.results")
    }

    /// While the first page is being read an empty list is not an answer yet.
    @ViewBuilder
    private var state: some View {
        if session.searching {
            VStack(spacing: 8) {
                ProgressView()
                Text("Ищем в переписке…")
                    .textRole(Theme.Text.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("chat.search.progress")
        } else if session.foundNothing {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(Theme.glyph(34, max: 48))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                Text("Ничего не нашлось")
                    .font(.title3.weight(.semibold))
                Text("В этом чате нет сообщений с таким текстом")
                    .textRole(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
            .accessibilityIdentifier("chat.search.empty")
        } else {
            Color(.systemBackground)
        }
    }

    private func author(of hit: MessageSearchHit) -> String {
        if hit.fromUserId == ownUserId { return "Вы" }
        return members.first { $0.id == hit.fromUserId }?.displayName ?? "Собеседник"
    }
}

/// A found message: who wrote it, when, and the text around the match.
struct ChatSearchHitRow: View {
    let hit: MessageSearchHit
    let author: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(author)
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
                // an attachment caption is searched as ordinary text, but the row
                // has to show the hit is a photo or a file, not a message
                if let icon = MessageHitRow.kindIcon(hit.kind) {
                    Image(systemName: icon)
                        .font(Theme.glyph(12, max: 18))
                        .foregroundStyle(Theme.accent)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                }
                Text(MessageHitRow.highlighted(hit.snippet))
                    .textRole(Theme.Text.rowPreview)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The bar under the feed while the chat is being searched: where the reader
/// stands in the result and the two steps through it.
struct ChatSearchMatchBar: View {
    @ObservedObject var session: ChatSearchSession
    var onStep: (Int) -> Void
    var onShowList: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button(action: onShowList) {
                Text(session.status)
                    .textRole(Theme.Text.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(session.hits.isEmpty)
            .accessibilityIdentifier("chat.search.status")
            Spacer(minLength: 8)
            step(icon: "chevron.up", label: "Раньше", enabled: session.canStepOlder, offset: 1)
                .accessibilityIdentifier("chat.search.older")
            step(icon: "chevron.down", label: "Позже", enabled: session.canStepNewer, offset: -1)
                .accessibilityIdentifier("chat.search.newer")
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    private func step(icon: String, label: String, enabled: Bool, offset: Int) -> some View {
        Button { onStep(offset) } label: {
            Image(systemName: icon)
                .font(Theme.glyph(18, max: 26).weight(.semibold))
                .frame(width: TypeScale.scaled(44, max: 58), height: TypeScale.scaled(40, max: 54))
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .tint(Theme.accent)
        .accessibilityLabel(label)
    }
}
