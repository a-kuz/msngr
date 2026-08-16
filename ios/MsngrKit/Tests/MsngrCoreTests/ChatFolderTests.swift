import XCTest
import GRDB
@testable import MsngrCore

/// What a folder holds, and what deleting one costs. Membership is a rule set
/// plus the chats the user placed by hand, so the tests pin down which of the
/// two wins, and that a chat is free to sit in several folders at once.
final class ChatFolderTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue { try AppDatabase.openInMemory() }

    private func candidate(_ id: String, group: Bool = false, unread: Bool = false,
                           peer: String? = nil) -> ChatFolderCandidate {
        ChatFolderCandidate(chatId: id, isGroup: group, hasUnread: unread, peerId: peer)
    }

    // MARK: - Rules

    func testRuleMatchesByKind() {
        let people = ChatFolderRules(direct: true)
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c1", peer: "u1"), rules: people, pin: nil))
        XCTAssertFalse(ChatFolderMembership.matches(candidate("c2", group: true), rules: people, pin: nil))

        let groups = ChatFolderRules(groups: true)
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c2", group: true), rules: groups, pin: nil))
    }

    func testUnreadRuleFollowsTheCount() {
        let rules = ChatFolderRules(unread: true)
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c1", unread: true), rules: rules, pin: nil))
        XCTAssertFalse(ChatFolderMembership.matches(candidate("c1"), rules: rules, pin: nil))
    }

    func testPeerRuleMatchesTheChatWithThatContact() {
        let rules = ChatFolderRules(peerIds: ["u7"])
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c1", peer: "u7"), rules: rules, pin: nil))
        XCTAssertFalse(ChatFolderMembership.matches(candidate("c2", peer: "u8"), rules: rules, pin: nil))
    }

    func testHandPickedRowsOverrideTheRules() {
        let rules = ChatFolderRules(direct: true)
        // a matching chat taken out stays out
        XCTAssertFalse(ChatFolderMembership.matches(candidate("c1", peer: "u1"),
                                                    rules: rules, pin: .excluded))
        // a chat no rule describes still shows once it is added
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c2", group: true),
                                                   rules: rules, pin: .included))
    }

    func testFolderWithoutRulesHoldsOnlyWhatWasAdded() {
        let rules = ChatFolderRules()
        XCTAssertTrue(rules.isEmpty)
        XCTAssertFalse(ChatFolderMembership.matches(candidate("c1", peer: "u1"), rules: rules, pin: nil))
        XCTAssertTrue(ChatFolderMembership.matches(candidate("c1", peer: "u1"), rules: rules, pin: .included))
    }

    // MARK: - Storage

    func testCreateReadAndOrder() throws {
        let db = try makeDB()
        try db.write { dbc in
            try ChatFolderStore.create(dbc, title: "Work", rules: ChatFolderRules(groups: true))
            try ChatFolderStore.create(dbc, title: "Personal", rules: ChatFolderRules(direct: true, peerIds: ["u1", "u2"]))
        }
        let folders = try db.read { try ChatFolderStore.all($0) }
        XCTAssertEqual(folders.map(\.title), ["Work", "Personal"])
        XCTAssertEqual(folders[0].rules, ChatFolderRules(groups: true))
        XCTAssertEqual(folders[1].rules.peerIds, ["u1", "u2"])

        try db.write { dbc in
            try ChatFolderStore.reorder(dbc, orderedIds: [folders[1].id, folders[0].id])
        }
        XCTAssertEqual(try db.read { try ChatFolderStore.all($0) }.map(\.title), ["Personal", "Work"])
    }

    func testRenameAndRulesRewritePeerSet() throws {
        let db = try makeDB()
        let folder = try db.write { dbc in
            try ChatFolderStore.create(dbc, title: "Draft", rules: ChatFolderRules(peerIds: ["u1"]))
        }
        try db.write { dbc in
            try ChatFolderStore.rename(dbc, folderId: folder.id, title: "Family")
            try ChatFolderStore.setRules(dbc, folderId: folder.id,
                                         rules: ChatFolderRules(unread: true, peerIds: ["u2", "u3"]))
        }
        let stored = try db.read { try ChatFolderStore.all($0) }[0]
        XCTAssertEqual(stored.title, "Family")
        XCTAssertTrue(stored.rules.unread)
        XCTAssertEqual(stored.rules.peerIds, ["u2", "u3"])
    }

    func testChatSitsInSeveralFoldersAndSurvivesDeletingOne() throws {
        let db = try makeDB()
        var chat = Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
        chat.unreadCount = 0
        try db.write { dbc in try chat.save(dbc) }

        let (work, family) = try db.write { dbc in
            (try ChatFolderStore.create(dbc, title: "Work"),
             try ChatFolderStore.create(dbc, title: "Family"))
        }
        try db.write { dbc in
            try ChatFolderStore.setPin(dbc, folderId: work.id, chatId: "c1", pin: .included)
            try ChatFolderStore.setPin(dbc, folderId: family.id, chatId: "c1", pin: .included)
        }
        XCTAssertEqual(try db.read { try ChatFolderStore.pins($0) }.count, 2)

        try db.write { dbc in try ChatFolderStore.delete(dbc, folderId: work.id) }

        let pins = try db.read { try ChatFolderStore.pins($0) }
        XCTAssertNil(pins[work.id])
        XCTAssertEqual(pins[family.id]?["c1"], .included)
        XCTAssertNotNil(try db.read { try Chat.fetchOne($0, key: "c1") })
    }

    func testUnpinHandsTheChatBackToTheRules() throws {
        let db = try makeDB()
        let folder = try db.write { dbc in try ChatFolderStore.create(dbc, title: "People") }
        try db.write { dbc in
            try ChatFolderStore.setPin(dbc, folderId: folder.id, chatId: "c1", pin: .excluded)
            try ChatFolderStore.setPin(dbc, folderId: folder.id, chatId: "c1", pin: nil)
        }
        XCTAssertTrue(try db.read { try ChatFolderStore.pins($0) }.isEmpty)
    }

    func testDeletingAChatDropsItsPlacements() throws {
        let db = try makeDB()
        var chat = Chat(id: "c1", kind: .direct, title: nil, createdBy: "peer", createdAt: 0,
                        lastSeq: 0, syncedSeq: 0, lastActivityAt: 0)
        chat.unreadCount = 0
        let folder = try db.write { dbc -> ChatFolder in
            try chat.save(dbc)
            let folder = try ChatFolderStore.create(dbc, title: "Work")
            try ChatFolderStore.setPin(dbc, folderId: folder.id, chatId: "c1", pin: .included)
            return folder
        }
        try db.write { dbc in try ChatCleanup.deleteChat(dbc, chatId: "c1") }
        XCTAssertNil(try db.read { try ChatFolderStore.pins($0) }[folder.id])
        XCTAssertEqual(try db.read { try ChatFolderStore.all($0) }.count, 1)
    }
}
