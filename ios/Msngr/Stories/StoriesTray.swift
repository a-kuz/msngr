import SwiftUI
import MsngrCore

/// The row of stories over the chat list: your own first, with the plus that
/// starts a new one, then everyone with something live, the unwatched ones
/// ahead. A ring around a picture means there is something to watch. The row
/// is drawn at a `progress` between folded and unfolded, and every measure is
/// interpolated between the two: folded, the pictures are small and lie in a
/// stack, each overlapping the one before it with the first on top and only the
/// first few showing; unfolded, they stand apart at full size with their names
/// under them. `StoriesTrayFollower` moves the progress with the finger on the
/// list.
struct StoriesTray: View {
    var progress: CGFloat
    var onCompose: () -> Void
    var onOpen: (StoriesModel.Author) -> Void

    @EnvironmentObject var app: AppState
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
    /// A cell is as wide as its picture when folded and as its name when unfolded.
    private var cellWidth: CGFloat { side + (72 - side) * p }
    /// Folded, each picture lies over a third of the one before it.
    private var spacing: CGFloat { -side * 0.35 * (1 - p) + 14 * p }
    /// How many others show in the folded stack.
    private static let stacked = 3

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: spacing) {
                ownCell
                    .zIndex(Double(others.count + 1))
                ForEach(Array(others.enumerated()), id: \.element.id) { index, author in
                    // the rest of the stack fades in as the row unfolds; while
                    // it is hidden it is not a target either
                    let shown = index < Self.stacked
                    Button { onOpen(author) } label: {
                        cell(name: author.name, avatarId: author.avatarId,
                             title: author.name, ring: true, unseen: author.unseen)
                    }
                    .buttonStyle(.plain)
                    .zIndex(Double(others.count - index))
                    .opacity(shown ? 1 : p)
                    .allowsHitTesting(shown || p > 0.5)
                    .accessibilityHidden(!shown && p < 0.5)
                    .accessibilityIdentifier("stories.author.\(author.id)")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, verticalPad)
        }
        .frame(height: Self.foldedHeight + Self.unfoldDelta * p)
        .scrollDisabled(p < 0.5)
        .accessibilityIdentifier("stories.tray")
        .task(id: app.ready) { await loadMe() }
        // the list is read once per connection and then follows the socket:
        // a story posted, taken down or watched arrives as a frame
        .task(id: app.ready) {
            guard app.ready, let engine = app.engine else { return }
            await stories.follow(engine)
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
                // a disc of the background behind the picture and its ring:
                // in the stack it cuts the picture out of the one underneath
                .background(Circle().fill(Color(.systemBackground)).padding(-5 - p))
            // the name takes its room as the row unfolds and fades in with it
            Text(title)
                .font(.caption2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: cellWidth, height: nameHeight, alignment: .bottom)
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
/// Folded, the tray is the first thing in the list: a scroll up carries it away
/// with the top row, out under the bar, and the folder tabs move up behind it
/// until they stand under the bar themselves.
@MainActor
final class StoriesTrayFollower: ObservableObject {
    /// How far the tray is unfolded right now, 0 to 1.
    @Published private(set) var progress: CGFloat = 0
    /// The state the list's inset is sized for.
    @Published private(set) var expanded = false
    /// How far the folded tray has scrolled out under the bar with the rows,
    /// 0 to its folded height. The header over the list is raised by this.
    @Published private(set) var hidden: CGFloat = 0

    private let delta = StoriesTray.unfoldDelta

    /// The distance the list is pulled past its top; negative once it has scrolled.
    private func pull(_ sv: UIScrollView) -> CGFloat {
        -(sv.contentOffset.y + sv.adjustedContentInset.top)
    }

    func didScroll(_ sv: UIScrollView) {
        // the folded tray follows the offset itself, whatever moved it: a
        // programmatic scroll to the top has to bring it back too
        if !expanded {
            set(hidden: min(StoriesTray.foldedHeight, max(0, -pull(sv))))
        }
        // only the finger, or the momentum it left, moves the tray. The offset
        // also moves when the system re-insets the list — the safe area
        // changes twice across a push and a pop — and reading those as a
        // scroll folded the tray and took its delta out of the inset while
        // the rows were away, so they came back standing under the header
        guard sv.isTracking || sv.isDragging || sv.isDecelerating else { return }
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
                // a fast scroll folds and hides in one frame
                set(hidden: min(StoriesTray.foldedHeight, max(0, -self.pull(sv))))
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

    private func set(hidden value: CGFloat) {
        if abs(value - hidden) > 0.001 { hidden = value }
    }
}
