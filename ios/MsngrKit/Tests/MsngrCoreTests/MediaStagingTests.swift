import XCTest
import GRDB
@testable import MsngrCore

/// A photo or a video is not ready the instant it is picked: it still has to be
/// compressed, and a video transcoded, which can take seconds. The row appears
/// at once (`beginMedia`), fills in as preparation progresses
/// (`updateMediaPreview`/`updateAlbumItemPreview`), and only becomes eligible
/// for upload once the file is on disk (`finalizeMedia`) — the send worker must
/// never see a `MediaInfo` with no `localPath` yet.
final class MediaStagingTests: XCTestCase {
    private func makeEngine(db: DatabaseQueue) throws -> SyncEngine {
        let api = APIClient(baseURL: URL(string: "http://localhost:1")!)
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        let e2ee = E2EEManager(store: store, api: api, ownUserId: "me", ownDeviceId: "dev")
        return SyncEngine(db: db, api: api, e2ee: e2ee,
                          wsURL: URL(string: "ws://localhost:1/ws")!,
                          ownUserId: "me", ownDeviceId: "dev")
    }

    private func makeChat(_ db: DatabaseQueue) async throws {
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
        }
    }

    private func blankMedia(localPath: String? = nil) -> MediaInfo {
        var m = MediaInfo(type: "photo", mediaId: "", key: "", hash: "", size: 0, mime: "image/jpeg")
        m.localPath = localPath
        return m
    }

    func testBeginMediaShowsTheRowWithoutQueuingIt() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db)

        try await engine.beginMedia(clientMsgId: "cm1", chatId: "c1", kind: .photo, text: nil,
                                    media: blankMedia(), album: nil)

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.status, .sending)
        XCTAssertEqual(msg?.kind, .photo)
        let queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(queued, 0, "not sendable yet: the attachment is not on disk")
    }

    func testUpdateMediaPreviewRefinesTheSameRowWithoutQueuingIt() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db)
        try await engine.beginMedia(clientMsgId: "cm1", chatId: "c1", kind: .photo, text: nil,
                                    media: blankMedia(), album: nil)

        var withBlurhash = blankMedia()
        withBlurhash.blurhash = "L6PZfSi_.AyE_3t7t7R**0o#DgR4"
        withBlurhash.w = 32
        withBlurhash.h = 24
        try await engine.updateMediaPreview(clientMsgId: "cm1", media: withBlurhash, album: nil)

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.media?.blurhash, withBlurhash.blurhash)
        let queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(queued, 0, "a preview refinement is still not a finished attachment")
    }

    func testFinalizeMediaQueuesOnlyOnceTheFileIsOnDisk() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db)
        try await engine.beginMedia(clientMsgId: "cm1", chatId: "c1", kind: .photo, text: nil,
                                    media: blankMedia(), album: nil)

        var content = ContentPayload(kind: "photo")
        content.media = blankMedia(localPath: "stashed.jpg")
        try await engine.finalizeMedia(chatId: "c1", clientMsgId: "cm1", content: content)

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.media?.localPath, "stashed.jpg")
        let outbox = try await db.read { dbc in
            try OutboxItem.fetchOne(dbc, sql: "SELECT * FROM outbox WHERE clientMsgId = 'cm1'")
        }
        XCTAssertNotNil(outbox, "the file is on disk now, the worker may pick it up")
        XCTAssertEqual(outbox?.state, "ready")
    }

    /// Album tiles prepare concurrently; each must land in its own slot without
    /// clobbering a sibling that finished first.
    func testUpdateAlbumItemPreviewWritesOnlyItsOwnSlot() async throws {
        let db = try AppDatabase.openInMemory()
        let engine = try makeEngine(db: db)
        try await makeChat(db)
        try await engine.beginMedia(clientMsgId: "cm1", chatId: "c1", kind: .album, text: nil,
                                    media: nil, album: [blankMedia(), blankMedia(), blankMedia()])

        var second = blankMedia()
        second.blurhash = "second"
        try await engine.updateAlbumItemPreview(clientMsgId: "cm1", index: 1, media: second)
        var first = blankMedia()
        first.blurhash = "first"
        try await engine.updateAlbumItemPreview(clientMsgId: "cm1", index: 0, media: first)

        let msg = try await db.read { dbc in
            try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(msg?.album?.count, 3)
        XCTAssertEqual(msg?.album?[0].blurhash, "first")
        XCTAssertEqual(msg?.album?[1].blurhash, "second")
        XCTAssertNil(msg?.album?[2].blurhash)
        let queued = try await db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox WHERE clientMsgId = 'cm1'")
        }
        XCTAssertEqual(queued, 0)
    }
}
