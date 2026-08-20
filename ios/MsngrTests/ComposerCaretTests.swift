import SwiftUI
import UIKit
import XCTest
@testable import Msngr

/// Where the caret lands when the composer is written into from its binding.
/// The owner typed «123» on the device and got «231»: the first character
/// arrived through the binding while the view still reported an empty field,
/// and the caret was put back at its absolute position — in front of what had
/// just been typed. Everything after that went in before the first character.
final class ComposerCaretTests: XCTestCase {
    private func composer(text: Binding<String>) -> (GrowingTextView, UITextView,
                                                     GrowingTextView.Coordinator) {
        let view = GrowingTextView(text: text, onChange: { _ in })
        let tv = UITextView(frame: CGRect(x: 0, y: 0, width: 240, height: 36))
        return (view, tv, view.makeCoordinator())
    }

    func testTheFirstCharacterKeepsTheCaretBehindIt() {
        var value = "1"
        let (view, tv, coordinator) = composer(text: .init(get: { value }, set: { value = $0 }))
        // the field the view holds: empty, the caret at its only position
        tv.text = ""
        tv.selectedRange = NSRange(location: 0, length: 0)

        view.applyText("1", to: tv, coordinator: coordinator)

        XCTAssertEqual(tv.text, "1")
        XCTAssertEqual(tv.selectedRange.location, 1,
                       "the caret must stand behind the typed character, not in front of it")
    }

    func testTypingContinuesInOrderAfterSuchAWrite() {
        var value = "1"
        let (view, tv, coordinator) = composer(text: .init(get: { value }, set: { value = $0 }))
        tv.text = ""
        tv.selectedRange = NSRange(location: 0, length: 0)
        view.applyText("1", to: tv, coordinator: coordinator)

        // what the keyboard does with the next two characters at that caret
        for next in ["2", "3"] {
            tv.replace(tv.selectedTextRange!, withText: next)
        }
        XCTAssertEqual(tv.text, "123", "the characters must land in the order they were typed")
    }

    func testSendLeavesAnEmptyFieldWithTheCaretAtItsStart() {
        var value = ""
        let (view, tv, coordinator) = composer(text: .init(get: { value }, set: { value = $0 }))
        tv.text = "hello"
        tv.selectedRange = NSRange(location: 5, length: 0)

        view.applyText("", to: tv, coordinator: coordinator)

        XCTAssertEqual(tv.text, "")
        XCTAssertEqual(tv.selectedRange.location, 0)
    }

    func testARestoredDraftPutsTheCaretAtItsEnd() {
        var value = "unsent draft"
        let (view, tv, coordinator) = composer(text: .init(get: { value }, set: { value = $0 }))
        tv.text = ""
        tv.selectedRange = NSRange(location: 0, length: 0)

        view.applyText("unsent draft", to: tv, coordinator: coordinator)

        XCTAssertEqual(tv.selectedRange.location, ("unsent draft" as NSString).length,
                       "a restored draft is continued, so the caret belongs at its end")
    }
}
