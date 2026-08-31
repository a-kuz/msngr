import UIKit
import XCTest
@testable import Msngr
import MsngrCore

/// A feed update is a pointwise diff, not a reload: a new message at the
/// bottom materialises its own cell and leaves the rest of the screen alone,
/// and an edit reconfigures its cell in place. A reload would re-ask the data
/// source for every visible position and cut running animations short.
@MainActor
final class FeedDiffTests: XCTestCase {
    /// Counts what the collection view asks the data source for, forwarding
    /// everything to the controller.
    private final class CountingDataSource: NSObject, UICollectionViewDataSource {
        let real: UICollectionViewDataSource
        var cellRequests: [IndexPath] = []

        init(real: UICollectionViewDataSource) { self.real = real }

        func collectionView(_ collectionView: UICollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            real.collectionView(collectionView, numberOfItemsInSection: section)
        }

        func collectionView(_ collectionView: UICollectionView,
                            cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            cellRequests.append(indexPath)
            return real.collectionView(collectionView, cellForItemAt: indexPath)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || real.responds(to: aSelector)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            real.responds(to: aSelector) ? real : nil
        }
    }

    private func msg(_ seq: Int, text: String? = nil) -> Message {
        var m = Message(id: "m\(seq)", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000 + Double(seq), kind: .text,
                        text: text ?? "message \(seq)", status: .sent, isOutgoing: false)
        m.seq = seq
        return m
    }

    private func item(_ m: Message) -> ChatFeedItem {
        .message(m, tightGap: false, showTail: true, showName: false, authorName: nil)
    }

    /// A window keeps the view loaded and the visible cells alive.
    private func loaded(seqs: [Int])
        -> (MessagesViewController, CountingDataSource, [ChatFeedItem]) {
        let vc = MessagesViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        let feed = seqs.sorted(by: >).map { item(msg($0)) }
        vc.apply(feed)
        vc.view.layoutIfNeeded()
        let proxy = CountingDataSource(real: vc.collectionView.dataSource!)
        vc.collectionView.dataSource = proxy
        // swapping the data source invalidates the collection view's state;
        // settle it through the proxy before counting anything
        vc.collectionView.reloadData()
        vc.view.layoutIfNeeded()
        proxy.cellRequests = []
        return (vc, proxy, feed)
    }

    /// A new message at the bottom is an insert of one cell: the data source
    /// is asked for the new position, not for the whole screen.
    func testANewMessageMaterialisesOneCell() {
        let (vc, proxy, feed) = loaded(seqs: Array(1...30))
        let visible = vc.collectionView.indexPathsForVisibleItems.count
        XCTAssertGreaterThan(visible, 5, "the screen must hold several cells for the test to mean anything")

        var next = feed
        next.insert(item(msg(31)), at: 0)
        vc.apply(next)
        vc.view.layoutIfNeeded()

        XCTAssertEqual(vc.collectionView.numberOfItems(inSection: 0), 31)
        XCTAssertLessThan(proxy.cellRequests.count, visible,
                          "an insert re-asked the data source for the screen — that is a reload, not a diff")
        XCTAssertTrue(proxy.cellRequests.contains(IndexPath(item: 0, section: 0)),
                      "the inserted message never materialised")
    }

    /// An edit keeps every id in place: the cell is reconfigured directly,
    /// with no dequeue at all.
    func testAnEditReconfiguresInPlaceWithoutDequeue() {
        let (vc, proxy, feed) = loaded(seqs: Array(1...30))

        var next = feed
        var edited = msg(30, text: "edited")
        edited.editedAt = 1_700_000_100
        next[0] = item(edited)
        vc.apply(next)
        vc.view.layoutIfNeeded()

        XCTAssertTrue(proxy.cellRequests.isEmpty,
                      "an edit went through dequeue — the cell should be reconfigured in place")
        let cell = vc.collectionView.cellForItem(at: IndexPath(item: 0, section: 0)) as? MessageCell
        XCTAssertNotNil(cell)
    }
}
