import XCTest
import GRDB
@testable import MsngrCore

/// The contact and location kinds: the payload carries the card or the point,
/// the message row stores it, the previews name it.
final class ContactLocationTests: XCTestCase {
    func testPayloadCarriesTheCardAndThePoint() throws {
        var contact = ContentPayload(kind: "contact")
        contact.contact = ContactCard(name: "Ada Lovelace", phones: ["+1 555 0100"],
                                      emails: ["ada@example.org"])
        var location = ContentPayload(kind: "location")
        location.location = LocationInfo(lat: 59.9387, lon: 30.3162, name: "Летний сад")

        let backC = try JSONDecoder().decode(ContentPayload.self,
                                             from: JSONEncoder().encode(contact))
        XCTAssertEqual(backC.contact, contact.contact)
        let backL = try JSONDecoder().decode(ContentPayload.self,
                                             from: JSONEncoder().encode(location))
        XCTAssertEqual(backL.location, location.location)
    }

    func testMessageRowStoresBothColumns() async throws {
        let db = try AppDatabase.openInMemory()
        try await db.write { dbc in
            try dbc.execute(sql: "INSERT INTO chat (id, kind, createdBy, createdAt) VALUES ('c1','direct','me',0)")
            var m = Message(id: "m1", chatId: "c1", fromUserId: "me", sentAt: 1,
                            kind: .contact, text: nil, status: .sent, isOutgoing: true)
            m.contact = ContactCard(name: "Ada", phones: ["+1 555 0100"])
            try m.save(dbc)
            var l = Message(id: "m2", chatId: "c1", fromUserId: "me", sentAt: 2,
                            kind: .location, text: nil, status: .sent, isOutgoing: true)
            l.location = LocationInfo(lat: 1.5, lon: -2.25, name: nil)
            try l.save(dbc)
        }
        let (card, point) = try await db.read { dbc in
            (try Message.fetchOne(dbc, key: "m1")?.contact,
             try Message.fetchOne(dbc, key: "m2")?.location)
        }
        XCTAssertEqual(card, ContactCard(name: "Ada", phones: ["+1 555 0100"]))
        XCTAssertEqual(point, LocationInfo(lat: 1.5, lon: -2.25, name: nil))
    }

    func testPreviewsNameTheContent() {
        var contact = ContentPayload(kind: "contact")
        contact.contact = ContactCard(name: "Ada", phones: [])
        XCTAssertTrue(NotificationContentBuilder.preview(contact).contains("Ada"))
        var location = ContentPayload(kind: "location")
        location.location = LocationInfo(lat: 0, lon: 0, name: "Café")
        XCTAssertTrue(NotificationContentBuilder.preview(location).contains("Café"))
        location.location?.name = nil
        XCTAssertFalse(NotificationContentBuilder.preview(location).isEmpty)
    }
}
