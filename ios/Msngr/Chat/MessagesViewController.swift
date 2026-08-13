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
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if width != view.bounds.width {
            width = view.bounds.width
            // кэш планов раскладки зависит от ширины — сбрасываем при её изменении,
            // иначе бабблы, посчитанные под другую ширину, вылезают за экран
            BubbleLayout.clearCache()
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateInsets()
    }

    // MARK: - Инсеты (навбар сверху, инпут-бар/клавиатура снизу)

    /// Фрейм клавиатуры в координатах экрана; .null — клавиатура скрыта.
    private var keyboardScreenFrame: CGRect = .null

    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // клавиатура скрыта = уехала за нижний край экрана
        keyboardScreenFrame = end.minY >= UIScreen.main.bounds.maxY ? .null : end
        updateInsets()
    }

    /// Считает инсеты сам: safe area даёт перекрытие навбаром/индикатором,
    /// перекрытие клавиатурой считается от её фрейма в координатах view —
    /// часть, которую уже отработал внешний layout (SwiftUI), не учитывается повторно.
    private func updateInsets() {
        var bottomOverlap = view.safeAreaInsets.bottom
        if !keyboardScreenFrame.isNull {
            let kbInView = view.convert(keyboardScreenFrame, from: nil)
            bottomOverlap = max(bottomOverlap, view.bounds.maxY - kbInView.minY)
        }
        setInsets(top: view.safeAreaInsets.top + 6, bottom: max(0, bottomOverlap) + 6)
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        // список перевёрнут: top-инсет экрана = bottom контента
        let insets = UIEdgeInsets(top: bottom, left: 0, bottom: top, right: 0)
        guard insets != collectionView.contentInset else { return }
        let wasAtBottom = collectionView.contentOffset.y <= -collectionView.contentInset.top + 1
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = insets
        // лента была у низа — держим её у низа и с новым инсетом
        if wasAtBottom {
            collectionView.contentOffset = CGPoint(x: 0, y: -insets.top)
        }
    }

    /// Обновление ленты: точечный diff по id. Инвертированный список — index 0 внизу
    /// экрана. Вставки/удаления идут через performBatchUpdates, чтобы контент выше
    /// не прыгал при новом сообщении, когда пользователь читает историю.
    func apply(_ newItems: [ChatFeedItem]) {
        let old = items
        guard isViewLoaded else { items = newItems; return }
        if old.isEmpty {
            items = newItems
            collectionView.reloadData()
            return
        }
        let oldIds = old.map(\.id)
        let newIds = newItems.map(\.id)

        if oldIds == newIds {
            items = newItems
            for (i, item) in newItems.enumerated() where !contentEqual(old[i], item) {
                let indexPath = IndexPath(item: i, section: 0)
                // reload пересоздаёт ячейку и мгновенно обрывает идущую анимацию
                // появления (ack pending→sent приходит в первые миллисекунды полёта) —
                // видимую ячейку той же высоты обновляем на месте
                if case .message(let msg, let tightGap, let showTail, let showName, let authorName) = item,
                   msg.kind != .system,
                   let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
                    let plan = BubbleLayout.plan(for: msg, width: collectionView.bounds.width, tightGap: tightGap,
                                                 showTail: showTail, showName: showName, authorName: authorName)
                    if abs(cell.bounds.height - plan.cellHeight) < 0.5 {
                        configureMessageCell(cell, msg: msg, plan: plan)
                        continue
                    }
                }
                UIView.performWithoutAnimation { collectionView.reloadItems(at: [indexPath]) }
            }
            return
        }

        // вычисляем удаления и вставки по позициям id; при дубликате id берём
        // первую позицию, а не трапаемся (id обязаны быть уникальны, но краш хуже)
        let oldIndex = Dictionary(oldIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let newIndex = Dictionary(newIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let deletes = oldIds.enumerated().filter { newIndex[$0.element] == nil }
            .map { IndexPath(item: $0.offset, section: 0) }
        let inserts = newIds.enumerated().filter { oldIndex[$0.element] == nil }
            .map { IndexPath(item: $0.offset, section: 0) }
        // если структура изменилась слишком сложно (перестановки) — безопасный reload
        let onlyAppendOrRemove = deletes.count + inserts.count == abs(oldIds.count - newIds.count)
            || (deletes.isEmpty || inserts.isEmpty)
        guard onlyAppendOrRemove, deletes.count + inserts.count < 60 else {
            items = newItems
            collectionView.reloadData()
            return
        }

        let nearBottom = collectionView.contentOffset.y < 60
        items = newItems
        // новое сообщение внизу — анимируем появление (spring); вставки истории
        // сверху идут без анимации, чтобы не дёргать контент под пальцем
        // новое сообщение приходит в item 0 (низ инвертированного списка)
        let newBottom: (id: String, outgoing: Bool)? = {
            guard inserts.contains(where: { $0.item == 0 }),
                  case .message(let m, _, _, _, _) = newItems[0] else { return nil }
            return (m.id, m.isOutgoing)
        }()

        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates {
                if !deletes.isEmpty { collectionView.deleteItems(at: deletes) }
                if !inserts.isEmpty { collectionView.insertItems(at: inserts) }
            }
            // completion у batch-апдейта без анимации вызывается до создания
            // вставленной ячейки (cellForItem там nil) — материализуем её сразу
            // и запускаем анимацию появления синхронно, до первого кадра
            collectionView.layoutIfNeeded()
        }
        if let nb = newBottom,
           let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MessageCell {
            if nb.outgoing {
                let point = CGPoint(x: view.bounds.width - 28,
                                    y: view.bounds.height - collectionView.contentInset.top + 22)
                cell.animateSendFlight(fromScreenPoint: point, in: view)
            } else {
                cell.animateAppearance()
            }
        }
        // новое сообщение и мы были у низа — плавно подскроллим к нему
        if newIds.count > oldIds.count, inserts.contains(where: { $0.item == 0 }), nearBottom {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: true)
        }
    }

    /// Полная настройка ячейки сообщения: контент + колбэки (замыкания захватывают msg,
    /// при обновлении контента их нужно переустановить вместе с ним).
    private func configureMessageCell(_ cell: MessageCell, msg: Message, plan: BubbleLayoutPlan) {
        cell.configure(msg: msg, plan: plan)
        cell.onReply = { [weak self] in self?.onReply?(msg) }
        cell.onReact = { [weak self] emoji in self?.onReact?(msg, emoji) }
        cell.onContextAction = { [weak self] action in self?.onContextAction?(msg, action) }
        cell.onTapMedia = { [weak self] index, view in self?.onTapMedia?(msg, index, view) }
    }

    private func contentEqual(_ a: ChatFeedItem, _ b: ChatFeedItem) -> Bool {
        switch (a, b) {
        case let (.message(m1, t1, s1, _, _), .message(m2, t2, s2, _, _)):
            return m1 == m2 && t1 == t2 && s1 == s2
        case let (.dateSeparator(_, l1), .dateSeparator(_, l2)):
            return l1 == l2
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
        case .dateSeparator(_, let label):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "date", for: indexPath) as! DateSeparatorCell
            cell.configure(label)
            return cell
        case .message(let msg, let tightGap, let showTail, let showName, let authorName):
            if msg.kind == .system {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
                cell.configure(msg)
                return cell
            }
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "msg", for: indexPath) as! MessageCell
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName)
            configureMessageCell(cell, msg: msg, plan: plan)
            return cell
        }
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        switch items[indexPath.item] {
        case .dateSeparator:
            return CGSize(width: cv.bounds.width, height: 32)
        case .message(let msg, let tightGap, let showTail, let showName, let authorName):
            if msg.kind == .system {
                return CGSize(width: cv.bounds.width, height: 30)
            }
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName)
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
