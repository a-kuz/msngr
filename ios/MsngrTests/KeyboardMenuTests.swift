import XCTest
@testable import Msngr

/// The Mac menu bar's menus: two of them, whose commands name the composer's
/// selectors, so the responder chain enables an item exactly where its key
/// already works.
final class KeyboardMenuTests: XCTestCase {
    func testMenusCarryTheComposerSelectors() {
        let menus = AppDelegate.keyboardMenus()
        XCTAssertEqual(menus.count, 2)
        let selectors = menus
            .flatMap(\.children)
            .compactMap { ($0 as? UICommand)?.action }
            .map(NSStringFromSelector)
        XCTAssertEqual(selectors, ["switchChatForward", "switchChatBackward",
                                   "editLastMessage", "makeBold", "makeItalic", "makeLink"])
    }

    /// Every menu selector is really implemented by the composer's text view —
    /// the responder chain has somewhere to land.
    func testComposerAnswersEveryMenuSelector() {
        let tv = GrowingTextView.PasteAwareTextView()
        for command in AppDelegate.keyboardMenus().flatMap(\.children).compactMap({ $0 as? UICommand }) {
            XCTAssertTrue(tv.responds(to: command.action),
                          "\(command.action) has no home in the composer")
        }
    }
}
