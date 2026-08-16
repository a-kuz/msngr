import UIKit
import SwiftUI
import SafariServices
import MsngrCore

/// Инвертированный список сообщений: UICollectionView, перевёрнутый по Y.
/// Ячейки тоже перевёрнуты — итог выглядит нормально, а «низ» чата это contentOffset 0:
/// мгновенное открытие с последних сообщений и естественная пагинация вверх.
final class MessagesViewController: UIViewController, UIGestureRecognizerDelegate {
    /// Лента у низа: самый новый элемент реально виден на экране.
    /// От этого зависят кнопка «вниз» и отметка прочтения.
    var onAtBottomChanged: ((Bool) -> Void)?
    var onNeedOlder: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onReact: ((Message, String) -> Void)?
    var onContextAction: ((Message, MessageContextAction) -> Void)?
    var onTapMedia: ((Message, Int, UIView) -> Void)?
    /// тап по цитате в баббле-ответе (переход к оригиналу)
    var onTapReplyQuote: ((Message) -> Void)?
    /// тап по строке в режиме мультивыбора
    var onToggleSelection: ((Message) -> Void)?
    /// тап по статус-бару: экран ведёт ленту к началу чата
    var onScrollToStart: (() -> Void)?
    /// свайп от левой кромки: возврат к списку чатов
    var onSwipeBack: (() -> Void)?

    private(set) var collectionView: UICollectionView!
    private var items: [ChatFeedItem] = []
    private var width: CGFloat = 0
    /// сообщение, которое ждёт вспышки подсветки после перехода по цитате
    private var pendingHighlightId: String?
    private var selectionMode = false
    private var selectedIds: Set<String> = []
    /// Последнее посчитанное «лента у низа»; стартовое значение совпадает
    /// с состоянием пустой ленты, поэтому первый пересчёт молчит.
    private var atBottom = true
    private var recomputingAtBottom = false
    /// Счётчик своих отправок, уже отработанный лентой.
    private var seenSendTick = 0
    /// Возврат свайпом: кромка своя, потому что системный жест на этом экране
    /// не начинается.
    private let backSwipe = UIPanGestureRecognizer()
    /// Отправка ждёт своего сообщения: оно обязано приехать в низ ленты
    /// и появиться там с анимацией, из какого бы места истории его ни отправили.
    private var awaitingOwnSend = false

    /// Своя отправка: лента уезжает к концу сразу, не дожидаясь, пока сообщение
    /// ляжет в базу и придёт из наблюдения.
    func noteSendTick(_ tick: Int) {
        guard tick != seenSendTick else { return }
        seenSendTick = tick
        awaitingOwnSend = true
        guard isViewLoaded else { return }
        scrollToBottom(animated: false)
    }

    /// Пришло ли в этом обновлении своё только что отправленное сообщение.
    /// Ждать приходится не только вставку в существующую ленту: окно, стоявшее
    /// на прочитанной истории, снова цепляется за новейшие, и лента приезжает
    /// другим набором сообщений целиком.
    private func ownSendLanded(newFirst: ChatFeedItem?, oldIds: Set<String>) -> Bool {
        guard awaitingOwnSend, case .message(let m, _, _, _, _, _)? = newFirst, m.isOutgoing,
              !oldIds.contains(m.id) else { return false }
        awaitingOwnSend = false
        return true
    }

    /// Ставит ленту на своё новое сообщение и играет его появление.
    private func landOwnMessage() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MessageCell
        else { return }
        let point = CGPoint(x: view.bounds.width - 28,
                            y: view.bounds.height - collectionView.contentInset.top + 22)
        cell.animateSendFlight(fromScreenPoint: point, in: view)
    }

    /// Состояние мультивыбора: видимые ячейки перестраиваются на месте
    /// (reload оборвал бы анимации ленты), новые получают его при настройке.
    func setSelection(mode: Bool, ids: Set<String>) {
        guard mode != selectionMode || ids != selectedIds else { return }
        let animated = isViewLoaded && view.window != nil
        selectionMode = mode
        selectedIds = ids
        for case let cell as MessageCell in collectionView.visibleCells {
            guard let id = cell.messageId else { continue }
            cell.setSelection(mode: mode, selected: ids.contains(id), animated: animated)
        }
    }

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
        collectionView.register(UnreadMarkerCell.self, forCellWithReuseIdentifier: "unread")
        view.addSubview(collectionView)
        backSwipe.addTarget(self, action: #selector(handleBackSwipe(_:)))
        backSwipe.delegate = self
        view.addGestureRecognizer(backSwipe)
        // лента ждёт отказа кромки: вне кромки жест не начинается вовсе,
        // поэтому скролл остаётся мгновенным
        collectionView.panGestureRecognizer.require(toFail: backSwipe)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    /// Возврат свайпом от левой кромки. Системный жест на этом экране не
    /// начинается: шапка рисует свою кнопку возврата, а с убранной системной
    /// навигация своему переходу отказывает — ни снятый делегат, ни включённый
    /// заново распознаватель этого не меняют. Поэтому кромка своя.
    @objc private func handleBackSwipe(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        if g.translation(in: view).x > 70 || g.velocity(in: view).x > 500 { onSwipeBack?() }
    }

    /// Жест возврата берёт только касания от кромки, идущие вправо; всё
    /// остальное остаётся ленте.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === backSwipe else { return true }
        let start = backSwipe.location(in: nil).x - backSwipe.translation(in: nil).x
        let v = backSwipe.velocity(in: view)
        return start < MessageCell.backSwipeEdge && v.x > abs(v.y)
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
        // клавиатура открылась или уехала — видимая область другая
        updateAtBottom(layoutFirst: true)
    }

    /// Обновление ленты: точечный diff по id. Инвертированный список — index 0 внизу
    /// экрана. Вставки/удаления идут через performBatchUpdates, чтобы контент выше
    /// не прыгал при новом сообщении, когда пользователь читает историю.
    func apply(_ newItems: [ChatFeedItem]) {
        let old = items
        guard isViewLoaded else { items = newItems; return }
        // лента опустела (очистка истории): дифф удалял бы все позиции разом
        // посреди идущей анимации вставки, и якорь чтения указывал бы в пустоту
        if newItems.isEmpty {
            items = []
            collectionView.layer.removeAllAnimations()
            collectionView.reloadData()
            updateAtBottom(layoutFirst: true)
            return
        }
        if old.isEmpty {
            items = newItems
            collectionView.reloadData()
            // открытие чата с непрочитанными: лента встаёт на плашку.
            // Коллекция инвертирована — визуальный верх экрана это .bottom
            if let idx = newItems.firstIndex(where: { if case .unreadMarker = $0 { return true }; return false }) {
                collectionView.layoutIfNeeded()
                collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .bottom, animated: false)
            }
            updateAtBottom(layoutFirst: true)
            return
        }
        let oldIds = old.map(\.id)
        let newIds = newItems.map(\.id)

        if oldIds == newIds {
            items = newItems
            for (i, item) in newItems.enumerated() where !contentEqual(old[i], item) {
                refreshItem(at: i, item: item)
            }
            // высота могла измениться (правка текста) — геометрия другая
            updateAtBottom(layoutFirst: true)
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
        // якорь на то, что человек читает: список инвертирован, вставка нового
        // сообщения идёт в item 0 и сдвигает под неизменным contentOffset весь
        // контент выше. Запоминаем верхний видимый элемент и его положение на
        // экране, чтобы вернуть их после обновления
        let anchor = readingAnchor()
        // своё новое сообщение лежит первым элементом инвертированной ленты
        let ownAtBottom: Bool = {
            guard case .message(let m, _, _, _, _, _)? = newItems.first else { return false }
            return m.isOutgoing && oldIndex[newIds[0]] == nil
        }()
        // вызывается всегда: он же снимает ожидание отправки
        let sendLanded = ownSendLanded(newFirst: newItems.first, oldIds: Set(oldIds))
        let ownLanded = ownAtBottom || sendLanded

        // если структура изменилась слишком сложно (перестановки) — безопасный reload
        let onlyAppendOrRemove = deletes.count + inserts.count == abs(oldIds.count - newIds.count)
            || (deletes.isEmpty || inserts.isEmpty)
        guard onlyAppendOrRemove, deletes.count + inserts.count < 60 else {
            items = newItems
            collectionView.reloadData()
            restore(anchor)
            // своё новое сообщение внизу обязано стать видимым и на reload-пути
            if ownLanded { landOwnMessage() }
            updateAtBottom(layoutFirst: true)
            return
        }

        // состояние до вставки: был ли самый новый элемент на экране
        let wasAtBottom = atBottom
        items = newItems

        // дифф из одного лишь удаления плашки непрочитанных — уходит с анимацией
        // (свернул в шторку / отправил своё / поставил реакцию)
        let onlyMarkerDelete = inserts.isEmpty && !deletes.isEmpty
            && deletes.allSatisfy { if case .unreadMarker = old[$0.item] { return true }; return false }
        if onlyMarkerDelete {
            // пересчёт в completion: до конца анимации набор видимых ячеек ещё
            // со старыми индексами, а layoutIfNeeded оборвал бы уход плашки
            collectionView.performBatchUpdates({ collectionView.deleteItems(at: deletes) },
                                               completion: { [weak self] _ in self?.updateAtBottom() })
            return
        }
        // новое сообщение внизу — анимируем появление (spring); вставки истории
        // сверху идут без анимации, чтобы не дёргать контент под пальцем
        // новое сообщение приходит в item 0 (низ инвертированного списка)
        let newBottom: (id: String, outgoing: Bool)? = {
            guard inserts.contains(where: { $0.item == 0 }),
                  case .message(let m, _, _, _, _, _) = newItems[0] else { return nil }
            return (m.id, m.isOutgoing)
        }()

        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates {
                if !deletes.isEmpty { collectionView.deleteItems(at: deletes) }
                if !inserts.isEmpty { collectionView.insertItems(at: inserts) }
            }
            // своё сообщение показываем всегда, из любой глубины истории:
            // мгновенный переход к низу до материализации ячейки — анимированный
            // скролл отсюда гонялся бы с полётом баббла и отменялся следующим
            // апдейтом ленты (ack), из-за чего иногда не доезжал
            if newBottom?.outgoing == true {
                collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
            }
            // completion у batch-апдейта без анимации вызывается до создания
            // вставленной ячейки (cellForItem там nil) — материализуем её сразу
            // и запускаем анимацию появления синхронно, до первого кадра
            collectionView.layoutIfNeeded()
            if newBottom?.outgoing != true { restore(anchor) }
        }
        // уцелевшие элементы могли сменить содержимое в том же апдейте, где что-то
        // вставилось: у соседа сверху пропадает хвостик и меняется зазор, когда
        // сообщение продолжает его серию, растёт счётчик плашки непрочитанных.
        // Дифф по id такие ячейки не пересоздаёт — обновляем их отдельно
        for (i, item) in newItems.enumerated() {
            guard let oldIdx = oldIndex[item.id], !contentEqual(old[oldIdx], item) else { continue }
            refreshItem(at: i, item: item)
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
        // чужое новое сообщение: плавно подскролливаем, только если пользователь
        // и так был у низа — читающего историю не дёргаем
        if let nb = newBottom, !nb.outgoing, wasAtBottom {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: true)
        }
        // вставка и удаление меняют геометрию без события скролла
        updateAtBottom()
    }

    /// Обновление уже стоящей в ленте позиции, содержимое которой изменилось.
    /// reload пересоздаёт ячейку и мгновенно обрывает идущую анимацию появления
    /// (ack pending→sent приходит в первые миллисекунды полёта), поэтому видимую
    /// ячейку той же высоты перенастраиваем на месте.
    private func refreshItem(at index: Int, item: ChatFeedItem) {
        let indexPath = IndexPath(item: index, section: 0)
        switch item {
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName)
            where msg.kind != .system:
            if let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
                let plan = BubbleLayout.plan(for: msg, width: collectionView.bounds.width, tightGap: tightGap,
                                             showTail: showTail, showName: showName, authorName: authorName,
                                             replyAuthorName: replyAuthorName)
                if abs(cell.bounds.height - plan.cellHeight) < 0.5 {
                    configureMessageCell(cell, msg: msg, plan: plan)
                    return
                }
            }
        case .unreadMarker(_, let count):
            if let cell = collectionView.cellForItem(at: indexPath) as? UnreadMarkerCell {
                cell.configure(count: count)
                return
            }
        default:
            break
        }
        UIView.performWithoutAnimation { collectionView.reloadItems(at: [indexPath]) }
    }

    /// Полная настройка ячейки сообщения: контент + колбэки (замыкания захватывают msg,
    /// при обновлении контента их нужно переустановить вместе с ним).
    private func configureMessageCell(_ cell: MessageCell, msg: Message, plan: BubbleLayoutPlan) {
        cell.configure(msg: msg, plan: plan)
        cell.onReply = { [weak self] in self?.onReply?(msg) }
        cell.onReact = { [weak self] emoji in self?.onReact?(msg, emoji) }
        cell.onContextAction = { [weak self] action in self?.onContextAction?(msg, action) }
        cell.onTapMedia = { [weak self] index, view in self?.onTapMedia?(msg, index, view) }
        cell.onTapLink = { [weak self] url in self?.open(url) }
        cell.onTapReplyQuote = { [weak self] in self?.onTapReplyQuote?(msg) }
        cell.onToggleSelection = { [weak self] in self?.onToggleSelection?(msg) }
        cell.setSelection(mode: selectionMode, selected: selectedIds.contains(msg.id), animated: false)
    }

    /// Ссылка из сообщения открывается во встроенном браузере: чат остаётся
    /// на месте, возврат — свайпом вниз.
    private func open(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            UIApplication.shared.open(url)
            return
        }
        let safari = SFSafariViewController(url: url)
        safari.preferredControlTintColor = UIColor(Theme.accent)
        present(safari, animated: true)
    }

    private func contentEqual(_ a: ChatFeedItem, _ b: ChatFeedItem) -> Bool {
        switch (a, b) {
        case let (.message(m1, t1, s1, _, _, _), .message(m2, t2, s2, _, _, _)):
            return m1 == m2 && t1 == t2 && s1 == s2
        case let (.dateSeparator(_, l1), .dateSeparator(_, l2)):
            return l1 == l2
        case let (.unreadMarker(_, c1), .unreadMarker(_, c2)):
            return c1 == c2
        case (.unreadable, .unreadable), (.historyStart, .historyStart):
            return true
        default:
            return false
        }
    }

    func scrollToBottom(animated: Bool = true) {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: animated)
        if !animated { updateAtBottom(layoutFirst: true) }
    }

    /// Начало чата: список перевёрнут, самое старое сообщение лежит последним,
    /// то есть в конце контента. Дальний конец берём без анимации — прокрутка
    /// через тысячи ячеек всё равно не читается.
    func scrollToStart() {
        guard isViewLoaded, !items.isEmpty else { return }
        collectionView.layoutIfNeeded()
        let maxOffset = collectionView.contentSize.height - collectionView.bounds.height
            + collectionView.contentInset.bottom
        let target = max(-collectionView.contentInset.top, maxOffset)
        let far = abs(target - collectionView.contentOffset.y) > collectionView.bounds.height * 3
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: !far)
        if far { updateAtBottom(layoutFirst: true) }
    }

    // MARK: - Удержание позиции чтения

    /// Элемент у верхнего края экрана и его положение относительно него.
    private struct ReadingAnchor {
        let id: String
        let offsetInView: CGFloat
    }

    /// Якорь берётся, только когда человек читает историю: у низа ленту ведут
    /// новые сообщения, и удерживать там нечего.
    private func readingAnchor() -> ReadingAnchor? {
        guard isViewLoaded, !atBottom else { return nil }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        // список инвертирован: визуальный верх экрана — элемент с наибольшим maxY
        let top = collectionView.indexPathsForVisibleItems.compactMap { path -> (IndexPath, CGRect)? in
            guard let attrs = collectionView.layoutAttributesForItem(at: path),
                  attrs.frame.intersects(visibleRect) else { return nil }
            return (path, attrs.frame)
        }.max { $0.1.maxY < $1.1.maxY }
        guard let top, top.0.item < items.count else { return nil }
        return ReadingAnchor(id: items[top.0.item].id,
                             offsetInView: top.1.maxY - collectionView.contentOffset.y)
    }

    /// Возвращает якорный элемент туда же, где он был до обновления.
    private func restore(_ anchor: ReadingAnchor?) {
        guard let anchor, let idx = items.firstIndex(where: { $0.id == anchor.id }) else { return }
        collectionView.layoutIfNeeded()
        guard let attrs = collectionView.layoutAttributesForItem(at: IndexPath(item: idx, section: 0))
        else { return }
        let target = attrs.frame.maxY - anchor.offsetInView
        guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(CGPoint(x: collectionView.contentOffset.x, y: target),
                                        animated: false)
    }

    // MARK: - «Лента у низа»

    /// Решение «лента у низа»: список инвертирован, самый новый элемент лежит
    /// в item 0, и низ — это когда он попал в число видимых. Пустая лента — низ.
    static func isAtBottom(visibleItems: [Int], totalItems: Int) -> Bool {
        guard totalItems > 0 else { return true }
        return visibleItems.contains(0)
    }

    /// Пересчёт по фактически видимым ячейкам. Смещение в точках тут не годится:
    /// при открытии чата лента встаёт на плашку непрочитанных, и самые новые
    /// сообщения при этом на экране.
    /// layoutFirst — прогнать раскладку до опроса: после reloadData, вставок и
    /// смены инсетов набор видимых ячеек ещё старый.
    private func updateAtBottom(layoutFirst: Bool = false) {
        guard isViewLoaded, !recomputingAtBottom else { return }
        recomputingAtBottom = true
        defer { recomputingAtBottom = false }
        if layoutFirst { collectionView.layoutIfNeeded() }
        // из bounds вычитаем инсеты: то, что лежит под инпут-баром или навбаром,
        // пользователь не видит
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let visible = collectionView.indexPathsForVisibleItems.filter { path in
            guard let attrs = collectionView.layoutAttributesForItem(at: path) else { return false }
            return attrs.frame.intersects(visibleRect)
        }.map(\.item)
        let value = Self.isAtBottom(visibleItems: visible, totalItems: items.count)
        guard value != atBottom else { return }
        atBottom = value
        // колбэк меняет @State, а пересчёт бывает и внутри apply(), то есть
        // посреди обновления SwiftUI-view — отдаём следующим тиком
        DispatchQueue.main.async { [weak self] in
            guard let self, self.atBottom == value else { return }
            self.onAtBottomChanged?(value)
        }
    }

    /// Скролл к сообщению по серверному msgId или локальному id.
    /// Возвращает false, если сообщения нет в загруженной ленте (нужна догрузка истории).
    @discardableResult
    func scrollTo(msgId: String, highlight: Bool = false) -> Bool {
        guard let idx = index(ofMsgId: msgId) else { return false }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically, animated: true)
        if highlight {
            pendingHighlightId = msgId
            // ячейка уже на экране — вспышка идёт параллельно доводке скролла;
            // иначе сработает, когда ячейка материализуется или скролл доедет
            flushPendingHighlight()
        }
        return true
    }

    private func index(ofMsgId msgId: String) -> Int? {
        Self.index(ofMsgId: msgId, in: items)
    }

    /// Позиция сообщения в ленте: свои сообщения лежат под clientMsgId,
    /// а ссылаются на них (цитата, закреп) серверным msgId.
    static func index(ofMsgId msgId: String, in items: [ChatFeedItem]) -> Int? {
        items.firstIndex { item in
            guard case .message(let m, _, _, _, _, _) = item else { return false }
            return m.id == msgId || m.msgId == msgId
        }
    }

    private func flushPendingHighlight() {
        guard let id = pendingHighlightId, let idx = index(ofMsgId: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? MessageCell else { return }
        pendingHighlightId = nil
        cell.flashHighlight()
    }
}

enum MessageContextAction {
    case reply, copy, selectText, forward, select, edit, pin, delete
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
        case .unreadMarker(_, let count):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "unread", for: indexPath) as! UnreadMarkerCell
            cell.configure(count: count)
            return cell
        case .unreadable:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
            cell.configure(text: "Сообщение ещё не загружено")
            return cell
        case .historyStart:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
            cell.configure(text: "История начинается здесь")
            return cell
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName):
            if msg.kind == .system {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
                cell.configure(msg)
                return cell
            }
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "msg", for: indexPath) as! MessageCell
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName,
                                         replyAuthorName: replyAuthorName)
            configureMessageCell(cell, msg: msg, plan: plan)
            // ячейка оригинала создаётся уже по ходу скролла к нему — вспышка ждала её
            if let id = pendingHighlightId, id == msg.id || id == msg.msgId {
                pendingHighlightId = nil
                DispatchQueue.main.async { cell.flashHighlight() }
            }
            return cell
        }
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        switch items[indexPath.item] {
        case .dateSeparator:
            return CGSize(width: cv.bounds.width, height: 32)
        case .unreadMarker:
            return CGSize(width: cv.bounds.width, height: 36)
        case .unreadable, .historyStart:
            return CGSize(width: cv.bounds.width, height: 30)
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName):
            if msg.kind == .system {
                return CGSize(width: cv.bounds.width, height: 30)
            }
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName,
                                         replyAuthorName: replyAuthorName)
            return CGSize(width: cv.bounds.width, height: plan.cellHeight)
        }
    }

    /// Тап по статус-бару. Системная прокрутка «вверх» в перевёрнутом списке
    /// уехала бы к самым новым сообщениям — начало чата это другой конец,
    /// и ведёт туда экран сам.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        onScrollToStart?()
        return false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flushPendingHighlight()
        updateAtBottom(layoutFirst: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateAtBottom()
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

/// Плашка-разделитель «N непрочитанных сообщений»: полоса на всю ширину,
/// скроллится вместе с лентой.
final class UnreadMarkerCell: UICollectionViewCell {
    private let label = UILabel()
    private let band = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        band.backgroundColor = .tertiarySystemFill
        band.autoresizingMask = [.flexibleWidth]
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(band)
        band.addSubview(label)
        band.frame = CGRect(x: 0, y: 5, width: contentView.bounds.width, height: 26)
        label.frame = band.bounds
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int) {
        label.text = Self.title(count: count)
    }

    /// «1 непрочитанное сообщение / 2 непрочитанных сообщения / 5 непрочитанных сообщений»
    static func title(count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let (adj, noun): (String, String)
        if mod100 / 10 == 1 {
            (adj, noun) = ("непрочитанных", "сообщений")
        } else if mod10 == 1 {
            (adj, noun) = ("непрочитанное", "сообщение")
        } else if (2...4).contains(mod10) {
            (adj, noun) = ("непрочитанных", "сообщения")
        } else {
            (adj, noun) = ("непрочитанных", "сообщений")
        }
        return "\(count) \(adj) \(noun)"
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
        } else {
            label.text = t
        }
    }

    func configure(text: String) {
        label.text = text
    }
}
