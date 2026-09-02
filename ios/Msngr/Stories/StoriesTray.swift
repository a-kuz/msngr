import SwiftUI
import MsngrCore

/// The row of stories over the chat list: your own first, with the plus that
/// starts a new one, then everyone with something live, the unwatched ones
/// ahead. A ring around a picture means there is something to watch. Folded,
/// the row is small rings and nothing else; unfolded, the pictures grow and
/// take their names.
struct StoriesTray: View {
    var expanded: Bool
    var onCompose: () -> Void
    var onOpen: (StoriesModel.Author) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var stories = StoriesModel.shared
    @State private var me: User?

    private var ownId: String { app.session?.userId ?? "" }
    private var mine: StoriesModel.Author? { stories.authors.first { $0.id == ownId } }
    private var others: [StoriesModel.Author] { stories.authors.filter { $0.id != ownId } }

    /// The picture's side in the two states of the row.
    private var side: CGFloat { expanded ? 56 : 30 }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: expanded ? 14 : 10) {
                ownCell
                ForEach(others) { author in
                    Button { onOpen(author) } label: {
                        cell(name: author.name, avatarId: author.avatarId,
                             title: author.name, ring: true, unseen: author.unseen)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("stories.author.\(author.id)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, expanded ? 8 : 6)
        }
        .scrollDisabled(!expanded && others.count < 8)
        .accessibilityIdentifier("stories.tray")
        .task(id: app.ready) { await loadMe() }
        // the list is read again whenever the app comes to the front, and
        // once a minute while it stays there: a story is live for hours, and
        // nothing about it travels over the socket
        .task(id: app.ready) {
            guard app.ready else { return }
            while !Task.isCancelled {
                await stories.load()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await stories.load() } }
        }
    }

    /// Your own picture: a tap watches what you have live, the plus adds to it
    /// or starts the first one.
    private var ownCell: some View {
        Button {
            if let mine { onOpen(mine) } else { onCompose() }
        } label: {
            cell(name: me?.displayName ?? "", avatarId: me?.avatarId,
                 title: String(localized: "Your story"),
                 ring: mine != nil, unseen: mine?.unseen ?? false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("stories.mine")
        .overlay(alignment: .topTrailing) {
            Button(action: onCompose) {
                Image(systemName: "plus")
                    .font(.system(size: expanded ? 11 : 8, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: expanded ? 20 : 14, height: expanded ? 20 : 14)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: expanded ? 2 : 1.5))
            }
            .offset(x: expanded ? 2 : 3, y: expanded ? 40 : 18)
            .accessibilityIdentifier("chatlist.newStory")
        }
    }

    private func cell(name: String, avatarId: String?, title: String,
                      ring: Bool, unseen: Bool) -> some View {
        VStack(spacing: 5) {
            AvatarView(name: name, avatarId: avatarId)
                .frame(width: side, height: side)
                .overlay {
                    if ring {
                        Circle()
                            .strokeBorder(Theme.accent.opacity(unseen ? 1 : 0.3),
                                          lineWidth: expanded ? 2.5 : 2)
                            .padding(expanded ? -4 : -3)
                    }
                }
            if expanded {
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .frame(width: 72)
            }
        }
    }

    private func loadMe() async {
        guard app.ready, let db = app.db else { return }
        me = try? await db.read { [id = ownId] dbc in try User.fetchOne(dbc, key: id) }
    }
}
