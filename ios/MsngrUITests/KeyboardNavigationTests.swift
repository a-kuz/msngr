import XCTest

/// Hardware-keyboard navigation of the chat list: the arrows walk the rows,
/// Enter opens the selected chat, Cmd+N opens the new chat sheet. The keys are
/// sent as real HID events by the test daemon, the same path an attached
/// keyboard takes on an iPad or a Mac running the app as «Designed for iPad».
/// Needs wrangler dev running on :8787.
final class KeyboardNavigationTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if let server = ProcessInfo.processInfo.environment["MSNGR_SERVER"] {
            app.launchEnvironment["MSNGR_SERVER"] = server
        }
        app.launch()
        ensureRegistered()
    }

    private func ensureRegistered() {
        let username = app.textFields["reg.username"]
        if username.waitForExistence(timeout: 3) {
            username.tap()
            username.typeText("kb\(Int(Date().timeIntervalSince1970) % 100_000_000)")
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText("KB Tester")
            app.buttons["reg.submit"].tap()
        }
        let list = app.descendants(matching: .any).matching(identifier: "chatlist.root").firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 30), "the chat list never opened")
    }

    /// Down-arrow enters the list at its top and Enter opens that chat: a
    /// fresh account owns exactly one — the chat with yourself.
    func testArrowsSelectAndEnterOpens() {
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 8),
                      "Enter on the keyboard selection did not open the chat")
    }

    // The composer's own keys — Enter sends, Shift+Enter breaks the line, Esc
    // walks out — are pinned in MsngrTests/KeyboardComposerTests: the
    // simulator's hardware-keyboard pipe drifts between runs and XCUITest
    // cannot hold it steady, the StatusBarTapTests situation over again.

    /// Cmd+N opens the new chat sheet from the list.
    func testCmdNOpensNewChat() {
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5),
                      "Cmd+N did not open the new chat sheet")
    }
}
