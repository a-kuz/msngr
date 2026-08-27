import UIKit
import XCTest
@testable import Msngr
import MsngrCore

/// A reaction changes the bubble height. The feed must resize the visible cell in
/// place — recreating it through reloadItems is what produced the size jump — and
/// the reaction capsule itself must survive a count change, so its frame animates
/// instead of a new view popping in.
final class BubbleResizeTests: XCTestCase {
    private let width: CGFloat = 390

    /// A window keeps the controller's view loaded and the collection view alive.
    private func loaded() -> MessagesViewController {
        let vc = MessagesViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        return vc
    }

    /// Multiline text: with it the capsules take rows of their own, so adding a
    /// reaction genuinely changes the bubble height.
    private func message(reactions: [String: [String]]) -> Message {
        var m = Message(id: "m1", chatId: "c", fromUserId: "me",
                        sentAt: 1_700_000_000,
                        kind: .text,
                        text: "A message long enough to wrap onto several lines, so the reaction capsules land below the text.",
                        status: .sent, isOutgoing: true)
        m.seq = 1
        m.serverTs = 1_700_000_000
        m.reactions = reactions
        return m
    }

    private func feed(_ m: Message) -> [ChatFeedItem] {
        [.message(m, tightGap: false, showTail: true, showName: false,
                  authorName: nil, replyAuthorName: nil)]
    }

    private func capsules(in view: UIView) -> [ReactionCapsuleView] {
        var out: [ReactionCapsuleView] = []
        for sub in view.subviews {
            if let c = sub as? ReactionCapsuleView { out.append(c) }
            out += capsules(in: sub)
        }
        return out
    }

    @MainActor
    func testReactionResizeKeepsTheVisibleCell() {
        let vc = loaded()
        vc.apply(feed(message(reactions: [:])))
        vc.collectionView.layoutIfNeeded()
        let path = IndexPath(item: 0, section: 0)
        guard let cell = vc.collectionView.cellForItem(at: path) as? MessageCell else {
            return XCTFail("the message cell never materialised")
        }
        let heightBefore = vc.collectionView.layoutAttributesForItem(at: path)!.frame.height

        vc.apply(feed(message(reactions: ["❤️": ["peer"]])))
        vc.collectionView.layoutIfNeeded()

        let after = vc.collectionView.cellForItem(at: path) as? MessageCell
        XCTAssertTrue(after === cell,
                      "a height change on a visible cell must reconfigure it in place, not recreate it")
        let heightAfter = vc.collectionView.layoutAttributesForItem(at: path)!.frame.height
        XCTAssertGreaterThan(heightAfter, heightBefore + 5,
                             "the layout must take the new plan height")
        XCTAssertEqual(capsules(in: cell).count, 1)
    }

    /// A genuinely new capsule springs in as one unit. The emoji label must be
    /// laid out to the capsule's final bounds before the entrance animation
    /// starts: a label that picks its frame up in a later layout pass inherits
    /// the feed's outer animation block and reveals the glyph as a clipped
    /// sliver growing from the corner.
    @MainActor
    func testNewCapsuleLabelIsLaidOutBeforeTheSpring() {
        let cell = MessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 300))
        let bare = message(reactions: [:])
        cell.configure(msg: bare, plan: BubbleLayout.plan(for: bare, width: width, tightGap: false,
                                                          showTail: true, showName: false, authorName: nil))
        let reacted = message(reactions: ["❤️": ["peer"]])
        let plan = BubbleLayout.plan(for: reacted, width: width, tightGap: false,
                                     showTail: true, showName: false, authorName: nil)
        // the feed reconfigures visible cells inside an animation block
        UIView.animate(withDuration: 0.25) {
            cell.configure(msg: reacted, plan: plan)
        }
        guard let capsule = capsules(in: cell).first else {
            return XCTFail("no capsule after the reaction arrived")
        }
        XCTAssertNotEqual(capsule.bounds.size, .zero, "the capsule takes its plan frame at once")
        guard let label = capsule.subviews.compactMap({ $0 as? UILabel }).first else {
            return XCTFail("the capsule holds its emoji label")
        }
        XCTAssertEqual(label.frame.size, capsule.bounds.size,
                       "the label is laid out to the capsule before the spring, or the glyph clips mid-entrance")
    }

    @MainActor
    func testCapsuleSurvivesACountChange() {
        let cell = MessageCell(frame: CGRect(x: 0, y: 0, width: width, height: 300))
        let one = message(reactions: ["❤️": ["peer"]])
        cell.configure(msg: one, plan: BubbleLayout.plan(for: one, width: width, tightGap: false,
                                                         showTail: true, showName: false, authorName: nil))
        guard let capsule = capsules(in: cell).first else {
            return XCTFail("no capsule after the first configure")
        }

        let two = message(reactions: ["❤️": ["peer", "me"]])
        cell.configure(msg: two, plan: BubbleLayout.plan(for: two, width: width, tightGap: false,
                                                         showTail: true, showName: false, authorName: nil))
        let now = capsules(in: cell)
        XCTAssertEqual(now.count, 1)
        XCTAssertTrue(now.first === capsule,
                      "the capsule is reused by emoji so a count change animates in place")
    }
}
