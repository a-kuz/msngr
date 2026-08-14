import XCTest
@testable import Msngr

/// Матрица правил плашки «N непрочитанных сообщений».
final class UnreadMarkerStateTests: XCTestCase {

    // Правило 1: вход с непрочитанными — плашка над первым непрочитанным
    func testEnterChatWithUnread() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.anchorSeq, 11)
        XCTAssertEqual(s.count, 5)
    }

    func testEnterChatWithoutUnread() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.anchorSeq)
    }

    // Правило 2: входящие при видимом чате увеличивают счётчик активной плашки
    func testIncomingIncrementsActiveMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.incoming(seq: 16)
        XCTAssertEqual(s.count, 6)
        XCTAssertEqual(s.anchorSeq, 11, "якорь не двигается при росте счётчика")
    }

    // без активной плашки входящее при видимом чате плашку не создаёт
    func testIncomingWithoutMarkerDoesNothing() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        s.incoming(seq: 11)
        XCTAssertFalse(s.isActive)
    }

    // Правило 3: своя отправка / реакция убирает плашку
    func testDismissClearsMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.dismiss()
        XCTAssertFalse(s.isActive)
        XCTAssertNil(s.anchorSeq)
        XCTAssertEqual(s.count, 0)
    }

    // после dismiss входящие не оживляют плашку (пока экран видим)
    func testIncomingAfterDismissDoesNothing() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.dismiss()
        s.incoming(seq: 16)
        XCTAssertFalse(s.isActive)
    }

    // Правило 4: уход в фон/шторку убирает плашку
    func testObscuredDismissesMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.becameObscured()
        XCTAssertFalse(s.isActive)
    }

    // Правило 5: пришедшее за время отсутствия — новая плашка при возврате
    func testMessagesWhileObscuredShowMarkerOnReturn() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 0, myReadUpTo: 10)
        s.becameObscured()
        s.incoming(seq: 11)
        s.incoming(seq: 12)
        s.incoming(seq: 13)
        XCTAssertFalse(s.isActive, "пока экран не виден, плашки нет")
        s.becameActive()
        XCTAssertTrue(s.isActive)
        XCTAssertEqual(s.anchorSeq, 11, "якорь — первое пришедшее за отсутствие")
        XCTAssertEqual(s.count, 3)
    }

    func testReturnWithoutNewMessagesShowsNoMarker() {
        var s = UnreadMarkerState()
        s.enterChat(unreadCount: 5, myReadUpTo: 10)
        s.becameObscured()
        s.becameActive()
        XCTAssertFalse(s.isActive, "старая плашка после фона не возвращается")
    }

    // повторный цикл фон→возврат не тащит старое накопленное
    func testObscuredCycleResetsPending() {
        var s = UnreadMarkerState()
        s.becameObscured()
        s.incoming(seq: 11)
        s.becameActive()
        XCTAssertEqual(s.count, 1)
        s.becameObscured()
        s.becameActive()
        XCTAssertFalse(s.isActive)
    }

    // после возврата с новой плашкой входящие продолжают увеличивать счётчик
    func testIncomingAfterReturnIncrements() {
        var s = UnreadMarkerState()
        s.becameObscured()
        s.incoming(seq: 11)
        s.becameActive()
        s.incoming(seq: 12)
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s.anchorSeq, 11)
    }

    // склонение текста плашки
    func testMarkerTitlePluralization() {
        XCTAssertEqual(UnreadMarkerCell.title(count: 1), "1 непрочитанное сообщение")
        XCTAssertEqual(UnreadMarkerCell.title(count: 2), "2 непрочитанных сообщения")
        XCTAssertEqual(UnreadMarkerCell.title(count: 5), "5 непрочитанных сообщений")
        XCTAssertEqual(UnreadMarkerCell.title(count: 11), "11 непрочитанных сообщений")
        XCTAssertEqual(UnreadMarkerCell.title(count: 21), "21 непрочитанное сообщение")
        XCTAssertEqual(UnreadMarkerCell.title(count: 104), "104 непрочитанных сообщения")
    }
}
