import SwiftUI
import UIKit
import MsngrCore

/// The chat list's container. A UIKit collection list instead of a SwiftUI
/// List because of what a reorder looks like: here a pinned or unpinned chat
/// is a real move — every row slides to its new place in one motion — while
/// List plays it as a removal and an insertion, flying the row over its
/// neighbours and leaving a gap open for the length of the spring.
struct ChatListCollection: UIViewRepresentable {
    @ObservedObject var model: ChatListModel
    var folder: ChatFolder?
    var items: [ChatListItem]
    var keySelection: String?
    var ownUserId: String
    var onOpen: (String) -> Void
    var onOpenArchive: () -> Void
    var onDelete: (ChatListItem) -> Void
    var onNewFolder: () -> Void

    enum Row: Hashable {
        case request(String)
        case archive
        case chat(String)
    }

    enum Sect: Int, CaseIterable {
        case requests, archive, chats
    }

    func makeUIView(context: Context) -> UICollectionView {
        let coordinator = context.coordinator
        let collection = UICollectionView(frame: .zero,
                                          collectionViewLayout: coordinator.makeLayout())
        collection.backgroundColor = .clear
        collection.delegate = coordinator
        coordinator.install(on: collection)
        coordinator.parent = self
        coordinator.apply(animated: false)
        return collection
    }

    func updateUIView(_ collection: UICollectionView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        // a structural change arrives inside the reorder's withAnimation
        // transaction; content-only emissions come with no animation and are
        // applied as silent reconfigures
        coordinator.apply(animated: context.transaction.animation != nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UICollectionViewDelegate {
        var parent: ChatListCollection
        private var dataSource: UICollectionViewDiffableDataSource<Sect, Row>?
        private weak var collection: UICollectionView?
        /// what each row showed last time, to reconfigure only what changed
        private var shown: [String: ChatListItem] = [:]
        private var shownArchivedCount = -1
        private var shownSelection: String?

        init(_ parent: ChatListCollection) {
            self.parent = parent
        }

        private func item(for row: Row) -> ChatListItem? {
            switch row {
            case .request(let id): return parent.model.requests.first { $0.id == id }
            case .chat(let id): return parent.items.first { $0.id == id }
            case .archive: return nil
            }
        }

        // MARK: layout

        func makeLayout() -> UICollectionViewLayout {
            UICollectionViewCompositionalLayout { [weak self] index, env in
                guard let self, let section = Sect(rawValue: index) else { return nil }
                var cfg = UICollectionLayoutListConfiguration(appearance: .plain)
                cfg.backgroundColor = .clear
                cfg.showsSeparators = true
                if section == .requests {
                    cfg.headerMode = .supplementary
                }
                cfg.leadingSwipeActionsConfigurationProvider = { [weak self] path in
                    self?.leadingSwipe(at: path)
                }
                cfg.trailingSwipeActionsConfigurationProvider = { [weak self] path in
                    self?.trailingSwipe(at: path)
                }
                return NSCollectionLayoutSection.list(using: cfg, layoutEnvironment: env)
            }
        }

        // MARK: cells

        func install(on collection: UICollectionView) {
            self.collection = collection
            let chatCell = UICollectionView.CellRegistration<ChatListCell, Row>
            { [weak self] cell, _, row in
                guard let self else { return }
                switch row {
                case .archive:
                    cell.contentConfiguration = UIHostingConfiguration {
                        ArchiveRowLabel(count: self.parent.model.archived.count)
                    }.margins(.all, 0)
                case .request(let id), .chat(let id):
                    guard let item = self.item(for: row) else { return }
                    cell.contentConfiguration = UIHostingConfiguration {
                        ChatRowView(item: item, ownUserId: self.parent.ownUserId)
                    }
                    .margins(.vertical, 6)
                    .margins(.horizontal, 12)
                    var bg = UIBackgroundConfiguration.listPlainCell()
                    if self.parent.keySelection == id {
                        bg.backgroundColor = UIColor(Theme.accent.opacity(0.12))
                    } else if item.chat.pinned {
                        bg.backgroundColor = .secondarySystemBackground
                    }
                    cell.backgroundConfiguration = bg
                }
                cell.pinSeparator()
            }
            let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
                elementKind: UICollectionView.elementKindSectionHeader) { view, _, _ in
                view.contentConfiguration = UIHostingConfiguration {
                    Text("Message requests")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .margins(.horizontal, 12)
                .margins(.vertical, 4)
            }
            let source = UICollectionViewDiffableDataSource<Sect, Row>(collectionView: collection)
            { view, path, row in
                view.dequeueConfiguredReusableCell(using: chatCell, for: path, item: row)
            }
            source.supplementaryViewProvider = { view, kind, path in
                view.dequeueConfiguredReusableSupplementary(using: header, for: path)
            }
            dataSource = source
        }

        // MARK: data

        func apply(animated: Bool) {
            guard let dataSource else { return }
            let inAll = parent.folder == nil
            let requests = inAll ? parent.model.requests : []
            let archivedCount = inAll ? parent.model.archived.count : 0

            var snapshot = NSDiffableDataSourceSnapshot<Sect, Row>()
            snapshot.appendSections(Sect.allCases)
            snapshot.appendItems(requests.map { .request($0.id) }, toSection: .requests)
            if archivedCount > 0 {
                snapshot.appendItems([.archive], toSection: .archive)
            }
            snapshot.appendItems(parent.items.map { .chat($0.id) }, toSection: .chats)

            // rows whose content moved on since they were last configured
            var changed: [Row] = []
            var current: [String: ChatListItem] = [:]
            for item in requests {
                current[item.id] = item
                if let old = shown[item.id], old != item { changed.append(.request(item.id)) }
            }
            for item in parent.items {
                current[item.id] = item
                if let old = shown[item.id],
                   old != item || shownSelection == item.id || parent.keySelection == item.id {
                    changed.append(.chat(item.id))
                }
            }
            if archivedCount > 0, shownArchivedCount != archivedCount, shownArchivedCount >= 0 {
                changed.append(.archive)
            }
            let toReconfigure = changed.filter { snapshot.indexOfItem($0) != nil }
            shown = current
            shownArchivedCount = archivedCount
            shownSelection = parent.keySelection

            // SwiftUI runs the update twice for one emission; a second apply of
            // the same order lands in the middle of the first one's slide and
            // ends it on the spot, so an unchanged order is only reconfigured
            let sameOrder = dataSource.snapshot().itemIdentifiers == snapshot.itemIdentifiers
            if animated, !sameOrder {
                // the move goes alone: a row reconfigured in the same batch is
                // animated on its own curve and lands after its neighbours
                dataSource.apply(snapshot, animatingDifferences: true) { [weak dataSource] in
                    guard let dataSource, !toReconfigure.isEmpty else { return }
                    var after = dataSource.snapshot()
                    after.reconfigureItems(toReconfigure.filter { after.indexOfItem($0) != nil })
                    dataSource.apply(after, animatingDifferences: false)
                }
            } else if sameOrder {
                guard !toReconfigure.isEmpty else { return }
                var after = dataSource.snapshot()
                after.reconfigureItems(toReconfigure)
                dataSource.apply(after, animatingDifferences: false)
            } else {
                snapshot.reconfigureItems(toReconfigure)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        }

        // MARK: selection

        func collectionView(_ collectionView: UICollectionView, didSelectItemAt path: IndexPath) {
            collectionView.deselectItem(at: path, animated: true)
            guard let row = dataSource?.itemIdentifier(for: path) else { return }
            switch row {
            case .archive: parent.onOpenArchive()
            case .request(let id), .chat(let id): parent.onOpen(id)
            }
        }

        // MARK: swipes

        private func leadingSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let row = dataSource?.itemIdentifier(for: path),
                  case .chat = row, let item = item(for: row) else { return nil }
            let pin = UIContextualAction(style: .normal,
                                         title: String(localized: item.chat.pinned ? "Unpin" : "Pin"))
            { [weak self] _, _, done in
                // the row moves only once its swipe has closed: a cell still in
                // its swipe state is animated apart from the batch it belongs to
                done(true)
                // a cell that has been under a swipe starts its move from a stale
                // frame: once the swipe has closed, the row is reissued as a fresh
                // cell — nothing visible changes — and that one makes the move
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    guard let self, let dataSource = self.dataSource,
                          let row = dataSource.itemIdentifier(for: path) else { return }
                    var snapshot = dataSource.snapshot()
                    snapshot.reloadItems([row])
                    dataSource.apply(snapshot, animatingDifferences: false)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        self.parent.model.togglePin(item)
                    }
                }
            }
            pin.image = UIImage(systemName: item.chat.pinned ? "pin.slash.fill" : "pin.fill")
            pin.backgroundColor = .systemOrange
            let cfg = UISwipeActionsConfiguration(actions: [pin])
            cfg.performsFirstActionWithFullSwipe = false
            return cfg
        }

        private func trailingSwipe(at path: IndexPath) -> UISwipeActionsConfiguration? {
            guard let row = dataSource?.itemIdentifier(for: path),
                  let item = item(for: row) else { return nil }
            let model = parent.model
            var actions: [UIContextualAction] = []
            switch row {
            case .request:
                let block = UIContextualAction(style: .destructive,
                                               title: String(localized: "Block"))
                { _, _, done in model.blockRequest(item); done(true) }
                block.image = UIImage(systemName: "hand.raised.fill")
                let accept = UIContextualAction(style: .normal,
                                                title: String(localized: "Accept"))
                { _, _, done in model.acceptRequest(item); done(true) }
                accept.image = UIImage(systemName: "checkmark")
                accept.backgroundColor = .systemGreen
                actions = [block, accept]
            case .chat:
                if let folder = parent.folder {
                    let out = UIContextualAction(style: .normal,
                                                 title: String(localized: "Remove from folder"))
                    { _, _, done in model.setChat(item.id, inFolder: folder, included: false); done(true) }
                    out.image = UIImage(systemName: "folder.badge.minus")
                    out.backgroundColor = .systemTeal
                    actions.append(out)
                }
                let archive = UIContextualAction(style: .normal,
                                                 title: String(localized: "Archive"))
                { _, _, done in model.toggleArchive(item); done(true) }
                archive.image = UIImage(systemName: "archivebox.fill")
                archive.backgroundColor = .systemGray
                actions.append(archive)
                let muted = MuteState.isMuted(muted: item.chat.muted, mutedUntil: item.chat.mutedUntil)
                let mute = UIContextualAction(style: .normal,
                                              title: String(localized: muted ? "Unmute" : "Mute"))
                { _, _, done in model.toggleMute(item); done(true) }
                mute.image = UIImage(systemName: muted ? "bell.fill" : "bell.slash.fill")
                mute.backgroundColor = .systemIndigo
                actions.append(mute)
                // delete comes last, further from the edge; the chat with
                // yourself stays, it is cleared from its info screen instead
                if item.chat.kind != .saved {
                    let delete = UIContextualAction(style: .destructive,
                                                    title: String(localized: "Delete"))
                    { [weak self] _, _, done in self?.parent.onDelete(item); done(true) }
                    delete.image = UIImage(systemName: "trash.fill")
                    actions.append(delete)
                }
            case .archive:
                return nil
            }
            let cfg = UISwipeActionsConfiguration(actions: actions)
            cfg.performsFirstActionWithFullSwipe = false
            return cfg
        }

        // MARK: folder context menu

        func collectionView(_ collectionView: UICollectionView,
                            contextMenuConfigurationForItemAt path: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
            guard let row = dataSource?.itemIdentifier(for: path),
                  case .chat = row, let item = item(for: row) else { return nil }
            let model = parent.model
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                guard let self else { return nil }
                let pin = UIAction(title: String(localized: item.chat.pinned ? "Unpin" : "Pin"),
                                   image: UIImage(systemName: item.chat.pinned ? "pin.slash" : "pin")) { _ in
                    model.togglePin(item)
                }
                let folders: [UIMenuElement]
                if model.folders.isEmpty {
                    folders = [
                        UIAction(title: String(localized: "New Folder"),
                                 image: UIImage(systemName: "folder.badge.plus")) { _ in
                            self.parent.onNewFolder()
                        },
                    ]
                } else {
                    let containing = model.folders(containing: item.id)
                    folders = model.folders.map { folder in
                        let inside = containing.contains(folder.id)
                        return UIAction(title: folder.title,
                                        image: UIImage(systemName: inside ? "checkmark" : "folder")) { _ in
                            model.setChat(item.id, inFolder: folder, included: !inside)
                        }
                    }
                }
                return UIMenu(children: [pin, UIMenu(options: .displayInline, children: folders)])
            }
        }
    }
}

/// A list cell whose separator starts where the row's text does, past the
/// avatar; the constraint survives reconfiguration, so it is added once.
final class ChatListCell: UICollectionViewListCell {
    private var separatorPinned = false

    func pinSeparator() {
        guard !separatorPinned else { return }
        separatorPinned = true
        separatorLayoutGuide.leadingAnchor
            .constraint(equalTo: contentView.leadingAnchor, constant: 76)
            .isActive = true
    }
}

/// The archive row's face; opening it is the collection's selection handler.
struct ArchiveRowLabel: View {
    let count: Int

    var body: some View {
        HStack {
            Image(systemName: "archivebox")
                .foregroundStyle(.secondary)
                .frame(width: 52, height: 52)
            Text("Archive").foregroundStyle(.secondary)
            Spacer()
            Text("\(count)").foregroundStyle(.secondary).font(.subheadline)
        }
        .contentShape(Rectangle())
    }
}
