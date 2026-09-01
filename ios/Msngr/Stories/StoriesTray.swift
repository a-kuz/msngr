import SwiftUI
import MsngrCore

/// The row of stories over the chat list: your own first, with the plus that
/// starts a new one, then everyone with something live, the unwatched ones
/// ahead. A ring around a picture means there is something to watch.
struct StoriesTray: View {
    var onCompose: () -> Void
    var onOpen: (StoriesModel.Author) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var stories = StoriesModel.shared
    @State private var me: User?

    private var ownId: String { app.session?.userId ?? "" }
    private var mine: StoriesModel.Author? { stories.authors.first { $0.id == ownId } }
    private var others: [StoriesModel.Author] { stories.authors.filter { $0.id != ownId } }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
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
            .padding(.vertical, 8)
        }
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
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }
            .offset(x: 2, y: 40)
            .accessibilityIdentifier("chatlist.newStory")
        }
    }

    private func cell(name: String, avatarId: String?, title: String,
                      ring: Bool, unseen: Bool) -> some View {
        VStack(spacing: 5) {
            AvatarView(name: name, avatarId: avatarId)
                .frame(width: 56, height: 56)
                .overlay {
                    if ring {
                        Circle()
                            .strokeBorder(Theme.accent.opacity(unseen ? 1 : 0.3), lineWidth: 2.5)
                            .padding(-4)
                    }
                }
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 72)
        }
    }

    private func loadMe() async {
        guard app.ready, let db = app.db else { return }
        me = try? await db.read { [id = ownId] dbc in try User.fetchOne(dbc, key: id) }
    }
}
