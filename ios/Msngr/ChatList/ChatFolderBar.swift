import SwiftUI
import MsngrCore

/// Вкладки над списком: «Все» и папки пользователя. Вкладка переключается
/// тапом, а сам список — свайпом (см. ChatListView); подчёркивание переезжает
/// одной пружиной на обеих дорогах.
struct ChatFolderBar: View {
    let folders: [ChatFolder]
    /// Число чатов с непрочитанным по папкам; ключ «Всех» — пустая строка.
    let unread: [String: Int]
    /// Выбранная вкладка; nil — «Все».
    @Binding var selection: String?
    var onManage: () -> Void
    var onEdit: (ChatFolder) -> Void

    @Namespace private var indicator
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Полоса вкладок ведёт свою высоту от шрифта вкладки: на крупном тексте
    /// название иначе обрезается по нижнему краю.
    private var tabHeight: CGFloat { typeSize.scaled(39, relativeTo: .subheadline, max: 56) }
    private var tabBadgeSide: CGFloat { typeSize.scaled(18, relativeTo: .caption1, max: 28) }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    tab(id: nil, title: "Все", badge: unread[""] ?? 0)
                    ForEach(folders) { folder in
                        tab(id: folder.id, title: folder.title, badge: unread[folder.id] ?? 0)
                            .contextMenu {
                                Button { onEdit(folder) } label: {
                                    Label("Настроить папку", systemImage: "slider.horizontal.3")
                                }
                                Button { onManage() } label: {
                                    Label("Все папки", systemImage: "folder")
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
        }
        .buttonStyle(.plain)
        .id(id ?? "")
        .accessibilityIdentifier("chatlist.folder.\(id ?? "all")")
    }

    /// Пока папок нет, полоса и есть приглашение их завести: на месте будущей
    /// вкладки стоит кнопка, которая её создаёт.
    private var manageChip: some View {
        Button(action: onManage) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(Theme.glyph(13, max: 20).weight(.semibold))
                if folders.isEmpty {
                    Text("Папка").textRole(Theme.Text.folderTab)
                }
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 12)
            .frame(height: tabHeight)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chatlist.folders.manage")
    }
}
