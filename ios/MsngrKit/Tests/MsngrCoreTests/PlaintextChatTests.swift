import XCTest
import GRDB
@testable import MsngrCore

/// A channel and a chat with a bot journal their content readable. Every other
/// chat is end-to-end encrypted, and a readable envelope arriving in one of
/// those must not be opened: otherwise anyone could put an unencrypted message
/// into an encrypted conversation and have it read as an ordinary one.
final class PlaintextChatTests: XCTestCase {
    private func decryptor() throws -> IncomingDecryptor {
        let db = try AppDatabase.openInMemory()
        let store = try IdentityStore(db: db, masterKeyProvider: StaticMasterKey())
        return IncomingDecryptor(store: store, ownUserId: "me", ownDeviceId: "dev")
    }

    private func envelope() throws -> JSONValue {
        var content = ContentPayload(kind: "text")
        content.text = "in the clear"
        let data = try JSONEncoder().encode(Envelope.plain(content))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func testAReadableEnvelopeOpensInAPlaintextChat() throws {
        let result = try decryptor().decrypt(envelopeJSON: try envelope(), chatId: "c1",
                                             fromUserId: "bot", fromDeviceId: "d1",
                                             plaintext: true)
        guard case .content(let payload) = result else {
            return XCTFail("expected content, got \(result)")
        }
        XCTAssertEqual(payload.text, "in the clear")
    }

    func testAReadableEnvelopeIsRefusedInAnEncryptedChat() throws {
        let result = try decryptor().decrypt(envelopeJSON: try envelope(), chatId: "c1",
                                             fromUserId: "peer", fromDeviceId: "d1")
        guard case .undecryptable(let reason) = result else {
            return XCTFail("expected a refusal, got \(result)")
        }
        XCTAssertEqual(reason, "plaintext_refused")
    }

    /// The chat's flag is what the send path reads, and it comes from the
    /// server's state rather than from the kind alone: a direct chat with a bot
    /// in it is plaintext too.
    func testTheChatCarriesTheFlagFromTheServersState() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try SyncEngine.upsertChatState(dbc, Self.state(chatId: "c1", kind: "direct",
                                                           plaintext: true),
                                           ownUserId: "me", flags: nil)
            try SyncEngine.upsertChatState(dbc, Self.state(chatId: "c2", kind: "direct",
                                                           plaintext: false),
                                           ownUserId: "me", flags: nil)
            try SyncEngine.upsertChatState(dbc, Self.state(chatId: "c3", kind: "channel",
                                                           plaintext: nil),
                                           ownUserId: "me", flags: nil)
        }
        let flags = try await db.read { dbc in
            try Chat.fetchAll(dbc).reduce(into: [String: Bool]()) { $0[$1.id] = $1.plaintext }
        }
        XCTAssertEqual(flags["c1"], true)
        XCTAssertEqual(flags["c2"], false)
        // a state built before the flag existed still knows a channel is readable
        XCTAssertEqual(flags["c3"], true)
    }

    private static func state(chatId: String, kind: String, plaintext: Bool?) -> ChatStateDTO {
        ChatStateDTO(chatId: chatId, kind: kind, title: nil, avatarId: nil, description: nil,
                     sendPolicy: nil, invitePolicy: nil, createdBy: "me", createdAt: 0,
                     plaintext: plaintext,
                     members: [.init(userId: "me", role: "member", joinedAt: 0, accepted: true)],
                     pinnedSeqs: nil, lastSeq: 0, readMarks: [:], deliveredMarks: [:])
    }
}
