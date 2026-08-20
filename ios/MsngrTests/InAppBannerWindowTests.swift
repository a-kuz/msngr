import UIKit
import XCTest
@testable import Msngr

/// The window the in-app banner lives in. The owner reported a banner that
/// ignored taps: its window had been cropped to the measured height of the
/// content, and a window does not clip what is drawn past its bounds — the
/// banner stayed visible and stopped taking touches. What has to hold once the
/// banner has settled: a touch on it reaches the banner and stays inside the
/// window, and a touch anywhere else goes to the app underneath.
@MainActor
final class InAppBannerWindowTests: XCTestCase {
    override func tearDown() {
        InAppBannerPresenter.dismiss(animated: false)
        super.tearDown()
    }

    /// Shows a banner and lets it arrive: it slides in from above the edge, so a
    /// window read before the animation settles says nothing about touches.
    private func settledBanner() throws -> UIWindow {
        InAppBannerPresenter.show(title: "Peer", subtitle: nil, body: "a line of text",
                                  avatar: nil, chatId: "chat-1")
        guard let window = InAppBannerPresenter.window else {
            throw XCTSkip("no foreground scene to put a window in")
        }
        let settled = expectation(description: "the banner arrived")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 3)
        window.layoutIfNeeded()
        return window
    }

    /// Where the banner is drawn: the window is the band, so its own middle.
    private func bannerPoint(in window: UIWindow) -> CGPoint {
        CGPoint(x: window.bounds.midX, y: window.bounds.midY)
    }

    func testATouchOnTheBannerReachesIt() throws {
        let window = try settledBanner()
        let hit = window.hitTest(bannerPoint(in: window), with: nil)
        XCTAssertNotNil(hit, "a touch where the banner is drawn found nothing")
        XCTAssertFalse(hit === window, "the touch stopped at the window itself")
    }

    func testWhatTakesTheTouchIsInsideTheWindow() throws {
        let window = try settledBanner()
        let hit = try XCTUnwrap(window.hitTest(bannerPoint(in: window), with: nil))
        let frame = hit.convert(hit.bounds, to: window)
        XCTAssertTrue(window.bounds.contains(frame),
                      "the banner takes touches outside its window: \(frame) against \(window.bounds)")
    }

    /// The banner's window takes every touch inside itself, so it must be a band
    /// at the top edge: everything below stays the app's.
    func testTheWindowIsOnlyTheBandTheBannerNeeds() throws {
        let window = try settledBanner()
        let screen = window.windowScene?.screen.bounds ?? UIScreen.main.bounds
        XCTAssertLessThan(window.frame.maxY, screen.midY,
                          "the banner's window reaches into the screen it has no business covering")
        // the content fills the band it was measured for, with nothing left over
        let content = try XCTUnwrap(window.rootViewController?.view)
        XCTAssertEqual(content.frame.height, window.bounds.height, accuracy: 0.5,
                       "the banner is laid out for a height its window does not have")
    }
}
