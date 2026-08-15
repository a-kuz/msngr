import Foundation
import GRDB

/// The message a push carries, as it arrived.
///
/// The payload holds the E2E envelope addressed to this device, so a device
/// that has been offline for a day still gets the text of the banner it shows,
/// and keeps it: a notification is a write to the database, not a picture of
/// one.
public struct PushEnvelope: Sendable {
    public var body: JSONValue
    public var fromUserId: String
    public var fromDeviceId: String
    /// Server clock of the message; the feed orders by it.
    public var ts: Double

    public init(body: JSONValue, fromUserId: String, fromDeviceId: String, ts: Double) {
        self.body = body
        self.fromUserId = fromUserId
        self.fromDeviceId = fromDeviceId
        self.ts = ts
    }

    /// Reads what the extension needs out of an APNs payload. A push without an
    /// envelope — a media message too big for the four kilobytes, an older
    /// sender — parses to nil, and the message arrives on the next connection.
    public static func fromPush(_ userInfo: [AnyHashable: Any]) -> PushEnvelope? {
        guard let raw = userInfo["env"] as? String,
              let from = userInfo["from"] as? String,
              let fromDevice = userInfo["fromDevice"] as? String,
              let body = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8))
        else { return nil }
        let ts = (userInfo["ts"] as? Double) ?? (userInfo["sentAt"] as? Double) ?? 0
        return PushEnvelope(body: body, fromUserId: from, fromDeviceId: fromDevice, ts: ts)
    }
}

/// What became of one envelope that arrived by push.
public enum PushStoreOutcome: String, Sendable {
    /// The message is in the feed.
    case stored
    /// It was there already — the socket brought it first.
    case duplicate
    /// The chat is unknown to this device: a message has nowhere to go until
    /// the app fetches the chat itself.
    case unknownChat
    /// The envelope did not open and is kept for the app to replay.
    case deferred
    /// The envelope carried something the extension does not apply; the ratchet
    /// step is rolled back with it, so the app opens the same envelope again.
    case skipped
}

/// Writes the message a push carried into the feed.
///
/// It runs inside the burst's transaction, and the gate is already held by the
/// caller: the ratchet must not be stepped by two processes at once (see
/// `CryptoGate`), and the step must commit together with the row it produced.
public struct PushMessageWriter: Sendable {
    let decryptor: IncomingDecryptor
    let ticket: CryptoGate.Ticket
    let ownUserId: String
    let store: IdentityStore

    public init(decryptor: IncomingDecryptor, store: IdentityStore, ownUserId: String,
                holding ticket: CryptoGate.Ticket) {
        self.decryptor = decryptor
        self.store = store
        self.ownUserId = ownUserId
        self.ticket = ticket
    }

    /// Kinds the extension has no way to act on: they belong to the repair
    /// protocol, which needs the socket. They never travel by push — the server
    /// sends none for a service frame — and an envelope that turns out to hold
    /// one is left to the app, ratchet step and all.
    static let outOfReach: Set<String> = SyncEngine.repairKinds

    public func write(_ dbc: GRDB.Database, item: BurstItem, envelope: PushEnvelope,
                      now: Double = Date().timeIntervalSince1970) -> PushStoreOutcome {
        guard let chat = try? Chat.fetchOne(dbc, key: item.chatId) else { return .unknownChat }
        let known = (try? Bool.fetchOne(dbc, sql: "SELECT EXISTS(SELECT 1 FROM message WHERE msgId = ?)",
                                        arguments: [item.msgId])) ?? false
        if known { return .duplicate }

        // A savepoint per envelope: the ratchet step inside it is undone with
        // the rest of the item when the content turns out not to be ours to
        // apply, and the other pushes of the burst keep their work.
        var outcome = PushStoreOutcome.skipped
        let done = try? dbc.inSavepoint {
            let result = store.joining(dbc) {
                (try? decryptor.decrypt(envelopeJSON: envelope.body, chatId: item.chatId,
                                        fromUserId: envelope.fromUserId,
                                        fromDeviceId: envelope.fromDeviceId, holding: ticket))
                    ?? .undecryptable(reason: "exception")
            }
            switch result {
            case .content(let payload):
                guard !Self.outOfReach.contains(payload.kind) else { return .rollback }
                try apply(dbc, payload, item: item, envelope: envelope, chat: chat)
                outcome = .stored
                return .commit
            case .undecryptable(let reason):
                // The step that failed changed nothing, so only the envelope is
                // kept: the app replays it once the key it waits for arrives.
                guard let data = try? JSONEncoder().encode(envelope.body) else { return .rollback }
                try SyncEngine.deferEnvelope(dbc, reason: reason, chatId: item.chatId,
                                             msgId: item.msgId, seq: item.seq,
                                             from: envelope.fromUserId,
                                             fromDevice: envelope.fromDeviceId,
                                             sentAt: item.sentAt, ts: envelope.ts,
                                             body: data, now: now)
                outcome = .deferred
                return .commit
            case .senderKeyDistribution, .identityChanged:
                // A peer whose identity key changed is the app's business: it
                // is the one that says so in the chat. The step is rolled back
                // with everything else, so the same envelope reaches it whole.
                return .rollback
            }
        }
        return done == nil ? .skipped : outcome
    }

    /// Moves `syncedSeq` up the run of seqs the chat actually holds.
    ///
    /// The cursor only ever stands on a contiguous prefix, and one message at a
    /// time can only extend it by one. A burst arrives in whatever order APNs
    /// felt like, so the message that closes a hole is often written before the
    /// ones under it, and the prefix is worth a look once the burst is in.
    static func extendSyncedPrefix(_ dbc: GRDB.Database, chatId: String) throws {
        guard let row = try Row.fetchOne(dbc, sql: "SELECT syncedSeq, lastSeq FROM chat WHERE id = ?",
                                         arguments: [chatId]) else { return }
        var synced: Int = row["syncedSeq"]
        let lastSeq: Int = row["lastSeq"]
        while synced < lastSeq,
              try Bool.fetchOne(dbc, sql: """
                  SELECT EXISTS(SELECT 1 FROM message WHERE chatId = ? AND seq = ?)
                  """, arguments: [chatId, synced + 1]) == true {
            synced += 1
        }
        guard synced != row["syncedSeq"] as Int else { return }
        try dbc.execute(sql: "UPDATE chat SET syncedSeq = ? WHERE id = ?", arguments: [synced, chatId])
    }

    private func apply(_ dbc: GRDB.Database, _ payload: ContentPayload, item: BurstItem,
                       envelope: PushEnvelope, chat: Chat) throws {
        try SyncEngine.applyContent(dbc, payload, chatId: item.chatId, msgId: item.msgId,
                                    seq: item.seq, from: envelope.fromUserId,
                                    sentAt: item.sentAt, ts: envelope.ts, ownUserId: ownUserId)
        // The cursors move exactly as they do for a message off the socket:
        // syncedSeq only along a contiguous prefix, unread derived from lastSeq.
        try SyncEngine.advanceChat(dbc, chatId: item.chatId, seq: item.seq,
                                   isOwn: envelope.fromUserId == ownUserId,
                                   isService: SyncEngine.serviceKinds.contains(payload.kind))
        // the seq is filled now: neither the envelope nor the hole it left is
        // waiting for anything
        try dbc.execute(sql: "DELETE FROM pendingDecrypt WHERE chatId = ? AND msgId = ?",
                        arguments: [item.chatId, item.msgId])
        try dbc.execute(sql: "DELETE FROM historyGap WHERE chatId = ? AND seq = ?",
                        arguments: [item.chatId, item.seq])
    }
}
