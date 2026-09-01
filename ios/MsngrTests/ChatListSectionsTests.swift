import XCTest
@testable import Msngr

/// The list's sections. A section that is in the snapshot draws its header, so
/// the requests header stands only while there is a request to answer.
final class ChatListSectionsTests: XCTestCase {
    func testNoRequestsMeansNoRequestsSection() {
        let snapshot = ChatListCollection.snapshot(requestIds: [],
                                                   archived: false,
                                                   chatIds: ["a", "b"])
        XCTAssertEqual(snapshot.sectionIdentifiers, [.chats])
    }

    func testARequestBringsItsSection() {
        let snapshot = ChatListCollection.snapshot(requestIds: ["r"],
                                                   archived: false,
                                                   chatIds: ["a"])
        XCTAssertEqual(snapshot.sectionIdentifiers, [.requests, .chats])
        XCTAssertEqual(snapshot.itemIdentifiers(inSection: .requests), [.request("r")])
    }

    func testTheArchiveRowStandsInItsOwnSectionOnlyWhenThereIsOne() {
        XCTAssertEqual(ChatListCollection.snapshot(requestIds: [],
                                                   archived: true,
                                                   chatIds: ["a"]).sectionIdentifiers,
                       [.archive, .chats])
        XCTAssertEqual(ChatListCollection.snapshot(requestIds: [],
                                                   archived: false,
                                                   chatIds: ["a"]).sectionIdentifiers,
                       [.chats])
    }
}
