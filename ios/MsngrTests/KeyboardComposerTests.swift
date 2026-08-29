import XCTest
@testable import Msngr

/// The composer's hardware-key commands, at the unit level: the simulator's
/// hardware-keyboard pipe is not something XCUITest can hold steady between
/// runs (the same reason StatusBarTapTests lives here and not in the UI
/// smoke), so the wiring is pinned by driving the key actions directly.
/// The full path was watched live on 2026-08-30: Enter sends, Shift+Enter
/// breaks the line, Esc walks back out of the chat.
final class KeyboardComposerTests: XCTestCase {
    private func makeView() -> GrowingTextView.PasteAwareTextView {
        GrowingTextView.PasteAwareTextView()
    }

    private func press(_ tv: UITextView, _ input: String, _ flags: UIKeyModifierFlags = []) {
        guard let command = tv.keyCommands?.first(where: {
            $0.input == input && $0.modifierFlags == flags
        }) else { return XCTFail("no command for \(input)") }
        tv.perform(command.action, with: command)
    }

    /// A consumed Return sends and leaves the text alone.
    func testReturnConsumedBySendInsertsNothing() {
        let tv = makeView()
        tv.text = "hello"
        var sends = 0
        tv.onReturn = { sends += 1; return true }
        press(tv, "\r")
        XCTAssertEqual(sends, 1)
        XCTAssertEqual(tv.text, "hello", "a sent Return must not also break the line")
    }

    /// A declined Return falls back to the newline the key means elsewhere.
    func testReturnDeclinedInsertsNewline() {
        let tv = makeView()
        tv.text = "hello"
        tv.selectedRange = NSRange(location: 5, length: 0)
        tv.onReturn = { false }
        press(tv, "\r")
        XCTAssertEqual(tv.text, "hello\n")
    }

    /// Shift+Return always breaks the line, send or no send.
    func testShiftReturnAlwaysBreaksTheLine() {
        let tv = makeView()
        tv.text = "hello"
        tv.selectedRange = NSRange(location: 5, length: 0)
        tv.onReturn = { XCTFail("Shift+Return must not send"); return true }
        press(tv, "\r", .shift)
        XCTAssertEqual(tv.text, "hello\n")
    }

    /// Esc in the focused composer reaches the chat screen as a notification.
    func testEscapeForwardsToTheChatScreen() {
        let tv = makeView()
        var escapes = 0
        tv.onEscape = { escapes += 1 }
        press(tv, UIKeyCommand.inputEscape)
        XCTAssertEqual(escapes, 1)
    }

    /// Tab is consumed whole: the composer holds focus for the chat, so the
    /// key must not fill the field with tab characters.
    func testTabInsertsNothing() {
        let tv = makeView()
        tv.text = "hi"
        press(tv, "\t")
        XCTAssertEqual(tv.text, "hi")
    }

    /// The arrows walk the feed only over an empty field; with text in it the
    /// commands are absent and the caret moves as in any text view.
    func testArrowsExistOnlyOverAnEmptyField() {
        let tv = makeView()
        var walks = 0
        tv.onArrow = { _ in walks += 1; return true }
        press(tv, UIKeyCommand.inputUpArrow)
        XCTAssertEqual(walks, 1)
        tv.text = "draft"
        XCTAssertNil(tv.keyCommands?.first { $0.input == UIKeyCommand.inputUpArrow })
    }

    /// Cmd+B wraps the selection in the bold marker; a second press takes it off.
    func testBoldWrapsAndUnwraps() {
        let tv = makeView()
        tv.text = "make this bold"
        tv.selectedRange = NSRange(location: 5, length: 4)
        press(tv, "b", .command)
        XCTAssertEqual(tv.text, "make **this** bold")
        press(tv, "b", .command)
        XCTAssertEqual(tv.text, "make this bold")
    }

    /// Cmd+I with no selection inserts the pair and leaves the caret inside.
    func testItalicInsertsPairAtCaret() {
        let tv = makeView()
        tv.text = "x"
        tv.selectedRange = NSRange(location: 1, length: 0)
        press(tv, "i", .command)
        XCTAssertEqual(tv.text, "x**")
        XCTAssertEqual(tv.selectedRange, NSRange(location: 2, length: 0))
    }

    /// Cmd+K turns the selection into link markup; a URL on the clipboard
    /// becomes the target.
    func testLinkTakesTheClipboardURL() {
        UIPasteboard.general.string = "https://a.io/x"
        let tv = makeView()
        tv.text = "see docs"
        tv.selectedRange = NSRange(location: 4, length: 4)
        press(tv, "k", .command)
        XCTAssertEqual(tv.text, "see [docs](https://a.io/x)")
    }

    /// Cmd+K with no URL around leaves the caret between the parentheses.
    func testLinkWithoutClipboardLeavesCaretInTarget() {
        UIPasteboard.general.string = "not a url"
        let tv = makeView()
        tv.text = "docs"
        tv.selectedRange = NSRange(location: 0, length: 4)
        press(tv, "k", .command)
        XCTAssertEqual(tv.text, "[docs]()")
        XCTAssertEqual(tv.selectedRange, NSRange(location: 7, length: 0))
    }

    /// Ctrl+Tab asks for the next chat, Ctrl+Shift+Tab and Cmd+[ for the
    /// previous, as a notification the chat screen resolves.
    func testChatSwitchKeysPostTheirDirection() {
        let tv = makeView()
        var directions: [Bool] = []
        let sub = NotificationCenter.default.addObserver(
            forName: .chatSwitchRequested, object: nil, queue: nil
        ) { note in
            directions.append(note.userInfo?["forward"] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(sub) }
        press(tv, "\t", .control)
        press(tv, "\t", [.control, .shift])
        press(tv, "]", .command)
        press(tv, "[", .command)
        XCTAssertEqual(directions, [true, false, true, false])
    }

    /// The switch target walks the tab's rows and stops at the edges.
    func testSwitchTargetWalksTheTab() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(ChatListView.switchTarget(from: "a", in: ids, forward: true), "b")
        XCTAssertEqual(ChatListView.switchTarget(from: "b", in: ids, forward: false), "a")
        XCTAssertNil(ChatListView.switchTarget(from: "c", in: ids, forward: true))
        XCTAssertNil(ChatListView.switchTarget(from: "a", in: ids, forward: false))
        XCTAssertNil(ChatListView.switchTarget(from: "archived", in: ids, forward: true))
    }

    /// Every command claims priority over the system's text handling — without
    /// it the text view swallows the keystroke before the command fires.
    func testCommandsOutrankSystemTextHandling() {
        let tv = makeView()
        for command in tv.keyCommands ?? [] where command.input == "\r" || command.input == UIKeyCommand.inputEscape {
            XCTAssertTrue(command.wantsPriorityOverSystemBehavior,
                          "\(String(describing: command.input)) must outrank the text view")
        }
    }
}
