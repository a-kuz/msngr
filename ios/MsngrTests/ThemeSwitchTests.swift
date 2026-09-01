import UIKit
import XCTest
@testable import Msngr
import MsngrCore

/// The bubble background is an image baked for one appearance, while the text
/// repaints itself dynamically: a system light/dark switch over an open chat
/// must re-bake the visible bubbles too, or a light plate is left under white
/// text.
final class ThemeSwitchTests: XCTestCase {
    private let width: CGFloat = 390

    private func loaded() -> (MessagesViewController, UIWindow) {
        let vc = MessagesViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 844))
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = vc
        window.isHidden = false
        vc.loadViewIfNeeded()
        vc.view.layoutIfNeeded()
        return (vc, window)
    }

    private func feed() -> [ChatFeedItem] {
        var m = Message(id: "m1", chatId: "c", fromUserId: "peer",
                        sentAt: 1_700_000_000, kind: .text,
                        text: "Читаемый и в тёмной теме",
                        status: .sent, isOutgoing: false)
        m.seq = 1
        m.serverTs = 1_700_000_000
        return [.message(m, tightGap: false, showTail: true, showName: false,
                         authorName: nil, replyAuthorName: nil)]
    }

    private func bubbleImage(in view: UIView) -> UIImage? {
        for sub in view.subviews {
            if let iv = sub as? UIImageView, let img = iv.image { return img }
            if let img = bubbleImage(in: sub) { return img }
        }
        return nil
    }

    @MainActor
    func testAppearanceSwitchRebakesTheVisibleBubble() {
        let (vc, window) = loaded()
        vc.apply(feed())
        vc.collectionView.layoutIfNeeded()
        let path = IndexPath(item: 0, section: 0)
        guard let cell = vc.collectionView.cellForItem(at: path) else {
            return XCTFail("the message cell never materialised")
        }
        var light: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            light = BubbleBackground.image(outgoing: false, mediaOnly: false)
        }
        XCTAssertTrue(bubbleImage(in: cell) === light, "the cell starts with the light bake")

        window.overrideUserInterfaceStyle = .dark
        window.layoutIfNeeded()
        vc.collectionView.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        var dark: UIImage?
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            dark = BubbleBackground.image(outgoing: false, mediaOnly: false)
        }
        guard let visible = vc.collectionView.cellForItem(at: path) else {
            return XCTFail("the cell left the screen on the switch")
        }
        XCTAssertTrue(bubbleImage(in: visible) === dark,
                      "an appearance switch must re-bake the visible bubble for the new style")
    }
}
