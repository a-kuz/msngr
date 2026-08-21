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
            // the display name is the username: the chat row shows the name, so this is
            // what lets the other device recognise the chat with the peer
            let displayName = app.textFields["reg.displayName"]
            displayName.tap()
            displayName.typeText(username)
            app.buttons["reg.submit"].tap()
        }
        // key generation on a loaded simulator takes its time, and the empty list keeps
        // the navigation title out of the tree, so the list itself is what we wait for
        XCTAssertTrue(chatList.waitForExistence(timeout: 120), "the chat list never opened")
    }

    /// The row of a direct chat is titled with the peer's display name; a device
    /// registered by an earlier run of this suite carries "UI Tester" instead of its
    /// username, and is recognised by that name too.
    private func openPeerChat() {
        // a tap on a row of a list that is still settling is swallowed now and then, and
        // the second one lands, so the row is offered the touch twice before giving up
        for attempt in 0..<2 {
            if attempt > 0 && !chatList.waitForExistence(timeout: 5) { break }
            tapPeerRow()
            // the first message from someone new arrives as a request, and its content
            // stays closed until it is accepted; the side that started the chat never
            // sees this
            let accept = app.buttons["request.accept"]
            if accept.waitForExistence(timeout: 3) { accept.tap() }
            if app.textViews["chat.input"].waitForExistence(timeout: 15) { return }
        }
        XCTFail("the chat never opened")
    }

    private func tapPeerRow() {
        let byTitle = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS 'UI Tester'", peer)
        let existing = app.cells.containing(byTitle).firstMatch
        if existing.waitForExistence(timeout: 3) {
            existing.tap()
        } else {
            app.buttons["chatlist.new"].tap()
            let search = userSearchField()
            XCTAssertTrue(search.waitForExistence(timeout: 10), "no user search field")
            type(peer, into: search)
            let row = app.staticTexts["@\(peer)"]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "search did not find the user \(peer)")
            row.tap()
        }
    }

    /// The search field of the new chat sheet. Its placeholder is localised, so naming
    /// it would tie the run to the host's language; the list's own field is behind the
    /// sheet and takes no touch, which is what tells the two apart.
    private func userSearchField() -> XCUIElement {
        let fields = app.searchFields
        _ = fields.firstMatch.waitForExistence(timeout: 10)
        return fields.allElementsBoundByIndex.first { $0.isHittable } ?? fields.firstMatch
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

    /// The play buttons on screen, oldest message first: the order of the bubbles in the
    /// accessibility tree says nothing about the order they were sent in, the screen does.
    private func playButtons() -> [XCUIElement] {
        app.descendants(matching: .any).matching(identifier: "voice.play")
            .allElementsBoundByIndex.sorted { $0.frame.maxY < $1.frame.maxY }
    }

    private var newestPlay: XCUIElement {
        playButtons().last ?? play
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

    /// The button of the message that is playing. It carries its own identifier: the
    /// label is translated with the rest of the interface, and naming it would tie the
    /// run to the language of the host.
    private var pauseButton: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "voice.pause").firstMatch
    }

    /// The speed the button stands at. Its label is translated with the interface, so
    /// the run reads the value, which is the same in every language.
    private func rateSpeed() -> String {
        rateButton.value as? String ?? ""
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

    /// How far along the wave the player has got, in percent. Every wave that is not the
    /// one playing stands at zero, so the largest of them is the position; a failure then
    /// carries the number instead of a missing-element error.
    private func progress() -> Int {
        app.descendants(matching: .any).matching(identifier: "voice.wave")
            .allElementsBoundByIndex
            .compactMap { Int($0.value as? String ?? "") }
            .max() ?? -1
    }

    /// The position once it has passed `mark`, or whatever it still is when the wait runs
    /// out. A host with a dozen builds on it can leave the app without a frame for
    /// seconds, and a position read once at a fixed moment then says "stopped" about a
    /// message that is playing perfectly well.
    private func progress(above mark: Int, timeout: TimeInterval = 15) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        var value = progress()
        while value <= mark, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            value = progress()
        }
        return value
    }

    /// Puts the position of the message that is playing back to the start, so a borrowed
    /// take of unknown length still has room for what comes next. A tap on the wave of a
    /// running message moves inside it and leaves it running.
    private func rewind() {
        playingWave.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.5)).tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 3),
                      "the message stopped when the position was moved")
    }

    /// Records a take of the given length with the lock and sends it. What lands at the
    /// bottom of the feed has to be this take, by its length: a chat holds more voice
    /// messages than fit on a screen, so counting the bubbles on it says nothing.
    private func sendVoice(seconds: TimeInterval) {
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(app.buttons["chat.sendVoice"].waitForExistence(timeout: 5),
                      "a locked recording has no send button")
        Thread.sleep(forTimeInterval: seconds)
        app.buttons["chat.sendVoice"].tap()
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the take never reached the feed")
        XCTAssertFalse(recordingBar.exists, "the recording bar stayed up after sending")
        let landed = length(of: newestPlay)
        XCTAssertGreaterThanOrEqual(landed, Int(seconds),
                                    "the newest take is \(landed) s, shorter than the one just made")
        XCTAssertLessThanOrEqual(landed, Int(seconds) + 6,
                                 "the newest take is \(landed) s, longer than the one just made")
    }

    /// The length written on a bubble, in seconds. The duration sits next to the play
    /// button — a clock time carries two digits before the colon and is left out.
    private func length(of playButton: XCUIElement) -> Int {
        let texts = app.staticTexts
            .matching(NSPredicate(format: "label MATCHES '[0-9]:[0-9]{2}'"))
            .allElementsBoundByIndex
        let mine = texts.first {
            abs($0.frame.midY - playButton.frame.midY) < 24
                && $0.frame.minX > playButton.frame.minX
                && $0.frame.minX - playButton.frame.maxX < 60
        }
        let parts = (mine?.label ?? "").split(separator: ":")
        guard parts.count == 2, let minutes = Int(parts[0]), let seconds = Int(parts[1]) else {
            return -1
        }
        return minutes * 60 + seconds
    }

    /// The play button of the longest take on screen: a test that has to survive a walk
    /// to the list needs a message that will not simply end on the way.
    private func longestPlay() -> XCUIElement {
        playButtons().max { length(of: $0) < length(of: $1) } ?? newestPlay
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
        app.navigationBars.buttons.element(boundBy: 0).tap() // the system back button
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "never got back to the list")
        openPeerChat()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 3),
                       "the recording survived leaving the chat")
        XCTAssertEqual(voiceCount(), before, "the dropped take was sent anyway")
    }

    /// The app leaves the foreground mid-take, the way an incoming call takes it away:
    /// the recording stops and nothing is sent. A call cannot be raised on a simulator, so
    /// this is as close as the run gets; the audio session interruption itself is checked
    /// in `RecordingGestureTests`.
    func testE1_LeavingTheAppDropsTheTake() {
        openPeerChat()
        XCTAssertTrue(mic.waitForExistence(timeout: 10), "no microphone button")
        let before = voiceCount()
        micCenter().press(forDuration: 1.0,
                          thenDragTo: micCenter().withOffset(CGVector(dx: 0, dy: -110)))
        XCTAssertTrue(recordingBar.waitForExistence(timeout: 3), "the recording never locked")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 2)
        app.activate()
        XCTAssertFalse(recordingBar.waitForExistence(timeout: 5),
                       "the recording survived the app leaving the foreground")
        XCTAssertEqual(voiceCount(), before, "the dropped take was sent anyway")
    }

    /// The message in the feed plays, the position moves along the wave, and the speed
    /// button is on the message being played.
    func testF_PlaybackRunsAndSpeedSticks() {
        openPeerChat()
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        newestPlay.tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 5), "the message never started")
        XCTAssertTrue(rateButton.waitForExistence(timeout: 5),
                      "the message being played has no speed button")
        let first = progress(above: 0)
        XCTAssertGreaterThan(first, 0, "the position stayed at the start")
        XCTAssertGreaterThan(progress(above: first), first,
                             "the position stopped moving at \(first)")

        // the speed belongs to a message that is still running, and the take this test
        // borrows can be a few seconds long, so the position goes back to the start first
        rewind()
        XCTAssertEqual(rateSpeed(), "1×")
        rateButton.tap()
        XCTAssertEqual(rateSpeed(), "1,5×", "the speed button did not step to 1,5×")
        rateButton.tap()
        XCTAssertEqual(rateSpeed(), "2×", "the speed button did not step to 2×")
    }

    /// The speed is not just a caption on a button: at 2× the position walks the wave
    /// about twice as fast. The take is recorded here because the measurement needs a
    /// message long enough to outlast both samples.
    func testF1_SpeedReallyPlaysFaster() {
        openPeerChat()
        sendVoice(seconds: 20)
        newestPlay.tap()
        XCTAssertTrue(rateButton.waitForExistence(timeout: 5),
                      "the message being played has no speed button")
        Thread.sleep(forTimeInterval: 0.5)
        let oneFrom = progress()
        Thread.sleep(forTimeInterval: 3)
        let atOne = progress() - oneFrom
        XCTAssertGreaterThan(atOne, 0, "the position stayed at the start")

        rateButton.tap()
        rateButton.tap()
        XCTAssertEqual(rateSpeed(), "2×", "the speed button did not reach 2×")
        let twoFrom = progress()
        Thread.sleep(forTimeInterval: 3)
        let atTwo = progress() - twoFrom
        XCTAssertGreaterThan(atTwo, Int(Double(atOne) * 1.5),
                             "three seconds moved the position by \(atOne)% at 1× and \(atTwo)% at 2×")
    }

    /// A message keeps playing while the reader walks out to the list and back, and the
    /// position it comes back to is further along than the one it left. The take is
    /// recorded here rather than borrowed: it has to outlast the walk, otherwise a
    /// message that simply ended reads the same as one that was cut off.
    func testG_PlaybackSurvivesAnotherChat() {
        openPeerChat()
        sendVoice(seconds: 25)
        newestPlay.tap()
        let left = progress(above: 0)
        XCTAssertGreaterThan(left, 0, "playback never started")

        app.navigationBars.buttons.element(boundBy: 0).tap() // the system back button
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

    /// The speed belongs to the player, not to the bubble: what the reader chose on one
    /// message is what the next one starts at.
    func testI_SpeedHoldsBetweenMessages() {
        openPeerChat()
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        let all = playButtons()
        guard all.count >= 2 else {
            return XCTFail("the chat needs two voice messages, it has \(all.count)")
        }
        all[all.count - 1].tap()
        XCTAssertTrue(rateButton.waitForExistence(timeout: 5),
                      "the message being played has no speed button")
        rateButton.tap()
        XCTAssertEqual(rateSpeed(), "1,5×", "the speed button did not step to 1,5×")
        // the buttons move as the speed button appears next to the duration, so ask again
        playButtons()[0].tap()
        Thread.sleep(forTimeInterval: 0.7)
        XCTAssertEqual(rateSpeed(), "1,5×",
                       "the speed went back to 1× when another message started")
        XCTAssertGreaterThan(progress(above: 0), 0, "the other message never started")
    }

    /// The receiving side of the same rule: a message that came in goes on playing while
    /// the reader walks out to the list and back. The take is not recorded here, it is the
    /// one the peer sent, which is the whole point of running this on the second device.
    func testJ_IncomingPlaybackSurvivesTheList() {
        openPeerChat()
        XCTAssertTrue(play.waitForExistence(timeout: 15), "no voice message in the chat")
        longestPlay().tap()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 5), "the message never started")
        XCTAssertGreaterThan(progress(above: 0), 0, "the position stayed at the start")

        // the walk begins with the whole take ahead of it, or a message that simply ended
        // reads the same as one that was cut off
        rewind()
        app.navigationBars.buttons.element(boundBy: 0).tap() // the system back button
        XCTAssertTrue(chatList.waitForExistence(timeout: 10), "never got back to the list")
        Thread.sleep(forTimeInterval: 1.5)
        openPeerChat()
        XCTAssertTrue(pauseButton.waitForExistence(timeout: 3),
                      "the message stopped playing on the way out of the chat")
        XCTAssertGreaterThan(progress(), 0,
                             "the position did not move while the chat was closed")
    }
}
