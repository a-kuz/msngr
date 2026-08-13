import XCTest
@testable import Msngr

/// Матрица «показывать ли уведомление»: WS-путь (in-app баннер) и
/// willPresent-путь (системный APNs-пуш, приходящий на каждое сообщение).
final class NotificationDecisionTests: XCTestCase {

    private func ws(appActive: Bool = true, chatOpen: Bool = false, isOwn: Bool = false,
                    isService: Bool = false, muted: Bool = false,
                    alreadyShown: Bool = false) -> NotificationDecision.WSAction {
        NotificationDecision.forIncomingWS(appActive: appActive, chatOpen: chatOpen,
                                           isOwn: isOwn, isService: isService,
                                           muted: muted, alreadyShown: alreadyShown)
    }

    // MARK: - Сообщение по WS

    func testActiveOtherChatShowsInAppBanner() {
        XCTAssertEqual(ws(appActive: true, chatOpen: false), .inAppBanner)
    }

    func testActiveOpenChatShowsNothing() {
        XCTAssertEqual(ws(appActive: true, chatOpen: true), .none)
    }

    func testBackgroundShowsNothing() {
        // в фоне баннер даст системный APNs-пуш; своя локальная нотификация — дубль
        XCTAssertEqual(ws(appActive: false, chatOpen: false), .none)
    }

    func testAlreadyShownMsgIdShowsNothing() {
        // системный пуш успел показаться раньше WS-фрейма
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

    // MARK: - Системный пуш в активном приложении (willPresent)

    private func present(chatOpen: Bool = false, alreadyShown: Bool = false,
                         messageInDB: Bool = false, messageRead: Bool = false,
                         muted: Bool = false) -> Bool {
        NotificationDecision.shouldPresentSystemPush(chatOpen: chatOpen,
                                                     alreadyShown: alreadyShown,
                                                     messageInDB: messageInDB,
                                                     messageRead: messageRead,
                                                     muted: muted)
    }

    func testPushForUnknownMessagePresents() {
        // WS отстал (или мёртв): пуш — единственный канал, показываем
        XCTAssertTrue(present())
    }

    func testPushForOpenChatSuppressed() {
        XCTAssertFalse(present(chatOpen: true))
    }

    func testPushAfterInAppBannerSuppressed() {
        // in-app баннер уже показан по WS — системный дубль гасится
        XCTAssertFalse(present(alreadyShown: true, messageInDB: true))
    }

    func testPushForMessageAlreadyReceivedViaWSSuppressed() {
        // recv-ack не остановил пуш (сервер шлёт всегда): сообщение уже в БД,
        // баннер по нему решался WS-путём — системный не показываем
        XCTAssertFalse(present(messageInDB: true))
    }

    func testPushForReadMessageSuppressed() {
        XCTAssertFalse(present(messageInDB: true, messageRead: true))
    }

    func testPushForMutedChatSuppressed() {
        XCTAssertFalse(present(muted: true))
    }
}
