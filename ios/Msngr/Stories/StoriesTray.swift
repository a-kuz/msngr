import SwiftUI
import MsngrCore

/// The row of stories over the chat list: your own first, with the plus that
/// starts a new one, then everyone with something live, the unwatched ones
/// ahead. A ring around a picture means there is something to watch. The row
/// is drawn at a `progress` between folded (small rings and nothing else) and
/// unfolded (full pictures with their names); `StoriesTrayFollower` moves the
/// progress with the finger on the list.
struct StoriesTray: View {
    var progress: CGFloat
    var onCompose: () -> Void
    var onOpen: (StoriesModel.Author) -> Void

    @EnvironmentObject var app: AppState
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var stories = StoriesModel.shared
    @State private var me: User?

    /// The folded row's height, and how much the unfolded one adds. Every
    /// measure below is interpolated so these two stay exact at either end.
    static let foldedHeight: CGFloat = 42
    static let unfoldDelta: CGFloat = 48

    private var ownId: String { app.session?.userId ?? "" }
    private var mine: StoriesModel.Author? { stories.authors.first { $0.id == ownId } }
    private var others: [StoriesModel.Author] { stories.authors.filter { $0.id != ownId } }

    private var p: CGFloat { min(1, max(0, progress)) }
    private var side: CGFloat { 30 + 26 * p }
    private var nameHeight: CGFloat { 18 * p }
    private var verticalPad: CGFloat { 6 + 2 * p }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 10 + 4 * p) {
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
            .padding(.vertical, verticalPad)
        }
        .frame(height: Self.foldedHeight + Self.unfoldDelta * p)
        .scrollDisabled(p < 0.5 && others.count < 8)
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
        let plus = 14 + 6 * p
        return Button {
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
                    .font(.system(size: 8 + 3 * p, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: plus, height: plus)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 1.5 + 0.5 * p))
                    // the badge is small to look at and a finger's width to touch
                    .contentShape(Circle().inset(by: -14 + 4 * p))
            }
            // the plus hangs off the picture's lower right, just past its edge
            .offset(x: 3 - p, y: side - plus + 4)
            .accessibilityIdentifier("chatlist.newStory")
        }
    }

    private func cell(name: String, avatarId: String?, title: String,
                      ring: Bool, unseen: Bool) -> some View {
        VStack(spacing: 0) {
            AvatarView(name: name, avatarId: avatarId)
                .frame(width: side, height: side)
                .overlay {
                    if ring {
                        Circle()
                            .strokeBorder(Theme.accent.opacity(unseen ? 1 : 0.3),
                                          lineWidth: 2 + 0.5 * p)
                            .padding(-3 - p)
                    }
                }
            // the name takes its room as the row unfolds and fades in with it
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 72, height: nameHeight, alignment: .bottom)
                .opacity(p)
                .clipped()
        }
    }

    private func loadMe() async {
        guard app.ready, let db = app.db else { return }
        me = try? await db.read { [id = ownId] dbc in try User.fetchOne(dbc, key: id) }
    }
}

/// Moves the stories tray with the finger on the chat list, the way Telegram
/// does. The tray and the folder tabs are drawn over the list, inside its top
/// content inset, so the list's frame never changes under a finger — that is
/// what lets the list's own bounce drive the whole motion. Folded, a pull past
/// the top grows the tray one for one with the finger; let go past half its
/// height the inset grows by the tray's delta and the bounce settles the rows
/// on the open tray, short of that the bounce carries the tray shut. Unfolded,
/// a scroll up folds the tray at the speed of the scroll, as if it were the
/// first row; when it is folded whole the inset gives the delta back, which
/// moves nothing on screen, and a release midway lands on the nearer state.
@MainActor
final class StoriesTrayFollower: ObservableObject {
    /// How far the tray is unfolded right now, 0 to 1.
    @Published private(set) var progress: CGFloat = 0
    /// The state the list's inset is sized for.
    @Published private(set) var expanded = false

    private let delta = StoriesTray.unfoldDelta

    /// The distance the list is pulled past its top; negative once it has scrolled.
    private func pull(_ sv: UIScrollView) -> CGFloat {
        -(sv.contentOffset.y + sv.adjustedContentInset.top)
    }

    func didScroll(_ sv: UIScrollView) {
        let pull = pull(sv)
        if !expanded {
            set(progress: min(1, max(0, pull) / delta))
        } else {
            let scrolled = -pull
            if scrolled >= delta {
                // folded whole: the rows already stand where the folded rest
                // is, so the inset shrinks and nothing on screen moves
                expanded = false
                sv.contentInset.top -= delta
                sv.verticalScrollIndicatorInsets.top -= delta
                set(progress: 0)
            } else {
                set(progress: 1 - max(0, scrolled) / delta)
            }
        }
    }

    func willEndDragging(_ sv: UIScrollView, velocity: CGPoint, target: UnsafeMutablePointer<CGPoint>) {
        let pull = pull(sv)
        if !expanded {
            guard pull >= delta / 2, velocity.y <= 0 else { return }
            // the rest moves down by the delta and the bounce takes the rows there
            expanded = true
            sv.contentInset.top += delta
            sv.verticalScrollIndicatorInsets.top += delta
        } else {
            let scrolled = -pull
            guard scrolled > 0, scrolled < delta else { return }
            // midway through folding: the list settles on whichever state is
            // nearer, and didScroll finishes the fold when it gets there
            let fold = scrolled > delta / 2 || velocity.y > 0.3
            target.pointee.y = -sv.adjustedContentInset.top + (fold ? delta : 0)
        }
    }

    private func set(progress value: CGFloat) {
        if abs(value - progress) > 0.001 { progress = value }
    }
}
