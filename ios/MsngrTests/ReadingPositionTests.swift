import XCTest
import GRDB
import MsngrCore
@testable import Msngr

/// The reading position kept between openings of a chat: one kv row per chat,
/// written on leaving and cleared when the reader left from the bottom.
final class ReadingPositionTests: XCTestCase {

    func testPositionRoundTrips() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { try ChatViewModel.storeReadingPosition($0, chatId: "c1", seq: 118) }
        let read = try db.read { try ChatViewModel.readingPosition($0, chatId: "c1") }
        XCTAssertEqual(read, 118)
    }

    func testLeavingFromTheBottomClearsThePosition() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { try ChatViewModel.storeReadingPosition($0, chatId: "c1", seq: 118) }
        try db.write { try ChatViewModel.storeReadingPosition($0, chatId: "c1", seq: nil) }
        let read = try db.read { try ChatViewModel.readingPosition($0, chatId: "c1") }
        XCTAssertNil(read)
    }

    func testPositionsAreKeptPerChat() throws {
        let db = try AppDatabase.openInMemory()
        try db.write { try ChatViewModel.storeReadingPosition($0, chatId: "c1", seq: 7) }
        try db.write { try ChatViewModel.storeReadingPosition($0, chatId: "c2", seq: 9) }
        XCTAssertEqual(try db.read { try ChatViewModel.readingPosition($0, chatId: "c1") }, 7)
        XCTAssertEqual(try db.read { try ChatViewModel.readingPosition($0, chatId: "c2") }, 9)
    }

    func testNothingStoredMeansNoPosition() throws {
        let db = try AppDatabase.openInMemory()
        XCTAssertNil(try db.read { try ChatViewModel.readingPosition($0, chatId: "c1") })
    }
}
