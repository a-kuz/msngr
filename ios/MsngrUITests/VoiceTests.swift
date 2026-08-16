import XCTest

/// Voice messages on a live screen: an accidental touch, slide-to-cancel, the lock,
/// leaving the chat mid-take, and on the receiving side playback, its position, the
/// speed and what happens to a message playing while the reader walks into another chat.
/// Needs wrangler dev on :8787 (or MSNGR_SERVER) and the peer from MSNGR_PEER, akuz by
/// default, registered there.
final class VoiceTests: XCTestCase {
    var app: XCUIApplication!

    private var peer: String {
        ProcessInfo.processInfo.environment["MSNGR_PEER"] ?? "akuz"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if let server = ProcessInfo.processInfo.environment["MSNGR_SERVER"] {
            app.launchEnvironment["MSNGR_SERVER"] = server
        }
        app.launch()
        ensureRegistered()
        openPeerChat()
    }

    private func ensureRegistered() {
        let username = app.textFields["reg.username"]
        if username.waitForExistence(timeout: 5) {
            username.tap()
            username.typeText("ui\(Int(Date().timeIntervalSince1970) % 100_000_000)")
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText("UI Tester")
            app.buttons["reg.submit"].tap()
        }
        // key generation on a loaded simulator takes its time, and the empty list keeps
        // the navigation title out of the tree, so the list itself is what we wait for
        XCTAssertTrue(app.otherElements["chatlist.root"].waitForExistence(timeout: 120),
                      "the chat list never opened")
    }

    private func openPeerChat() {
        let existing = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", peer)).firstMatch
        if existing.waitForExistence(timeout: 3) {
            existing.tap()
        } else {
            app.buttons["chatlist.new"].tap()
            let search = app.searchFields["Юзернейм или имя"]
            XCTAssertTrue(search.waitForExistence(timeout: 10), "no user search field")
            search.tap()
            search.typeText(peer)
            let row = app.staticTexts["@\(peer)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "search did not find the user \(peer)")
            row.tap()
        }
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15), "the chat never opened")
    }

    private var mic: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.mic").firstMatch
    }

    private var recordingBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.recording").firstMatch
    }

    private var wave: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "voice.wave").firstMatch
    }

    private var play: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "voice.play").firstMatch
    }

    private var rateButton: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "voice.rate").firstMatch
    }

    private func micCenter() -> XCUICoordinate {
        mic.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }

    private func voiceCount() -> Int {
        app.descendants(matching: .any).matching(identifier: "voice.play").count
    }

    private func progress() -> Int {
        Int(wave.value as? String ?? "") ?? -1
    }

    /// A touch too short to be a message leaves the recorder stopped and the feed as it
    /// was: no file, no bubble, no second of silence for the other side.
    func testA_AccidentalTapLeavesNoMessage() {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        mic.tap()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "an accidental tap left a recording running")
        XCTAssertTrue(app.textViews["chat.input"].exists, "the composer never came back")
        XCTAssertEqual(voiceCount(), before, "an accidental tap sent a voice message")
    }

    /// Sliding left past the threshold ends the take, and the finger going on moving
    /// over the button does not start a second one.
    func testB_SlideLeftCancels() {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: -170, dy: 0)))
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "the recording bar stayed up after slide-to-cancel")
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 5),
                      "the composer never came back after a cancel")
        XCTAssertEqual(voiceCount(), before, "a cancelled take was sent anyway")
    }

    /// Sliding up locks: the finger comes off and the take goes on, with a send button
    /// and a cancel that really stops it.
    func testC_SlideUpLocksAndCancels() {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(recordingBar.waitForExistence(timeout: 3),
                      "the recording stopped when the finger came off a locked take")
        XCTAssertTrue(app.buttons["chat.sendVoice"].waitForExistence(timeout: 3),
                      "a locked recording has no send button")
        app.buttons["chat.cancelVoice"].tap()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "the cancel button left the recording running")
        XCTAssertEqual(voiceCount(), before, "a cancelled locked take was sent anyway")
    }

    /// A locked take is sent by its button and lands in the feed.
    func testD_LockedRecordingSends() {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(app.buttons["chat.sendVoice"].waitForExistence(timeout: 5),
                      "a locked recording has no send button")
        // a take worth playing back afterwards
        Thread.sleep(forTimeInterval: 6)
        app.buttons["chat.sendVoice"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 20),
                      "the sent voice message never appeared in the feed")
        XCTAssertEqual(voiceCount(), before + 1, "the feed did not gain exactly one voice message")
    }

    /// Leaving the chat while recording drops the take instead of sending a stump.
    func testE_LeavingChatDropsTheTake() {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(recordingBar.waitForExistence(timeout: 3), "the recording never locked")
        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.otherElements["chatlist.root"].waitForExistence(timeout: 10),
                      "never got back to the list")
        openPeerChat()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "the recording survived leaving the chat")
        XCTAssertEqual(voiceCount(), before, "the dropped take was sent anyway")
    }

    /// The message in the feed plays, the position moves along the wave, and the speed
    /// button is on the message being played.
    func testF_PlaybackRunsAndSpeedSticks() {
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        play.tap()
        XCTAssertTrue(rateButton.waitForExistence(timeout: 5),
                      "the message being played has no speed button")
        Thread.sleep(forTimeInterval: 1.5)
        let first = progress()
        XCTAssertGreaterThan(first, 0, "the position stayed at the start")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertGreaterThan(progress(), first, "the position stopped moving")

        XCTAssertEqual(rateButton.label, "Скорость 1×")
        rateButton.tap()
        XCTAssertEqual(rateButton.label, "Скорость 1,5×", "the speed button did not step to 1,5×")
        rateButton.tap()
        XCTAssertEqual(rateButton.label, "Скорость 2×", "the speed button did not step to 2×")
    }

    /// A message keeps playing while the reader walks out to the list and into another
    /// chat, and the position it comes back to is further along than the one it left.
    func testG_PlaybackSurvivesAnotherChat() {
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        play.tap()
        Thread.sleep(forTimeInterval: 1)
        let left = progress()
        XCTAssertGreaterThan(left, 0, "playback never started")

        app.buttons["chat.back"].tap()
        XCTAssertTrue(app.otherElements["chatlist.root"].waitForExistence(timeout: 10),
                      "never got back to the list")
        Thread.sleep(forTimeInterval: 2)
        openPeerChat()
        XCTAssertGreaterThan(progress(), left,
                             "the position did not move while the chat was closed")
        XCTAssertEqual(play.label, "Пауза", "the message stopped playing on the way")
    }
}
