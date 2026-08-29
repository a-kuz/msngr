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
