import XCTest
import GRDB
import MsngrCore
@testable import Msngr

/// The order of the calls list. A peer stamps `sentAt` itself, so a wrong clock
/// on the other side would otherwise stand at the top of the list for good and
/// push real calls out of the window the list is cut to — while the row beside
/// it shows the server's time, which is the one that is right.
final class CallsListOrderTests: XCTestCase {
    private func call(_ db: DatabaseQueue, id: String, sentAt: Double, serverTs: Double?) throws {
        try db.write { dbc in
            var msg = Message(id: id, chatId: "c1", fromUserId: "peer", sentAt: sentAt,
                              kind: .call, text: nil, status: .sent, isOutgoing: false)
            msg.serverTs = serverTs
            try msg.save(dbc)
        }
    }

    func testTheServersClockOrdersTheList() throws {
        let db = try AppDatabase.openInMemory()
        // the peer's clock says the far future; the server journalled it first
        try call(db, id: "wrongClock", sentAt: 4_000_000_000, serverTs: 1_000)
        try call(db, id: "recent", sentAt: 2_000, serverTs: 2_000)

        let order = try db.read { try CallsListView.calls($0).map(\.id) }
        XCTAssertEqual(order, ["recent", "wrongClock"])
    }

    /// A call that has not been journalled yet is ours and unsent, so its own
    /// clock is this device's: it keeps its place by `sentAt`.
    func testAnUnsentCallKeepsItsOwnClock() throws {
        let db = try AppDatabase.openInMemory()
        try call(db, id: "journalled", sentAt: 1_000, serverTs: 1_000)
        try call(db, id: "unsent", sentAt: 3_000, serverTs: nil)

        let order = try db.read { try CallsListView.calls($0).map(\.id) }
        XCTAssertEqual(order, ["unsent", "journalled"])
    }
}
