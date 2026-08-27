import XCTest
import UserNotifications
@testable import Msngr

/// Routing of a notification response: which action identifier and payload lead
/// to opening the chat, sending a quick reply, or muting.
final class NotificationActionRouteTests: XCTestCase {

    func testTheDefaultTapOpensTheChat() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            chatId: "c1", userText: nil), .open(chatId: "c1"))
    }

    func testReplySendsTheTrimmedText() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: NotificationActions.replyAction,
            chatId: "c1", userText: "  привет \n"), .reply(chatId: "c1", text: "привет"))
    }

    func testAnEmptyReplySendsNothing() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: NotificationActions.replyAction,
            chatId: "c1", userText: "   "), .none)
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: NotificationActions.replyAction,
            chatId: "c1", userText: nil), .none)
    }

    func testMuteMutesTheChat() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: NotificationActions.muteAction,
            chatId: "c1", userText: nil), .mute(chatId: "c1"))
    }

    func testWithoutAChatNothingHappens() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            chatId: nil, userText: nil), .none)
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: NotificationActions.replyAction,
            chatId: "", userText: "hi"), .none)
    }

    func testDismissAndUnknownActionsDoNothing() {
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            chatId: "c1", userText: nil), .none)
        XCTAssertEqual(NotificationActions.route(
            actionIdentifier: "somethingElse", chatId: "c1", userText: nil), .none)
    }

    func testTheCategoryCarriesBothActions() {
        let category = NotificationActions.messageCategory()
        XCTAssertEqual(category.identifier, "message")
        XCTAssertEqual(category.actions.map(\.identifier),
                       [NotificationActions.replyAction, NotificationActions.muteAction])
        XCTAssertTrue(category.actions.first is UNTextInputNotificationAction)
    }
}
