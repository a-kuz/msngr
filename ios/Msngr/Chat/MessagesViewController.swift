import UIKit
import SwiftUI
import MsngrCore

/// Инвертированный список сообщений: UICollectionView, перевёрнутый по Y.
/// Ячейки тоже перевёрнуты — итог выглядит нормально, а «низ» чата это contentOffset 0:
/// мгновенное открытие с последних сообщений и естественная пагинация вверх.
final class MessagesViewController: UIViewController {
    var onVisibleTopChanged: ((Bool) -> Void)?   // показать/скрыть кнопку «вниз»
    var onNeedOlder: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onReact: ((Message, String) -> Void)?
    var onContextAction: ((Message, MessageContextAction) -> Void)?
    var onTapMedia: ((Message, Int, UIView) -> Void)?

    private(set) var collectionView: UICollectionView!
    private var items: [ChatFeedItem] = []
    private var width: CGFloat = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        let layout = UICollectionViewFlowLayout()
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.transform = CGAffineTransform(scaleX: 1, y: -1)
        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: "msg")
        collectionView.register(DateSeparatorCell.self, forCellWithReuseIdentifier: "date")
        collectionView.register(SystemCell.self, forCellWithReuseIdentifier: "system")
        view.addSubview(collectionView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if width != view.bounds.width {
            width = view.bounds.width
            collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        // список перевёрнут: top-инсет экрана = bottom контента
        collectionView.contentInset = UIEdgeInsets(top: bottom, left: 0, bottom: top, right: 0)
        collectionView.verticalScrollIndicatorInsets = collectionView.contentInset
    }

    /// Обновление ленты: diff по id, вставка новых снизу без прыжков.
    func apply(_ newItems: [ChatFeedItem]) {
        let old = items
        items = newItems
        guard isViewLoaded else { return }
        if old.isEmpty || abs(old.count - newItems.count) > 30 {
            collectionView.reloadData()
            return
        }
        let oldIds = old.map(\.id)
        let newIds = newItems.map(\.id)
        if oldIds == newIds {
            // контент мог измениться (статусы, реакции, редактирование) — точечно
            var changed: [IndexPath] = []
            for (i, item) in newItems.enumerated() where !contentEqual(old[i], item) {
                changed.append(IndexPath(item: i, section: 0))
            }
            if !changed.isEmpty {
                UIView.performWithoutAnimation {
                    collectionView.reloadItems(at: changed)
                }
            }
            return
        }
        collectionView.reloadData()
        // новое сообщение при позиции у низа — плавный подскролл
        if newIds.count > oldIds.count, collectionView.contentOffset.y < 60 {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: true)
        }
    }

    private func contentEqual(_ a: ChatFeedItem, _ b: ChatFeedItem) -> Bool {
        switch (a, b) {
        case let (.message(m1, g1, _, _), .message(m2, g2, _, _)):
            return m1 == m2 && g1 == g2
        case let (.dateSeparator(d1), .dateSeparator(d2)):
            return d1 == d2
        default:
            return false
        }
    }

    func scrollToBottom(animated: Bool = true) {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: animated)
    }

    func scrollTo(msgId: String) {
        if let idx = items.firstIndex(where: { $0.id == msgId }) {
            collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically, animated: true)
        }
    }
}

enum MessageContextAction {
    case reply, copy, forward, edit, pin, deleteForMe, deleteForAll
}

extension MessagesViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ cv: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        switch items[indexPath.item] {
        case .dateSeparator(let label):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "date", for: indexPath) as! DateSeparatorCell
            cell.configure(label)
            return cell
        case .message(let msg, let grouped, let showName, let authorName):
            if msg.kind == .system {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
                cell.configure(msg)
                return cell
            }
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "msg", for: indexPath) as! MessageCell
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, grouped: grouped,
                                         showName: showName, authorName: authorName)
            cell.configure(msg: msg, plan: plan)
            cell.onReply = { [weak self] in self?.onReply?(msg) }
            cell.onReact = { [weak self] emoji in self?.onReact?(msg, emoji) }
            cell.onContextAction = { [weak self] action in self?.onContextAction?(msg, action) }
            cell.onTapMedia = { [weak self] index, view in self?.onTapMedia?(msg, index, view) }
            return cell
        }
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        switch items[indexPath.item] {
        case .dateSeparator:
            return CGSize(width: cv.bounds.width, height: 32)
        case .message(let msg, let grouped, let showName, let authorName):
            if msg.kind == .system {
                return CGSize(width: cv.bounds.width, height: 30)
            }
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, grouped: grouped,
                                         showName: showName, authorName: authorName)
            return CGSize(width: cv.bounds.width, height: plan.cellHeight)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onVisibleTopChanged?(scrollView.contentOffset.y > 300)
        // пагинация: близко к «верху» истории (в инвертированной системе — к концу контента)
        if scrollView.contentOffset.y > scrollView.contentSize.height - scrollView.bounds.height - 600 {
            onNeedOlder?()
        }
    }
}

// MARK: - Вспомогательные ячейки

final class DateSeparatorCell: UICollectionViewCell {
    private let label = UILabel()
    private let capsule = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        capsule.layer.cornerRadius = 11
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        contentView.addSubview(capsule)
        capsule.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        label.text = text
        label.sizeToFit()
        let w = label.bounds.width + 20
        capsule.frame = CGRect(x: (contentView.bounds.width - w) / 2, y: 5, width: w, height: 22)
        label.frame = CGRect(x: 10, y: 0, width: label.bounds.width, height: 22)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let text = label.text { configure(text) }
    }
}

final class SystemCell: UICollectionViewCell {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        label.frame = contentView.bounds
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ msg: Message) {
        let t = msg.text ?? ""
        if t.hasPrefix("identity_changed:") {
            label.text = "Код безопасности собеседника изменился"
        } else if t == "undecryptable" {
            label.text = "Сообщение не может быть расшифровано на этом устройстве"
        } else {
            label.text = t
        }
    }
}
