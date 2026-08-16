import XCTest

/// Voice messages on a live screen: an accidental touch, slide-to-cancel, the lock,
/// leaving the chat mid-take, and on the receiving side playback, its position, the
/// speed and what happens to a message playing while the reader walks into another chat.
/// Needs wrangler dev on :8787 (or MSNGR_SERVER) and the peer from MSNGR_PEER, akuz by
/// default, registered there. On a stand of its own the two devices are brought up in
/// order: `testAA_Registers` on each with its own MSNGR_USERNAME, then the rest.
final class VoiceTests: XCTestCase {
    var app: XCUIApplication!

    private var peer: String {
        ProcessInfo.processInfo.environment["MSNGR_PEER"] ?? "akuz"
    }

    /// A run over two devices needs to know both names beforehand, so the username can
    /// be handed in; on its own the device registers whoever it likes.
    private var username: String {
        ProcessInfo.processInfo.environment["MSNGR_USERNAME"]
            ?? "ui\(Int(Date().timeIntervalSince1970) % 100_000_000)"
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        if let server = ProcessInfo.processInfo.environment["MSNGR_SERVER"] {
            app.launchEnvironment["MSNGR_SERVER"] = server
        }
        app.launch()
        ensureRegistered()
    }

    /// A device on its own: registration, and nothing that needs the other side yet.
    /// This is what brings the second device of a two-device run into being.
    func testAA_Registers() {
        XCTAssertTrue(app.buttons["chatlist.new"].waitForExistence(timeout: 10),
                      "the chat list has no new chat button")
    }

    private func ensureRegistered() {
        let field = app.textFields["reg.username"]
        if field.waitForExistence(timeout: 5) {
            field.tap()
            field.typeText(username)
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText("UI Tester")
            app.buttons["reg.submit"].tap()
        }
        // key generation on a loaded simulator takes its time, and the empty list keeps
        // the navigation title out of the tree, so the list itself is what we wait for
        XCTAssertTrue(chatList.waitForExistence(timeout: 120), "the chat list never opened")
    }

    private func openPeerChat() {
        let existing = app.cells.containing(NSPredicate(format: "label CONTAINS[c] %@", peer)).firstMatch
        if existing.waitForExistence(timeout: 3) {
            existing.tap()
        } else {
            app.buttons["chatlist.new"].tap()
            let search = app.searchFields["Юзернейм или имя"]
            XCTAssertTrue(search.waitForExistence(timeout: 10), "no user search field")
            type(peer, into: search)
            let row = app.staticTexts["@\(peer)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "search did not find the user \(peer)")
            row.tap()
        }
        XCTAssertTrue(app.textViews["chat.input"].waitForExistence(timeout: 15), "the chat never opened")
    }

    /// A sheet that has just come up takes the first tap to settle and only then the
    /// keyboard, so typing waits for the keyboard and taps again if it never arrived.
    private func type(_ text: String, into field: XCUIElement) {
        for _ in 0..<3 {
            field.tap()
            if app.keyboards.element.waitForExistence(timeout: 5) {
                field.typeText(text)
                return
            }
        }
        XCTFail("the field never took the keyboard")
    }

    /// The list carries its identifier on several elements at once, and which of them
    /// answers depends on whether the empty state is up, so the type is left open.
    private var chatList: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chatlist.root").firstMatch
    }

    private var mic: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.mic").firstMatch
    }

    private var recordingBar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "chat.recording").firstMatch
    }

    private var play: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "voice.play").firstMatch
    }

    /// The newest message is the one lowest on the screen: the order of the bubbles in
    /// the accessibility tree says nothing about the order they were sent in.
    private var newestPlay: XCUIElement {
        let all = app.descendants(matching: .any)
            .matching(identifier: "voice.play").allElementsBoundByIndex
        return all.max { $0.frame.maxY < $1.frame.maxY } ?? play
    }

    private var newestWave: XCUIElement {
        let all = app.descendants(matching: .any)
            .matching(identifier: "voice.wave").allElementsBoundByIndex
        return all.max { $0.frame.maxY < $1.frame.maxY } ?? playingWave
    }

    /// The wave of whatever is playing: it is the only one standing away from the start.
    private var playingWave: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'voice.wave' AND value != '0'"))
            .firstMatch
    }

    private var pauseButton: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'voice.play' AND label == 'Пауза'"))
            .firstMatch
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
        Int(playingWave.value as? String ?? "") ?? -1
    }

    /// Records a take of the given length with the lock and sends it.
    private func sendVoice(seconds: TimeInterval) {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(app.buttons["chat.sendVoice"].waitForExistence(timeout: 5),
                      "a locked recording has no send button")
        Thread.sleep(forTimeInterval: seconds)
        app.buttons["chat.sendVoice"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the take never reached the feed")
        XCTAssertEqual(voiceCount(), before + 1, "the feed did not gain exactly one voice message")
    }

    /// A touch too short to be a message leaves the recorder stopped and the feed as it
    /// was: no file, no bubble, no second of silence for the other side.
    func testA_AccidentalTapLeavesNoMessage() {
        openPeerChat()
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
        openPeerChat()
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
        openPeerChat()
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
        openPeerChat()
        sendVoice(seconds: 6)
    }

    /// Leaving the chat while recording drops the take instead of sending a stump.
    func testE_LeavingChatDropsTheTake() {
        openPeerChat()
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(recordingBar.waitForExistence(timeout: 3), "the recording never locked")
        app.buttons["chat.back"].tap()
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "never got back to the list")
        openPeerChat()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "the recording survived leaving the chat")
        XCTAssertEqual(voiceCount(), before, "the dropped take was sent anyway")
    }

    /// The message in the feed plays, the position moves along the wave, and the speed
    /// button is on the message being played.
    func testF_PlaybackRunsAndSpeedSticks() {
        openPeerChat()
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        newestPlay.tap()
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

    /// A message keeps playing while the reader walks out to the list and back, and the
    /// position it comes back to is further along than the one it left. The take is
    /// recorded here rather than borrowed: it has to outlast the walk, otherwise a
    /// message that simply ended reads the same as one that was cut off.
    func testG_PlaybackSurvivesAnotherChat() {
        openPeerChat()
        sendVoice(seconds: 25)
        newestPlay.tap()
        Thread.sleep(forTimeInterval: 1)
        let left = progress()
        XCTAssertGreaterThan(left, 0, "playback never started")

        app.buttons["chat.back"].tap()
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "never got back to the list")
        Thread.sleep(forTimeInterval: 2)
        openPeerChat()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 3),
                      "the message stopped playing on the way out of the chat")
        XCTAssertGreaterThan(progress(), left,
                             "the position did not move while the chat was closed")
    }

    /// A tap along the wave: a message at rest starts from the point touched, and one
    /// that is playing moves to it.
    func testH_TheWaveSeeks() {
        openPeerChat()
        sendVoice(seconds: 10)
        let wave = newestWave
        wave.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertGreaterThan(progress(), 60,
                             "a tap on the wave of a message at rest did not start it there")
        wave.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5)).tap()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertLessThan(progress(), 45, "a tap further back along the wave did not move the position")
    }
}
