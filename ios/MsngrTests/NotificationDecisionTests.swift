import XCTest
@testable import Msngr

/// The "show a notification or not" matrix: the WS path (in-app banner) and the
/// willPresent path (the system APNs push that arrives for every message).
final class NotificationDecisionTests: XCTestCase {

    private func ws(appActive: Bool = true, chatOpen: Bool = false, isOwn: Bool = false,
                    isService: Bool = false, muted: Bool = false,
                    alreadyShown: Bool = false,
                    apnsAvailable: Bool = true) -> NotificationDecision.WSAction {
        NotificationDecision.forIncomingWS(appActive: appActive, chatOpen: chatOpen,
                                           isOwn: isOwn, isService: isService,
                                           muted: muted, alreadyShown: alreadyShown,
                                           apnsAvailable: apnsAvailable)
    }

    // MARK: - Message over WS

    func testActiveOtherChatShowsInAppBanner() {
        XCTAssertEqual(ws(appActive: true, chatOpen: false), .inAppBanner)
    }

    func testActiveOpenChatShowsNothing() {
        XCTAssertEqual(ws(appActive: true, chatOpen: true), .none)
    }

    func testBackgroundShowsNothing() {
        // in the background the system APNs push gives the banner; a local one would duplicate it
        XCTAssertEqual(ws(appActive: false, chatOpen: false), .none)
    }

    func testBackgroundWithoutApnsPostsLocalNotification() {
        // simulator, or a device with no token: no push will come, the app posts the banner
        XCTAssertEqual(ws(appActive: false, apnsAvailable: false), .localNotification)
    }

    func testBackgroundWithoutApnsStillRespectsMuteAndOwnEcho() {
        XCTAssertEqual(ws(appActive: false, isOwn: true, apnsAvailable: false), .none)
        XCTAssertEqual(ws(appActive: false, isService: true, apnsAvailable: false), .none)
        XCTAssertEqual(ws(appActive: false, muted: true, apnsAvailable: false), .none)
        XCTAssertEqual(ws(appActive: false, alreadyShown: true, apnsAvailable: false), .none)
    }

    func testBackgroundWithOpenChatStillNotifies() {
        // the app is in the background, so a chat left open on screen is no reason to stay silent
        XCTAssertEqual(ws(appActive: false, chatOpen: true, apnsAvailable: false), .localNotification)
    }

    func testAlreadyShownMsgIdShowsNothing() {
        // the system push got shown before the WS frame arrived
        XCTAssertEqual(ws(alreadyShown: true), .none)
    }

    func testOwnEchoShowsNothing() {
        XCTAssertEqual(ws(isOwn: true), .none)
    }

    func testServiceFrameShowsNothing() {
        XCTAssertEqual(ws(isService: true), .none)
    }

    func testMutedChatShowsNothing() {
        XCTAssertEqual(ws(muted: true), .none)
    }

    // MARK: - System push in an active app (willPresent)

    private func present(isLocal: Bool = false,
                         chatOpen: Bool = false, alreadyShown: Bool = false,
                         messageInDB: Bool = false, messageRead: Bool = false,
                         muted: Bool = false) -> Bool {
        NotificationDecision.shouldPresentSystemPush(isLocal: isLocal,
                                                     chatOpen: chatOpen,
                                                     alreadyShown: alreadyShown,
                                                     messageInDB: messageInDB,
                                                     messageRead: messageRead,
                                                     muted: muted)
    }

    func testOwnLocalNotificationAlwaysPresents() {
        // the app posted this banner itself from a WS frame: the message is already in
        // the DB and its key is already in alreadyShown, so the common dedupe would
        // swallow the app's own notification
        XCTAssertTrue(present(isLocal: true, alreadyShown: true, messageInDB: true))
    }

    func testPushForUnknownMessagePresents() {
        // WS is behind or dead: the push is the only channel, so show it
        XCTAssertTrue(present())
    }

    func testPushForOpenChatSuppressed() {
        XCTAssertFalse(present(chatOpen: true))
    }

    func testPushAfterInAppBannerSuppressed() {
        // the in-app banner was already shown from WS, so the system duplicate is suppressed
        XCTAssertFalse(present(alreadyShown: true, messageInDB: true))
    }

    func testPushForMessageAlreadyReceivedViaWSSuppressed() {
        // the recv ack did not stop the push (the server always sends one): the message
        // is already in the DB and the WS path already decided about its banner
        XCTAssertFalse(present(messageInDB: true))
    }

    func testPushForReadMessageSuppressed() {
        XCTAssertFalse(present(messageInDB: true, messageRead: true))
    }

    func testPushForMutedChatSuppressed() {
        XCTAssertFalse(present(muted: true))
    }
}
