import Foundation
import GRDB

/// Delivery receipts on their way out.
///
/// A message arrives at the device down the socket or inside a push the
/// notification extension writes, and the author is owed the same answer in
/// both cases. The socket sends a `recv` frame; the extension has no socket, so
/// it posts the receipt over HTTP — and it lives for seconds and can be killed
/// mid-request. The receipt is therefore written down in the same transaction
/// as the message it is about, and whatever is not sent then goes out on the
/// app's next connection.
///
/// The mark is monotone on the server, so one row per chat carrying the largest
/// seq is the whole of it, and sending it twice changes nothing.
public enum DeliveryReceipts {
    static let actionType = "recv"

    struct Payload: Codable { var upToSeq: Int }

    static func actionId(chatId: String) -> String { "\(actionType):\(chatId)" }

    /// Queues the receipt for one chat, keeping the larger seq of the two.
    public static func record(_ dbc: GRDB.Database, chatId: String, upToSeq: Int,
                              now: Double = Date().timeIntervalSince1970) throws {
        guard upToSeq > 0 else { return }
        let id = actionId(chatId: chatId)
        let prev = try Row.fetchOne(dbc, sql: "SELECT payload FROM pendingAction WHERE id = ?",
                                    arguments: [id])
            .flatMap { row -> Payload? in
                try? JSONDecoder().decode(Payload.self, from: Data((row["payload"] as String).utf8))
            }?.upToSeq ?? 0
        guard let payload = String(data: try JSONEncoder().encode(Payload(upToSeq: max(prev, upToSeq))),
                                   encoding: .utf8) else { return }
        try dbc.execute(
            sql: """
            INSERT INTO pendingAction (id, type, chatId, payload, createdAt) VALUES (?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, attempts = 0
            """,
            arguments: [id, actionType, chatId, payload, now])
    }

    /// What is queued right now, oldest first.
    public static func pending(_ dbc: GRDB.Database) throws -> [(chatId: String, upToSeq: Int)] {
        try Row.fetchAll(dbc, sql: """
            SELECT chatId, payload FROM pendingAction WHERE type = ? ORDER BY createdAt
            """, arguments: [actionType]).compactMap { row in
            guard let chatId = row["chatId"] as String?,
                  let payload = try? JSONDecoder().decode(
                    Payload.self, from: Data((row["payload"] as String).utf8))
            else { return nil }
            return (chatId, payload.upToSeq)
        }
    }

    /// Drops a receipt the server has taken. A larger seq written while the
    /// request was in flight leaves the row where it is, so the newer mark is
    /// still sent.
    static func clear(_ dbc: GRDB.Database, chatId: String, upToSeq: Int) throws {
        guard let payload = String(data: try JSONEncoder().encode(Payload(upToSeq: upToSeq)),
                                   encoding: .utf8) else { return }
        try dbc.execute(sql: "DELETE FROM pendingAction WHERE id = ? AND payload = ?",
                        arguments: [actionId(chatId: chatId), payload])
    }

    /// Sends everything queued over HTTP. Used by the notification extension:
    /// the app has a socket and drains the same rows through its action queue.
    /// A failure leaves the row alone — the next push, or the app, sends it.
    public static func flush(db: DatabaseQueue, api: APIClient) async {
        let queued = (try? await db.read { dbc in try pending(dbc) }) ?? []
        for item in queued {
            do {
                try await api.markDelivered(item.chatId, seqs: [item.upToSeq])
            } catch {
                return
            }
            try? await db.write { dbc in
                try clear(dbc, chatId: item.chatId, upToSeq: item.upToSeq)
            }
        }
    }
}
