import UIKit
import XCTest
@testable import Msngr

/// A status bar tap over the inverted feed. UIKit sends it as `scrollViewShouldScrollToTop`,
/// and the feed answers by going to the beginning of the conversation instead of letting the
/// system scroll to what is, in an inverted list, the newest message.
///
/// The tap itself lives outside the app: it is delivered by SpringBoard, and XCUITest has no
/// way to produce it on the simulator — a touch aimed at the status bar, whether through the
/// SpringBoard element or through a coordinate in the app's own window, never reaches the
/// delegate. So the wiring is checked here instead of in the UI smoke.
final class StatusBarTapTests: XCTestCase {
    /// A window keeps the controller's view loaded and the collection view alive.
    private func loaded() -> MessagesViewController {
        let vc = MessagesViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        return vc
    }

    func testTapAsksTheScreenForTheStartOfTheChat() {
        let vc = loaded()
        var asked = 0
        vc.onScrollToStart = { asked += 1 }
        _ = vc.scrollViewShouldScrollToTop(vc.collectionView)
        XCTAssertEqual(asked, 1, "the status bar tap never reached the screen")
    }

    /// Returning true would hand the scroll back to the system, which in an inverted feed
    /// means the newest message — the opposite end from the one the tap asks for.
    func testTheSystemScrollIsDeclined() {
        let vc = loaded()
        XCTAssertFalse(vc.scrollViewShouldScrollToTop(vc.collectionView))
    }

    /// UIKit delivers the tap only when exactly one visible scroll view claims it.
    func testTheFeedIsTheOnlyOneClaimingTheTap() {
        let vc = loaded()
        func claimants(_ view: UIView) -> [UIScrollView] {
            var out: [UIScrollView] = []
            if let scroll = view as? UIScrollView, scroll.scrollsToTop, !scroll.isHidden {
                out.append(scroll)
            }
            for sub in view.subviews { out += claimants(sub) }
            return out
        }
        XCTAssertEqual(claimants(vc.view).count, 1)
    }
}
