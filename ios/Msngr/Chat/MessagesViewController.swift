import UIKit
import SwiftUI
import SafariServices
import Combine
import MsngrCore

/// Inverted message list: a UICollectionView flipped along Y, with the cells
/// flipped back so the result reads normally. The bottom of the chat is then
/// contentOffset 0: it opens instantly on the latest messages and pages upwards
/// the way a scroll view already wants to.
final class MessagesViewController: UIViewController, UIGestureRecognizerDelegate {
    /// The feed is at the bottom: the newest item is really on screen. The scroll
    /// to bottom button and the read receipt both depend on this.
    var onAtBottomChanged: ((Bool) -> Void)?
    var onNeedOlder: (() -> Void)?
    var onReply: ((Message) -> Void)?
    var onReact: ((Message, String) -> Void)?
    /// Tap on a reaction capsule: in a group it opens who reacted, in a direct
    /// chat it toggles your own reaction — the screen decides which.
    var onReactionCapsuleTap: ((Message, String) -> Void)?
    var onContextAction: ((Message, MessageContextAction) -> Void)?
    /// an outgoing message in a group offers the read-by list in its menu
    var isGroupChat = false
    /// how many people besides the sender a note reaches: the listened dots
    /// compare it against who has actually listened
    var noteRecipients = 1
    /// a tap on a poll option: the message and the full chosen set
    var onVotePoll: ((Message, [Int]) -> Void)?
    /// the footer tap of a non-anonymous poll, asking for the voters sheet
    var onShowPollVoters: ((Message) -> Void)?
    var onOpenContact: ((Message) -> Void)?
    var onOpenLocation: ((Message) -> Void)?
    var onRedial: (() -> Void)?
    var onTranscript: ((Message) -> Void)?
    var onRetranscribe: ((Message) -> Void)?
    /// The message the chat holds pinned, so the context menu of that one offers
    /// to take the pin off instead of putting it on again.
    var pinnedSeqs: Set<Int> = []
    var onTapMedia: ((Message, Int, UIView) -> Void)?
    var onTapShader: ((Message) -> Void)?
    /// Tap on the quote inside a reply bubble, which jumps to the original.
    var onTapReplyQuote: ((Message) -> Void)?
    /// Tap on a row while multi-select is on.
    var onToggleSelection: ((Message) -> Void)?
    var onScrollToStart: (() -> Void)?
    var onSwipeBack: (() -> Void)?
    /// Tap on a date separator or on the floating day capsule: the calendar
    /// over the history.
    var onDateTap: (() -> Void)?

    var ownUserId = ""

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
    /// The next feed comes from a window that was moved: it is shown from the bottom.
    private var showBottomOnUpdate = false
    private var seenSendTick = 0
    private let backSwipe = UIPanGestureRecognizer()
    private var awaitingOwnSend = false
    /// The floating day capsule under the header. A plain subview over the feed,
    /// not a supplementary view: pointwise updates and cell reloads cannot move it.
    private let stickyDate = StickyDateOverlay()

    func noteSendTick(_ tick: Int) {
        guard tick != seenSendTick else { return }
        seenSendTick = tick
        awaitingOwnSend = true
        guard isViewLoaded else { return }
        scrollToBottom(animated: false)
    }

    private func ownSendLanded(newFirst: ChatFeedItem?, oldIds: Set<String>) -> Bool {
        guard awaitingOwnSend, case .message(let m, _, _, _, _, _, _)? = newFirst, m.isOutgoing,
              !oldIds.contains(m.id) else { return false }
        awaitingOwnSend = false
        return true
    }

    private func landOwnMessage() {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: false)
        collectionView.layoutIfNeeded()
        guard let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MessageCell
        else { return }
        let point = CGPoint(x: view.bounds.width - 28,
                            y: view.bounds.height - collectionView.contentInset.top + 22)
        cell.animateSendFlight(fromScreenPoint: point, in: view)
    }

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
        // the feed is flipped, so the system edge effect lands mirrored: it clears
        // the strip it should soften and softens the rest of the feed. The band
        // under the header is drawn by HeaderFade instead
        if #available(iOS 26.0, *) {
            collectionView.topEdgeEffect.isHidden = true
            collectionView.bottomEdgeEffect.isHidden = true
        }
        collectionView.register(MessageCell.self, forCellWithReuseIdentifier: "msg")
        collectionView.register(DateSeparatorCell.self, forCellWithReuseIdentifier: "date")
        collectionView.register(SystemCell.self, forCellWithReuseIdentifier: "system")
        collectionView.register(UnreadMarkerCell.self, forCellWithReuseIdentifier: "unread")
        view.addSubview(collectionView)
        view.addSubview(stickyDate)
        // the floating capsule opens the calendar too; while it is faded out
        // its alpha keeps it out of hit-testing, so scrolling is untouched
        stickyDate.isUserInteractionEnabled = true
        stickyDate.addGestureRecognizer(UITapGestureRecognizer(target: self,
                                                               action: #selector(stickyDateTapped)))
        backSwipe.addTarget(self, action: #selector(handleBackSwipe(_:)))
        backSwipe.delegate = self
        view.addGestureRecognizer(backSwipe)
        collectionView.panGestureRecognizer.require(toFail: backSwipe)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(typeScaleChanged),
                                               name: .typeScaleChanged, object: nil)
        // bubble backgrounds are images baked per appearance in the cell's
        // configure, while the text repaints dynamically: a light/dark switch
        // re-bakes the visible cells too
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (vc: MessagesViewController, _) in
            guard vc.isViewLoaded else { return }
            vc.collectionView.reloadData()
        }

        // the docked circle a round video keeps playing in once its bubble is
        // scrolled away; hidden while the bubble itself is on screen
        roundDock.isHidden = true
        roundDock.onTap = { [weak self] in
            guard let self, let id = RoundVideoPlayer.shared.state.msgId else { return }
            _ = self.scrollTo(id: id, highlight: false)
        }
        view.addSubview(roundDock)
        roundDockCancellable = RoundVideoPlayer.shared.$state
            .sink { [weak self] state in self?.updateRoundDock(state) }
    }

    private let roundDock = RoundVideoDockView()
    private var roundDockCancellable: AnyCancellable?

    /// The dock shows while a round video has the sound and its bubble is not
    /// visible; called on every player change and every cell entering or
    /// leaving the screen.
    private func updateRoundDock(_ state: RoundVideoPlayback? = nil) {
        let state = state ?? RoundVideoPlayer.shared.state
        guard let msgId = state.msgId else {
            roundDock.isHidden = true
            roundDock.attach(nil)
            return
        }
        let bubbleVisible = collectionView.visibleCells
            .contains { ($0 as? MessageCell)?.messageId == msgId }
        if bubbleVisible {
            roundDock.isHidden = true
            roundDock.attach(nil)
        } else {
            if roundDock.isHidden {
                let side = RoundVideoDockView.side
                roundDock.frame = CGRect(x: view.bounds.width - side - 10,
                                         y: view.safeAreaInsets.top + 8,
                                         width: side, height: side)
                roundDock.attach(RoundVideoPlayer.shared.player)
                roundDock.isHidden = false
                view.bringSubviewToFront(roundDock)
            }
            roundDock.setProgress(state.progress)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // the feed measures against a snapshot of the text size; the traits this
        // view is about to be drawn with are the truth it has to match
        TypeScale.sync(with: traitCollection)
    }

    /// Reader changed their text size: every cached plan was measured against
    /// the old font, so the feed re-measures from scratch and puts the message
    /// the reader was looking at back where it was.
    @objc private func typeScaleChanged() {
        guard isViewLoaded else { return }
        let anchor = readingAnchor()
        BubbleLayout.clearCache()
        // the capsule text was rendered with the old font
        stickyDate.invalidate()
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
    }

    /// Swipe back from the left edge. The system gesture does not start on this screen:
    /// the header draws its own back button, and with the system one hidden the
    /// navigation controller refuses its own transition — neither dropping the delegate
    /// nor re-enabling the recogniser changes that. Hence an edge of our own.
    @objc private func handleBackSwipe(_ g: UIPanGestureRecognizer) {
        guard g.state == .ended else { return }
        if g.translation(in: view).x > 70 || g.velocity(in: view).x > 500 { onSwipeBack?() }
    }

    /// The back gesture takes only touches from the edge going right; everything
    /// else stays with the feed.
    func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === backSwipe else { return true }
        let start = backSwipe.location(in: nil).x - backSwipe.translation(in: nil).x
        let v = backSwipe.velocity(in: view)
        return start < MessageCell.backSwipeEdge && v.x > abs(v.y)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        frameLink?.invalidate()
        frameLink = nil
        lastFrame = 0
        PerfTrace.shared.flush()
        // the sound and its circle belong to this chat: leaving it stops both
        // (voice keeps playing across chats, a picture without its feed does not)
        RoundVideoPlayer.shared.stop()
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

    /// The window was moved back to the end of the chat: the feed arriving next is a
    /// different stretch of the conversation, and it is shown from its newest message
    /// rather than diffed against the one the reader was standing in.
    func showBottomOnNextUpdate() {
        showBottomOnUpdate = true
    }

    private func applyDiff(_ newItems: [ChatFeedItem]) {
        let old = items
        guard isViewLoaded else { items = newItems; return }
        if showBottomOnUpdate, !newItems.isEmpty {
            showBottomOnUpdate = false
            items = newItems
            collectionView.layer.removeAllAnimations()
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top),
                                            animated: false)
            updateAtBottom(layoutFirst: true)
            return
        }
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
                burstIfReactionLanded(was: old[i], now: item, at: i)
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
        let ownAtBottom: Bool = {
            guard case .message(let m, _, _, _, _, _, _)? = newItems.first else { return false }
            return m.isOutgoing && oldIndex[newIds[0]] == nil
        }()
        let sendLanded = ownSendLanded(newFirst: newItems.first, oldIds: Set(oldIds))
        let ownLanded = ownAtBottom || sendLanded

        // a structural change too complex to diff (a reordering) falls back to reload
        let onlyAppendOrRemove = deletes.count + inserts.count == abs(oldIds.count - newIds.count)
            || (deletes.isEmpty || inserts.isEmpty)
        guard onlyAppendOrRemove, deletes.count + inserts.count < 60 else {
            items = newItems
            collectionView.reloadData()
            restore(anchor)
            // our own new message at the bottom has to become visible on the reload path too
            if ownLanded { landOwnMessage() }
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
                  case .message(let m, _, _, _, _, _, _) = newItems[0] else { return nil }
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
            burstIfReactionLanded(was: old[oldIdx], now: item, at: i)
        }
        if let nb = newBottom,
           let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MessageCell {
            if nb.outgoing {
                let point = CGPoint(x: view.bounds.width - 28,
                                    y: view.bounds.height - collectionView.contentInset.top + 22)
                cell.animateSendFlight(fromScreenPoint: point, in: view)
                ShaderEffectPlayer.play(.send, in: view, at: point)
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

    private static func reactionCount(_ msg: Message) -> Int {
        msg.reactions.values.reduce(0) { $0 + $1.count }
    }

    /// A reaction that just landed on a visible bubble bursts out of it.
    private func burstIfReactionLanded(was: ChatFeedItem, now: ChatFeedItem, at index: Int) {
        guard case .message(let after, _, _, _, _, _, _) = now, case .message(let before, _, _, _, _, _, _) = was else { return }
        let counts = (before: Self.reactionCount(before), after: Self.reactionCount(after))
        guard counts.after > counts.before else { return }
        // a reaction picked in the context menu lands while the menu's blur is
        // still dismissing; the burst waits for it and asks the cell where the
        // bubble stands then, since the feed relayouts under the menu
        MessageContextOverlay.afterDismiss { [weak self] in
            guard let self else { return }
            guard let cell = self.collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? MessageCell else {
                MsngrLog.shader.info("reaction landed \(counts.before)→\(counts.after) but the cell is off screen")
                return
            }
            MsngrLog.shader.info("reaction landed \(counts.before)→\(counts.after), bursting")
            ShaderEffectPlayer.play(.reaction, in: self.view, at: cell.bubbleCenter(in: self.view))
        }
    }

    /// Refreshes a position that already stands in the feed and whose content changed.
    /// A reload recreates the cell and instantly cuts off a running appearance animation
    /// (the pending→sent ack lands in the first milliseconds of the flight), so a visible
    /// cell of the same height is reconfigured in place instead. A visible cell whose
    /// height changed (a reaction arrived or left) resizes in place under a spring: the
    /// cell survives, its subviews slide to the new plan, and the neighbours follow
    /// through the batch update instead of jumping in a single frame.
    private func refreshItem(at index: Int, item: ChatFeedItem) {
        let indexPath = IndexPath(item: index, section: 0)
        switch item {
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName,
                      let avatar)
            where msg.kind != .system:
            if let cell = collectionView.cellForItem(at: indexPath) as? MessageCell {
                let plan = BubbleLayout.plan(for: msg, width: collectionView.bounds.width, tightGap: tightGap,
                                             showTail: showTail, showName: showName, authorName: authorName,
                                             replyAuthorName: replyAuthorName, avatarInset: avatar != nil)
                // an inline reaction changes only the width, so the spring wraps every
                // reconfigure; the batch update joins in only when the height moved. It
                // re-reads sizeForItemAt, which serves the new plan from the cache;
                // contentOffset is untouched, so in the inverted feed the bubble's
                // bottom edge stays put and the content above slides
                let sameHeight = abs(cell.bounds.height - plan.cellHeight) < 0.5
                UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86,
                               initialSpringVelocity: 0,
                               options: [.allowUserInteraction, .beginFromCurrentState]) {
                    self.configureMessageCell(cell, msg: msg, plan: plan, avatar: avatar)
                    if !sameHeight { self.collectionView.performBatchUpdates(nil) }
                }
                return
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
    private func configureMessageCell(_ cell: MessageCell, msg: Message, plan: BubbleLayoutPlan,
                                      avatar: FeedAvatar? = nil) {
        cell.isGroupChat = isGroupChat
        cell.noteRecipients = noteRecipients
        cell.ownUserId = ownUserId
        cell.onVotePoll = { [weak self] votes in self?.onVotePoll?(msg, votes) }
        cell.onShowPollVoters = { [weak self] in self?.onShowPollVoters?(msg) }
        cell.onOpenContact = { [weak self] in self?.onOpenContact?(msg) }
        cell.onOpenLocation = { [weak self] in self?.onOpenLocation?(msg) }
        cell.onRedial = { [weak self] in self?.onRedial?() }
        cell.onTranscript = { [weak self] in self?.onTranscript?(msg) }
        cell.onRetranscribe = { [weak self] in self?.onRetranscribe?(msg) }
        cell.configure(msg: msg, plan: plan, avatar: avatar)
        cell.onReply = { [weak self] in self?.onReply?(msg) }
        cell.onReact = { [weak self] emoji in self?.onReact?(msg, emoji) }
        cell.onCapsuleTap = { [weak self] emoji in self?.onReactionCapsuleTap?(msg, emoji) }
        cell.onContextAction = { [weak self] action in self?.onContextAction?(msg, action) }
        cell.onTapMedia = { [weak self] index, view in self?.onTapMedia?(msg, index, view) }
        cell.onTapShader = { [weak self] in self?.onTapShader?(msg) }
        cell.onTapLink = { [weak self] url in self?.open(url) }
        cell.onTapReplyQuote = { [weak self] in self?.onTapReplyQuote?(msg) }
        cell.onToggleSelection = { [weak self] in self?.onToggleSelection?(msg) }
        // asked when the menu opens, not when the cell is filled: pinning changes
        // the chat, not the message, so no cell is reconfigured for it
        cell.isPinned = { [weak self] in msg.seq.map { self?.pinnedSeqs.contains($0) ?? false } ?? false }
        cell.setSelection(mode: selectionMode, selected: selectedIds.contains(msg.id), animated: false)
    }

    /// A link from a message opens in the built-in browser: the chat stays where it is
    /// and a swipe down brings it back.
    private func open(_ url: URL) {
        // a mention: open (or create) the direct chat with that person; a
        // mention of yourself leads to the saved-messages chat — asking the
        // server for a direct chat with your own id hands back someone else's
        if url.scheme?.lowercased() == "user" {
            let userId = String(url.absoluteString.dropFirst("user:".count))
            // «@все» names no person, so there is nowhere to go
            guard !userId.isEmpty, userId != MessageMarkdown.allMentionId else { return }
            Task {
                let chatId: String?
                if userId == ownUserId {
                    chatId = try? await AppState.shared.db?.read { dbc in
                        try String.fetchOne(dbc, sql: "SELECT id FROM chat WHERE kind = 'self'")
                    } ?? nil
                } else {
                    chatId = await DirectChat.open(userId: userId)
                }
                guard let chatId else { return }
                NotificationCenter.default.post(name: .openChatRequested, object: chatId)
            }
            return
        }
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
        case let (.message(m1, t1, s1, _, _, _, a1), .message(m2, t2, s2, _, _, _, a2)):
            return m1 == m2 && t1 == t2 && s1 == s2 && a1 == a2
        case let (.dateSeparator(_, l1), .dateSeparator(_, l2)):
            return l1 == l2
        case let (.unreadMarker(_, c1), .unreadMarker(_, c2)):
            return c1 == c2
        case (.unreadable, .unreadable):
            return true
        default:
            return false
        }
    }

    func scrollToBottom(animated: Bool = true) {
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.contentInset.top), animated: animated)
        if !animated { updateAtBottom(layoutFirst: true) }
    }

    /// The start of the chat: the list is inverted, so the oldest message is the last
    /// item, at the end of the content. A far end is taken without animation — scrolling
    /// through thousands of cells does not read as anything anyway.
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

    // MARK: - Holding the reading position

    /// The item at the top edge of the screen and where it sits relative to that edge.
    private struct ReadingAnchor {
        let id: String
        let offsetInView: CGFloat
    }

    /// The item at the visual top of the screen: in the inverted list that is
    /// the visible item with the largest maxY.
    private func topVisible() -> (index: Int, frame: CGRect)? {
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        let top = collectionView.indexPathsForVisibleItems.compactMap { path -> (IndexPath, CGRect)? in
            guard let attrs = collectionView.layoutAttributesForItem(at: path),
                  attrs.frame.intersects(visibleRect) else { return nil }
            return (path, attrs.frame)
        }.max { $0.1.maxY < $1.1.maxY }
        guard let top, top.0.item < items.count else { return nil }
        return (top.0.item, top.1)
    }

    /// An anchor is only taken while someone is reading the history: at the bottom the
    /// feed is led by new messages and there is nothing to hold.
    private func readingAnchor() -> ReadingAnchor? {
        guard isViewLoaded, !atBottom, let top = topVisible() else { return nil }
        return ReadingAnchor(id: items[top.index].id,
                             offsetInView: top.frame.maxY - collectionView.contentOffset.y)
    }

    /// The seq of the message the reader is looking at, for keeping the reading
    /// position between openings of the chat. Nil at the bottom: the feed is led
    /// by new messages there and the next opening starts at the end. The topmost
    /// visible item may be a separator or the banner, so the nearest message
    /// below it carries the position.
    func readingPositionSeq() -> Int? {
        guard isViewLoaded, !atBottom, let top = topVisible() else { return nil }
        for i in stride(from: top.index, through: 0, by: -1) {
            if case .message(let m, _, _, _, _, _, _) = items[i], let seq = m.seq { return seq }
        }
        return nil
    }

    // MARK: - The floating day capsule

    @objc private func stickyDateTapped() { onDateTap?() }

    /// Renames the capsule after every geometry change. The text is compared
    /// inside the overlay, so an update that lands on the same day is a no-op
    /// and a pointwise insert cannot make the capsule blink.
    private func updateStickyDate() {
        stickyDate.set(label: Self.stickyLabel(items: items, topIndex: topVisible()?.index),
                       maxWidth: view.bounds.width - 40)
        stickyDate.center = CGPoint(x: view.bounds.midX,
                                    y: view.safeAreaInsets.top + 11 + stickyDate.bounds.height / 2)
    }

    /// The day of the item at the top edge, read from the nearest date separator
    /// above it — later in the inverted array. Nil while that separator itself is
    /// the topmost item: the real capsule then stands exactly where the floating
    /// one would hang, and the floating one yields to it.
    static func stickyLabel(items: [ChatFeedItem], topIndex: Int?) -> String? {
        guard let topIndex, topIndex < items.count else { return nil }
        if case .dateSeparator = items[topIndex] { return nil }
        for i in (topIndex + 1)..<items.count {
            if case .dateSeparator(_, let label) = items[i] { return label }
        }
        return nil
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
        // every path that changes the feed's geometry comes through here, so the
        // floating day capsule is renamed in the same breath
        updateStickyDate()
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

    /// The message at the top edge of the screen, or nil while the feed is at its
    /// bottom. Search remembers it and brings the reader back to it.
    func topVisibleMessageId() -> String? {
        guard isViewLoaded, !atBottom else { return nil }
        let visibleRect = collectionView.bounds.inset(by: collectionView.adjustedContentInset)
        // the list is inverted: the visual top of the screen is the largest maxY
        let top = collectionView.indexPathsForVisibleItems.compactMap { path -> (String, CGFloat)? in
            guard path.item < items.count,
                  case .message(let msg, _, _, _, _, _, _) = items[path.item],
                  let attrs = collectionView.layoutAttributesForItem(at: path),
                  attrs.frame.intersects(visibleRect) else { return nil }
            return (msg.id, attrs.frame.maxY)
        }.max { $0.1 < $1.1 }
        return top?.0
    }

    /// Scrolls to a message by its local row id.
    /// Returns false when the message is not in the loaded feed and history has to be fetched.
    @discardableResult
    func scrollTo(id: String, highlight: Bool = false, animated: Bool = true) -> Bool {
        guard let idx = index(ofId: id) else { return false }
        collectionView.scrollToItem(at: IndexPath(item: idx, section: 0), at: .centeredVertically,
                                    animated: animated)
        if highlight {
            pendingHighlightId = id
            // if the cell is already on screen the flash runs alongside the scroll settling;
            // otherwise it fires once the cell materialises or the scroll arrives
            flushPendingHighlight()
        }
        return true
    }

    // MARK: - The hardware-keyboard walk

    /// The message the ↑/↓ walk stands on; nil while no walk is active. The
    /// items array is inverted (0 is the newest), so up means a higher index.
    private var keyWalkId: String?

    /// The walked message, for the Enter action.
    var keyWalkMessage: Message? {
        guard let id = keyWalkId, let idx = index(ofId: id),
              case .message(let m, _, _, _, _, _, _) = items[idx] else { return nil }
        return m
    }

    /// Steps the walk one message older (up) or newer (down). Walking down
    /// past the newest message ends the walk. Returns false only when there
    /// was nothing to do at all, so the caller can leave the key unconsumed.
    @discardableResult
    func moveKeyWalk(up: Bool) -> Bool {
        let messageIndices = items.indices.filter {
            if case .message = items[$0] { return true } else { return false }
        }
        guard !messageIndices.isEmpty else { return false }
        var target: Int?
        if let id = keyWalkId, let current = index(ofId: id) {
            target = up ? messageIndices.first(where: { $0 > current })
                        : messageIndices.last(where: { $0 < current })
            if !up, target == nil {
                clearKeyWalk()
                return true
            }
        } else if up {
            target = messageIndices.first
        } else {
            return false
        }
        guard let idx = target, case .message(let m, _, _, _, _, _, _) = items[idx] else {
            return keyWalkId != nil
        }
        keyWalkId = m.id
        scrollTo(id: m.id, highlight: true)
        return true
    }

    /// Ends the walk; true when one was active — the caller's Esc is then spent.
    @discardableResult
    func clearKeyWalk() -> Bool {
        let active = keyWalkId != nil
        keyWalkId = nil
        return active
    }

    /// The newest message Cmd+↑ may edit: your own text, the same gate the
    /// context menu's Edit has, skipping what delete-for-all left behind.
    var lastOwnEditableMessage: Message? {
        for item in items {
            guard case .message(let m, _, _, _, _, _, _) = item else { continue }
            if m.isOutgoing, m.kind == .text, !m.deletedForAll { return m }
        }
        return nil
    }

    /// Scrolls to a message a reference names by seq (a quote, a pin).
    @discardableResult
    func scrollTo(seq: Int, highlight: Bool = false, animated: Bool = true) -> Bool {
        guard let idx = Self.index(ofSeq: seq, in: items),
              case .message(let msg, _, _, _, _, _, _) = items[idx] else { return false }
        return scrollTo(id: msg.id, highlight: highlight, animated: animated)
    }

    private func index(ofId id: String) -> Int? {
        Self.index(ofId: id, in: items)
    }

    /// Position of a message in the feed by its local row id.
    static func index(ofId id: String, in items: [ChatFeedItem]) -> Int? {
        items.firstIndex { item in
            guard case .message(let m, _, _, _, _, _, _) = item else { return false }
            return m.id == id
        }
    }

    /// Position of a message in the feed by its seq: how a quote or a pin names it.
    static func index(ofSeq seq: Int, in items: [ChatFeedItem]) -> Int? {
        items.firstIndex { item in
            guard case .message(let m, _, _, _, _, _, _) = item else { return false }
            return m.seq == seq
        }
    }

    private func flushPendingHighlight() {
        guard let id = pendingHighlightId, let idx = index(ofId: id),
              let cell = collectionView.cellForItem(at: IndexPath(item: idx, section: 0)) as? MessageCell else { return }
        pendingHighlightId = nil
        cell.flashHighlight()
    }
}

enum MessageContextAction {
    case reply, copy, forward, select, edit, editHistory, pin, unpin, delete, resend
    /// who has read and who has received an outgoing group message
    case readBy
    /// a shader message becomes this chat's background, on this device
    case setBackground
    /// a sticker goes into the local pack
    case saveSticker
    /// a message still waiting for its scheduled time
    case sendNow, reschedule, cancelScheduled
}

extension MessagesViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ cv: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    // autoplaying video stops the moment its cell leaves the screen and picks
    // up again when it comes back; the players themselves live in the cell
    func collectionView(_ cv: UICollectionView, willDisplay cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? MessageCell)?.setAutoplayActive(true)
        if RoundVideoPlayer.shared.state.msgId != nil { updateRoundDock() }
    }

    func collectionView(_ cv: UICollectionView, didEndDisplaying cell: UICollectionViewCell,
                        forItemAt indexPath: IndexPath) {
        (cell as? MessageCell)?.setAutoplayActive(false)
        if RoundVideoPlayer.shared.state.msgId != nil { updateRoundDock() }
    }

    func collectionView(_ cv: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard indexPath.item < items.count,
              case .dateSeparator = items[indexPath.item] else { return }
        onDateTap?()
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
        case .unreadable(_, let count):
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
            cell.configure(text: SystemCell.unreadableText(count: count))
            return cell
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName,
                      let avatar):
            if msg.kind == .system {
                let cell = cv.dequeueReusableCell(withReuseIdentifier: "system", for: indexPath) as! SystemCell
                cell.configure(msg, ownUserId: ownUserId)
                return cell
            }
            let cell = cv.dequeueReusableCell(withReuseIdentifier: "msg", for: indexPath) as! MessageCell
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName,
                                         replyAuthorName: replyAuthorName, avatarInset: avatar != nil)
            configureMessageCell(cell, msg: msg, plan: plan, avatar: avatar)
            // the original's cell is created while the scroll to it is under way, and the flash was waiting
            if let id = pendingHighlightId, id == msg.id {
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
        case .unreadable(_, let count):
            return CGSize(width: cv.bounds.width,
                          height: FeedNote.height(SystemCell.unreadableText(count: count),
                                                  width: cv.bounds.width) + 12)
        case .message(let msg, let tightGap, let showTail, let showName, let authorName, let replyAuthorName,
                      let avatar):
            if msg.kind == .system {
                return CGSize(width: cv.bounds.width,
                              height: FeedNote.height(SystemCell.text(for: msg, ownUserId: ownUserId),
                                                      width: cv.bounds.width) + 12)
            }
            let plan = BubbleLayout.plan(for: msg, width: cv.bounds.width, tightGap: tightGap,
                                         showTail: showTail, showName: showName, authorName: authorName,
                                         replyAuthorName: replyAuthorName, avatarInset: avatar != nil)
            return CGSize(width: cv.bounds.width, height: plan.cellHeight)
        }
    }

    /// A status bar tap. The system's own "scroll to top" would land on the newest
    /// messages in an inverted feed, so the screen takes the tap over and goes to the
    /// beginning of the conversation itself.
    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        onScrollToStart?()
        return false
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        flushPendingHighlight()
        updateAtBottom(layoutFirst: true)
        stickyDate.scheduleHide()
    }

    /// The day capsule shows only for a reader's own scrolling: a feed moved by
    /// an insert or a programmatic jump keeps it as it was, so updates cannot
    /// flash it.
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        updateStickyDate()
        stickyDate.reveal()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { stickyDate.scheduleHide() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        stickyDate.scheduleHide()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateAtBottom()
        if scrollView.isTracking || scrollView.isDecelerating { stickyDate.reveal() }
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

/// The day capsule: one look shared by the in-feed separator cell and the
/// floating sticky copy under the header.
final class DateCapsuleView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor.black.withAlphaComponent(0.18)
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Sizes itself to the text at the current type size.
    func set(text: String, maxWidth: CGFloat, height: CGFloat) {
        label.font = FeedNote.font
        label.text = text
        let inset: CGFloat = 10
        let maxW = max(40, maxWidth)
        let size = label.sizeThatFits(CGSize(width: maxW, height: .greatestFiniteMagnitude))
        bounds.size = CGSize(width: min(maxW, size.width) + 2 * inset, height: max(0, height))
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: inset, dy: 0)
    }
}

final class DateSeparatorCell: UICollectionViewCell {
    private let capsule = DateCapsuleView()
    private var text = ""

    /// The first message of the day carries its own series gap
    /// (`BubbleLayout.normalGap`) between itself and the capsule, while the last
    /// message of the previous day adjoins the cell directly. Half that gap
    /// moves the capsule toward the older day, so the air on both sides matches.
    static let olderSideShift: CGFloat = BubbleLayout.normalGap / 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.transform = CGAffineTransform(scaleX: 1, y: -1)
        contentView.addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ text: String) {
        self.text = text
        capsule.set(text: text, maxWidth: contentView.bounds.width - 40,
                    height: contentView.bounds.height - 10)
        capsule.center = CGPoint(x: contentView.bounds.midX,
                                 y: contentView.bounds.midY + Self.olderSideShift)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if !text.isEmpty { configure(text) }
    }
}

/// The floating date under the navigation bar: it appears while the reader
/// scrolls, names the day passing the top edge, and dissolves shortly after the
/// scrolling stops.
final class StickyDateOverlay: UIView {
    private let capsule = DateCapsuleView()
    private var hideWork: DispatchWorkItem?
    /// The day currently rendered; nil while the real separator cell holds the
    /// top of the screen.
    private(set) var dayLabel: String?
    /// The reader is scrolling, or stopped a moment ago.
    private var revealed = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        alpha = 0
        addSubview(capsule)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A repeated label is a no-op, so feed updates that stay within the same
    /// day cannot make the capsule blink. Losing the label means the real
    /// separator cell has taken the top edge, standing exactly where this
    /// capsule hangs: the handoff is instant, a fade would read as a double.
    func set(label: String?, maxWidth: CGFloat) {
        guard label != dayLabel else { return }
        dayLabel = label
        if let label {
            capsule.set(text: label, maxWidth: maxWidth,
                        height: FeedNote.height(label, width: maxWidth + 40, padding: 20))
            capsule.frame.origin = .zero
            bounds.size = capsule.bounds.size
        }
        applyVisibility(instant: label == nil)
    }

    /// The text was rendered for a type size that is gone: the next set() draws anew.
    func invalidate() { dayLabel = nil }

    func reveal() {
        hideWork?.cancel()
        hideWork = nil
        guard !revealed else { return }
        revealed = true
        applyVisibility()
    }

    /// The fade starts a beat after the scrolling stops, the way Telegram holds it.
    func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.revealed = false
            self.applyVisibility()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    private func applyVisibility(instant: Bool = false) {
        let target: CGFloat = (revealed && dayLabel != nil) ? 1 : 0
        guard target != alpha else { return }
        if instant {
            layer.removeAllAnimations()
            alpha = target
            return
        }
        UIView.animate(withDuration: target == 1 ? 0.15 : 0.3, delay: 0,
                       options: [.beginFromCurrentState]) { self.alpha = target }
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

    /// "N unread messages" in the plural forms of the current locale.
    static func title(count: Int) -> String {
        String(localized: "\(count) unread messages")
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

    static let unreadableText = String(localized: "Message not loaded yet")

    /// One hole in the history, however many messages are behind it.
    static func unreadableText(count: Int) -> String {
        count > 1 ? String(localized: "\(count) messages not loaded yet") : unreadableText
    }

    static func text(for msg: Message, ownUserId: String = "") -> String {
        let t = msg.text ?? ""
        if let event = GroupEvent.decode(t) {
            return event.sentence(isOwn: msg.isOutgoing, ownUserId: ownUserId)
        }
        return t.hasPrefix("identity_changed:") ? String(localized: "The peer's safety code has changed") : t
    }

    func configure(_ msg: Message, ownUserId: String = "") {
        configure(text: Self.text(for: msg, ownUserId: ownUserId))
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
