import XCTest

/// Smoke gate: the basic user journeys.
/// Needs wrangler dev running on :8787 and the user akuz on the server.
/// XCTest runs tests alphabetically, so the prefixes pin the order.
final class SmokeTests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // forwards a custom stand to the app under test; the test runner process
        // itself doesn't share its environment with the launched app by default
        if let server = ProcessInfo.processInfo.environment["MSNGR_SERVER"] {
            app.launchEnvironment["MSNGR_SERVER"] = server
        }
        app.launch()
        ensureRegistered()
    }

    /// On a clean simulator the first launch registers a fresh user.
    private func ensureRegistered() {
        let username = app.textFields["reg.username"]
        if username.waitForExistence(timeout: 3) {
            username.tap()
            username.typeText("ui\(Int(Date().timeIntervalSince1970) % 100_000_000)")
            // submit stays disabled until a display name (>= 3 chars) is filled too
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText("UI Tester")
            app.buttons["reg.submit"].tap()
        }
        // wait for the list itself rather than the navigation title: while the
        // list is empty the empty state covers it and the title is absent from
        // the accessibility tree. Registration generates keys, which takes
        // seconds on the simulator.
        XCTAssertTrue(app.otherElements["chatlist.root"].waitForExistence(timeout: 30)
                        || app.staticTexts["Чаты"].exists,
                      "the chat list never opened")
    }

    /// Opens the chat with akuz, from the list or through new chat search.
    private func openChatWithAkuz() {
        let existing = app.cells.containing(NSPredicate(format: "label CONTAINS 'Akuz'")).firstMatch
        if existing.waitForExistence(timeout: 2) {
            existing.tap()
        } else {
            app.buttons["chatlist.new"].tap()
            // the new chat sheet has its own field; the chat list search sits
            // underneath the sheet and matches too if you are not specific
            let search = app.searchFields["Юзернейм или имя"]
            XCTAssertTrue(search.waitForExistence(timeout: 5), "no user search field")
            search.tap()
            _ = search.waitForExistence(timeout: 1)
            search.typeText("akuz")
            let row = app.staticTexts["@akuz"]
            XCTAssertTrue(row.waitForExistence(timeout: 8), "search did not find the user akuz")
            row.tap()
        }
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 8), "the chat never opened")
    }

    private func send(_ text: String) {
        let input = app.textViews["chat.input"]
        input.tap()
        input.typeText(text)
        app.buttons["chat.send"].tap()
    }

    func testA_LaunchShowsChatList() {
        XCTAssertTrue(app.buttons["chatlist.new"].exists)
    }

    func testB_SendTextAppearsInFeed() {
        openChatWithAkuz()
        let marker = "smoke-\(Int(Date().timeIntervalSince1970))"
        send(marker)
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 8),
                      "the sent message never appeared in the feed")
    }

    func testC_DraftPersistsAcrossReopen() {
        openChatWithAkuz()
        let input = app.textViews["chat.input"]
        input.tap()
        let draft = "draft-\(Int(Date().timeIntervalSince1970))"
        input.typeText(draft)
        app.navigationBars.buttons.firstMatch.tap() // back
        XCTAssertTrue(app.staticTexts["Чаты"].waitForExistence(timeout: 5))
        openChatWithAkuz()
        let value = app.textViews["chat.input"].value as? String ?? ""
        XCTAssertTrue(value.contains(draft), "the draft was lost: '\(value)'")
        // send the draft so the next run starts from a clean input
        app.buttons["chat.send"].tap()
    }

    func testD_LongMessageContextMenu() {
        openChatWithAkuz()
        let input = app.textViews["chat.input"]
        input.tap()
        let marker = "long-\(Int(Date().timeIntervalSince1970))"
        input.typeText(marker)
        for i in 1...14 { input.typeText("\nline \(i)") }
        app.buttons["chat.send"].tap()
        let bubble = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 8))
        bubble.press(forDuration: 0.8)
        XCTAssertTrue(app.staticTexts["Ответить"].waitForExistence(timeout: 4),
                      "no context menu for a long message")
        // dismiss by tapping the background in the top left corner
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.08)).tap()
        XCTAssertFalse(app.staticTexts["Ответить"].waitForExistence(timeout: 2),
                       "the menu stayed up after a tap outside it")
    }

    func testE_AttachMenuOpensFromPaperclip() {
        openChatWithAkuz()
        app.buttons["chat.attach"].tap()
        XCTAssertTrue(app.buttons["Фото или видео"].waitForExistence(timeout: 4)
                      || app.staticTexts["Фото или видео"].waitForExistence(timeout: 1),
                      "the attachment menu never opened")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
    }
}
