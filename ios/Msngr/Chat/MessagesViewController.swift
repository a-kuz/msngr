import UIKit
import SwiftUI
import SafariServices
import MsngrCore

/// Inverted message list: a UICollectionView flipped along Y, with the cells
/// flipped back so the result reads normally. The bottom of the chat is then
/// contentOffset 0: it opens instantly on the latest messages and pages upwards
/// the way a scroll view already wants to.
final class MessagesViewController: UIViewController {
    /// The feed is at the bottom: the newest item is really on screen. The scroll
    /// to bottom button and the read receipt both depend on this.
    var onAtBottomChanged: ((Bool) -> Void)?
    var onNeedOlder: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onReact: ((Message, String) -> Void)?
    var onContextAction: ((Message, MessageContextAction) -> Void)?
    var onTapMedia: ((Message, Int, UIView) -> Void)?
    /// Tap on the quote inside a reply bubble, which jumps to the original.
    var onTapReplyQuote: ((Message) -> Void)?
    /// Tap on a row while multi-select is on.
    var onToggleSelection: ((Message) -> Void)?

    private(set) var collectionView: UICollectionView!
    private var items: [ChatFeedItem] = []
    private var width: CGFloat = 0
    /// The message waiting for its highlight flash after a jump from a quote.
    private var pendingHighlightId: String?
    private var selectionMode = false
    private var selectedIds: Set<String> = []
    /// Last computed "feed is at the bottom". The initial value matches an empty
    /// feed, so the first recomputation stays quiet.
    private var atBottom = true
    private var recomputingAtBottom = false

    /// Multi-select state: visible cells are reconfigured in place, because a reload
    /// would cut off the feed's animations; new cells pick it up in configure.
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
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(typeScaleChanged),
                                               name: .typeScaleChanged, object: nil)
    }

    /// Reader changed their text size: every cached plan was measured against
    /// the old font, so the feed re-measures from scratch and puts the message
    /// the reader was looking at back where it was.
    @objc private func typeScaleChanged() {
        guard isViewLoaded else { return }
        let anchor = readingAnchor()
        BubbleLayout.clearCache()
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.reloadData()
        collectionView.layoutIfNeeded()
        if anchor != nil {
            restore(anchor)
        } else {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
        }
        updateAtBottom(layoutFirst: true)
    }

    /// Frame clock of the measurement run: every screen refresh is recorded, so
    /// a gap in the trace is a frame the feed missed.
    private var frameLink: CADisplayLink?
    private var lastFrame: CFTimeInterval = 0

    @objc private func frameTick(_ link: CADisplayLink) {
        if lastFrame > 0 {
            PerfTrace.shared.span("frame", duration: link.timestamp - lastFrame)
        }
        lastFrame = link.timestamp
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if PerfTrace.shared.isEnabled, frameLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
            link.add(to: .main, forMode: .common)
            frameLink = link
        }
        // the chat header draws its own back button and the system one is hidden;
        // hiding it also disables the swipe-back gesture, so bring it back by
        // dropping the delegate that suppresses it
        if let pop = navigationController?.interactivePopGestureRecognizer {
            pop.delegate = nil
            pop.isEnabled = true
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        frameLink?.invalidate()
        frameLink = nil
        lastFrame = 0
        PerfTrace.shared.flush()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if width != view.bounds.width {
            width = view.bounds.width
            // the layout plan cache is keyed to the width, so a width change drops
            // it; otherwise bubbles measured for another width run off the screen
            BubbleLayout.clearCache()
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateInsets()
    }

    // MARK: - Insets (nav bar above, input bar and keyboard below)

    /// Keyboard frame in screen coordinates; .null means the keyboard is hidden.
    private var keyboardScreenFrame: CGRect = .null

    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // hidden means it moved past the bottom edge of the screen
        keyboardScreenFrame = end.minY >= UIScreen.main.bounds.maxY ? .null : end
        updateInsets()
    }

    /// Computes the insets itself: the safe area gives the overlap with the nav bar
    /// and the home indicator, while the keyboard overlap is measured from its frame
    /// converted into view coordinates, so the part the outer SwiftUI layout has
    /// already handled is not counted twice.
    private func updateInsets() {
        var bottomOverlap = view.safeAreaInsets.bottom
        if !keyboardScreenFrame.isNull {
            let kbInView = view.convert(keyboardScreenFrame, from: nil)
            bottomOverlap = max(bottomOverlap, view.bounds.maxY - kbInView.minY)
        }
        setInsets(top: view.safeAreaInsets.top + 6, bottom: max(0, bottomOverlap) + 6)
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        // the list is flipped: the screen's top inset is the content's bottom
        let insets = UIEdgeInsets(top: bottom, left: 0, bottom: top, right: 0)
        guard insets != collectionView.contentInset else { return }
        let wasAtBottom = collectionView.contentOffset.y <= -collectionView.contentInset.top + 1
        collectionView.contentInset = insets
        collectionView.verticalScrollIndicatorInsets = insets
        // it was at the bottom, so keep it there under the new inset
        if wasAtBottom {
            collectionView.contentOffset = CGPoint(x: 0, y: -insets.top)
        }
        // the keyboard came up or went away, so the visible area is different
        updateAtBottom(layoutFirst: true)
    }

    /// Updates the feed with a pointwise diff by id. The list is inverted, so item 0
    /// is at the bottom of the screen. Inserts and deletes go through
    /// performBatchUpdates so that the content above does not jump when a message
    /// arrives while the reader is in the history.
    func apply(_ newItems: [ChatFeedItem]) {
        PerfTrace.shared.measure("feed.ui.apply", info: ["items": Double(newItems.count)]) {
            applyDiff(newItems)
        }
    }

    private func applyDiff(_ newItems: [ChatFeedItem]) {
        let old = items
        guard isViewLoaded else { items = newItems; return }
        // the feed went empty (history cleared): a diff would delete every position
        // at once in the middle of a running insert animation, and the reading
        // anchor would point at nothing
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
            // opening a chat with unread messages parks the feed on the banner.
            // The collection is inverted, so the visual top of the screen is .bottom
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
            // an edit can change a height, so the geometry is different
            updateAtBottom(layoutFirst: true)
            return
        }

        // deletes and inserts come from the positions of the ids; a duplicate id
        // resolves to its first position instead of trapping, since ids are meant
        // to be unique but a crash is worse than a misplaced row
        let oldIndex = Dictionary(oldIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let newIndex = Dictionary(newIds.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let deletes = oldIds.enumerated().filter { newIndex[$0.element] == nil }
            .map { IndexPath(item: $0.offset, section: 0) }
        let inserts = newIds.enumerated().filter { oldIndex[$0.element] == nil }
            .map { IndexPath(item: $0.offset, section: 0) }
        // anchor on what the reader is looking at: the list is inverted, so a new
        // message is inserted at item 0 and shifts everything above it while
        // contentOffset stays put. Remember the top visible item and where it sits
        // on screen, then put it back after the update
        let anchor = readingAnchor()

        // a structural change too complex to diff (a reordering) falls back to reload
        let onlyAppendOrRemove = deletes.count + inserts.count == abs(oldIds.count - newIds.count)
            || (deletes.isEmpty || inserts.isEmpty)
        guard onlyAppendOrRemove, deletes.count + inserts.count < 60 else {
            items = newItems
            collectionView.reloadData()
            restore(anchor)
            // our own new message at the bottom has to become visible on this path too
            if case .message(let m, _, _, _, _, _)? = newItems.first, m.isOutgoing,
               oldIndex[newIds[0]] == nil {
                collectionView.layoutIfNeeded()
                collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
            }
            updateAtBottom(layoutFirst: true)
            return
        }

        // state before the insert: was the newest item on screen
        let wasAtBottom = atBottom
        items = newItems

        // a diff that only removes the unread banner animates it away (the reader
        // pulled down the shade, sent something, or added a reaction)
        let onlyMarkerDelete = inserts.isEmpty && !deletes.isEmpty
            && deletes.allSatisfy { if case .unreadMarker = old[$0.item] { return true }; return false }
        if onlyMarkerDelete {
            // recompute in the completion: until the animation ends the visible
            // cells still carry the old indices, and layoutIfNeeded would cut the
            // banner's exit short
            collectionView.performBatchUpdates({ collectionView.deleteItems(at: deletes) },
                                               completion: { [weak self] _ in self?.updateAtBottom() })
            return
        }
        // a new message at the bottom gets a spring appearance; history inserted at
        // the top comes in without animation so the content under the finger stays
        // still. A new message always arrives at item 0, the bottom of the
        // inverted list
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
            // our own message is always shown, from any depth of history: jump to
            // the bottom instantly, before the cell materialises. An animated
            // scroll from here would race the bubble's flight and get cancelled by
            // the next feed update (the ack), so it sometimes never arrived
            if newBottom?.outgoing == true {
                collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
            }
            // with animation off, the batch update's completion runs before the
            // inserted cell exists (cellForItem is nil there), so materialise it
            // here and start the appearance animation synchronously, before the
            // first frame
            collectionView.layoutIfNeeded()
            if newBottom?.outgoing != true { restore(anchor) }
        }
        // surviving items can change their content in the same update that inserted
        // something: the neighbour above loses its tail and changes its gap when the new
        // message continues its series, and the unread banner's counter grows. A diff by
        // id does not recreate those cells, so they are refreshed separately
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
        // someone else's new message: scroll down smoothly only if the reader was at the
        // bottom anyway; a reader in the history is left alone
        if let nb = newBottom, !nb.outgoing, wasAtBottom {
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: true)
        }
        // inserts and deletes change the geometry without a scroll event
        updateAtBottom()
    }

    /// Refreshes a position that already stands in the feed and whose content changed.
    /// A reload recreates the cell and instantly cuts off a running appearance animation
    /// (the pending→sent ack lands in the first milliseconds of the flight), so a visible
    /// cell of the same height is reconfigured in place instead.
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

    /// Full setup of a message cell: content plus callbacks. The closures capture msg, so
    /// when the content is updated they have to be reinstalled along with it.
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

    /// A link from a message opens in the built-in browser: the chat stays where it is
    /// and a swipe down brings it back.
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

    // MARK: - Holding the reading position

    /// The item at the top edge of the screen and where it sits relative to that edge.
    private struct ReadingAnchor {
        let id: String
        let offsetInView: CGFloat
    }

    /// An anchor is only taken while someone is reading the history: at the bottom the
    /// feed is led by new messages and there is nothing to hold.
    private func readingAnchor() -> ReadingAnchor? {
        guard isViewLoaded, !atBottom else { return nil }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        // the list is inverted: the visual top of the screen is the item with the largest maxY
        let top = collectionView.indexPathsForVisibleItems.compactMap { path -> (IndexPath, CGRect)? in
            guard let attrs = collectionView.layoutAttributesForItem(at: path),
                  attrs.frame.intersects(visibleRect) else { return nil }
            return (path, attrs.frame)
        }.max { $0.1.maxY < $1.1.maxY }
        guard let top, top.0.item < items.count else { return nil }
        return ReadingAnchor(id: items[top.0.item].id,
                             offsetInView: top.1.maxY - collectionView.contentOffset.y)
    }

    /// Puts the anchored item back exactly where it stood before the update.
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

    // MARK: - "The feed is at the bottom"

    /// Deciding whether the feed is at the bottom: the list is inverted, the newest item
    /// lives at item 0, and being at the bottom means it is among the visible ones. An
    /// empty feed counts as being at the bottom.
    static func isAtBottom(visibleItems: [Int], totalItems: Int) -> Bool {
        guard totalItems > 0 else { return true }
        return visibleItems.contains(0)
    }

    /// Recomputed from the cells that are actually visible. A content offset in points is
    /// no good here: opening a chat parks the feed on the unread banner while the newest
    /// messages are on screen all the same.
    /// layoutFirst runs the layout before asking, because after reloadData, an insert or
    /// an inset change the set of visible cells is still the old one.
    private func updateAtBottom(layoutFirst: Bool = false) {
        guard isViewLoaded, !recomputingAtBottom else { return }
        recomputingAtBottom = true
        defer { recomputingAtBottom = false }
        if layoutFirst { collectionView.layoutIfNeeded() }
        // the insets come off the bounds: whatever lies under the input bar or the nav bar
        // is not something the reader sees
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let visible = collectionView.indexPathsForVisibleItems.filter { path in
            guard let attrs = collectionView.layoutAttributesForItem(at: path) else { return false }
            return attrs.frame.intersects(visibleRect)
        }.map(\.item)
        let value = Self.isAtBottom(visibleItems: visible, totalItems: items.count)
        guard value != atBottom else { return }
        atBottom = value
        // the callback changes @State, and the recomputation can happen inside apply(),
        // that is in the middle of a SwiftUI view update, so it is delivered on the next tick
        DispatchQueue.main.async { [weak self] in
            guard let self, self.atBottom == value else { return }
            self.onAtBottomChanged?(value)
        }
    }

    /// Scrolls to a message by its server msgId or its local id.
    /// Returns false when the message is not in the loaded feed and history has to be fetched.
    @discardableResult
    func scrollTo(msgId: String, highlight: Bool = false) -> Bool {
        guard let idx = index(ofMsgId: msgId) else { return false }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically, animated: true)
        if highlight {
            pendingHighlightId = msgId
            // if the cell is already on screen the flash runs alongside the scroll settling;
            // otherwise it fires once the cell materialises or the scroll arrives
            flushPendingHighlight()
        }
        return true
    }

    private func index(ofMsgId msgId: String) -> Int? {
        Self.index(ofMsgId: msgId, in: items)
    }

    /// Position of a message in the feed: own messages live under their clientMsgId, while
    /// references to them (a quote, a pin) use the server msgId.
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
            cell.configure(text: SystemCell.unreadableText)
            return cell
        case .historyStart:
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
            cell.configure(text: SystemCell.historyStartText)
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
            // the original's cell is created while the scroll to it is under way, and the flash was waiting
            if let id = pendingHighlightId, id == msg.id || id == msg.msgId {
                pendingHighlightId = nil
                DispatchQueue.main.async { cell.flashHighlight() }
            }
            return cell
        }
    }

    func collectionView(_ cv: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // The auxiliary rows are sized by their own font, so nothing clips when
        // the reader turns the text up.
        switch items[indexPath.item] {
        case .dateSeparator(_, let label):
            return CGSize(width: cv.bounds.width,
                          height: FeedNote.height(label, width: cv.bounds.width, padding: 20) + 10)
        case .unreadMarker(_, let count):
            return CGSize(width: cv.bounds.width,
                          height: FeedNote.height(UnreadMarkerCell.title(count: count),
                                                  width: cv.bounds.width, padding: 12) + 14)
        case .unreadable:
            return CGSize(width: cv.bounds.width,
                          height: FeedNote.height(SystemCell.unreadableText, width: cv.bounds.width) + 12)
        case .historyStart:
            return CGSize(width: cv.bounds.width,
                          height: FeedNote.height(SystemCell.historyStartText, width: cv.bounds.width) + 12)
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName):
            if msg.kind == .system {
                return CGSize(width: cv.bounds.width,
                              height: FeedNote.height(SystemCell.text(for: msg), width: cv.bounds.width) + 12)
            }
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName,
                                         replyAuthorName: replyAuthorName)
            return CGSize(width: cv.bounds.width, height: plan.cellHeight)
        }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flushPendingHighlight()
        updateAtBottom(layoutFirst: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateAtBottom()
        // pagination: close to the "top" of the history, which in the inverted system is
        // the end of the content
        if scrollView.contentOffset.y > scrollView.contentSize.height - scrollView.bounds.height - 600 {
            onNeedOlder?()
        }
    }
}

// MARK: - Auxiliary cells

/// Text rows between bubbles (date capsule, unread band, system note) all share
/// one role, so one measurement serves the layout and the cells.
enum FeedNote {
    static var font: UIFont { Theme.Text.feedNote.uiFont }

    /// Height the text needs at this width, wrapping onto as many lines as the
    /// current text size demands.
    static func height(_ text: String, width: CGFloat, padding: CGFloat = 32) -> CGFloat {
        let available = max(40, width - 2 * padding)
        let box = (text as NSString).boundingRect(
            with: CGSize(width: available, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(box.height) + 6
    }
}

final class DateSeparatorCell: UICollectionViewCell {
    private let label = UILabel()
    private let capsule = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        capsule.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        contentView.addSubview(capsule)
        capsule.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        label.font = FeedNote.font
        label.text = text
        let inset: CGFloat = 10
        let maxW = max(40, contentView.bounds.width - 40)
        let size = label.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        let w = min(maxW, size.width) + 2 * inset
        let h = contentView.bounds.height - 10
        capsule.frame = CGRect(x: (contentView.bounds.width - w) / 2, y: 5, width: w, height: max(0, h))
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        label.frame = capsule.bounds.insetBy(dx: inset, dy: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let text = label.text { configure(text) }
    }
}

/// The unread-count divider: a full-width band that scrolls with the feed.
final class UnreadMarkerCell: UICollectionViewCell {
    private let label = UILabel()
    private let band = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        band.backgroundColor = .tertiarySystemFill
        band.autoresizingMask = [.flexibleWidth]
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(band)
        band.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(count: Int) {
        label.font = FeedNote.font
        label.text = Self.title(count: count)
        layoutBand()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutBand()
    }

    private func layoutBand() {
        band.frame = CGRect(x: 0, y: 5, width: contentView.bounds.width,
                            height: max(0, contentView.bounds.height - 10))
        label.frame = band.bounds.insetBy(dx: 12, dy: 0)
    }

    /// Russian plural forms of "N unread messages", for counts ending in 1, in 2 to 4, and in the rest.
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
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.numberOfLines = 0
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    static let unreadableText = "Сообщение ещё не загружено"
    static let historyStartText = "История начинается здесь"

    static func text(for msg: Message) -> String {
        let t = msg.text ?? ""
        return t.hasPrefix("identity_changed:") ? "Код безопасности собеседника изменился" : t
    }

    func configure(_ msg: Message) {
        configure(text: Self.text(for: msg))
    }

    func configure(text: String) {
        label.font = FeedNote.font
        label.text = text
        label.frame = contentView.bounds.insetBy(dx: 32, dy: 0)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = contentView.bounds.insetBy(dx: 32, dy: 0)
    }
}
