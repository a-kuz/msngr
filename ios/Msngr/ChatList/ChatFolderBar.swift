import SwiftUI
import MsngrCore

/// The tabs above the list: the "all" tab and the user's folders. A tab switches on a
/// tap, the list itself switches on a swipe (see ChatListView), and the
/// underline moves on the same spring either way.
struct ChatFolderBar: View {
    let folders: [ChatFolder]
    /// How many chats have unread messages, per folder; the key for the "all" tab is an empty string.
    let unread: [String: Int]
    /// The selected tab; nil means the "all" tab.
    @Binding var selection: String?
    var onManage: () -> Void
    var onEdit: (ChatFolder) -> Void

    @Namespace private var indicator
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The strip takes its height from the tab font: at large text sizes the
    /// title would otherwise be clipped along the bottom edge.
    private var tabHeight: CGFloat { typeSize.scaled(39, relativeTo: .subheadline, max: 56) }
    private var tabBadgeSide: CGFloat { typeSize.scaled(18, relativeTo: .caption1, max: 28) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    tab(id: nil, title: String(localized: "All"), badge: unread[""] ?? 0)
                    ForEach(folders) { folder in
                        tab(id: folder.id, title: folder.title, badge: unread[folder.id] ?? 0)
                            .contextMenu {
                                Button { onEdit(folder) } label: {
                                    Label("Edit folder", systemImage: "slider.horizontal.3")
                                }
                                Button { onManage() } label: {
                                    Label("All folders", systemImage: "folder")
                                }
                            }
                    }
                    manageChip
                }
                .padding(.horizontal, 10)
            }
            .onChange(of: selection) { _, new in
                withAnimation(Theme.springFast) { proxy.scrollTo(new ?? "", anchor: .center) }
            }
        }
        .frame(height: tabHeight + 1)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func tab(id: String?, title: String, badge: Int) -> some View {
        let selected = id == selection
        return Button {
            guard !selected else { return }
            Haptics.light()
            withAnimation(Theme.springFast) { selection = id }
        } label: {
            HStack(spacing: 5) {
                Text(title)
                    .textRole(selected ? Theme.Text.folderTabActive : Theme.Text.folderTab)
                if badge > 0 {
                    Text("\(badge)")
                        .textRole(Theme.Text.tabBadge)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: tabBadgeSide, minHeight: tabBadgeSide)
                        .background(selected ? Theme.accent : Color.secondary)
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(selected ? Theme.accent : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: tabHeight)
            .overlay(alignment: .bottom) {
                if selected {
                    Capsule()
                        .fill(Theme.accent)
                        .frame(height: 3)
                        .matchedGeometryEffect(id: "folderTab", in: indicator)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(id ?? "")
        .accessibilityIdentifier("chatlist.folder.\(id ?? "all")")
    }

    /// While there are no folders the strip is itself the invitation to make
    /// one: the button that creates it stands where the tab will be.
    private var manageChip: some View {
        Button(action: onManage) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(Theme.glyph(13, max: 20).weight(.semibold))
                if folders.isEmpty {
                    Text("Folder").textRole(Theme.Text.folderTab)
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(height: tabHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatlist.folders.manage")
    }
}
