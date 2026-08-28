import Foundation
import GRDB
import MsngrCore
import MsngrCrypto

// Three service accounts with a conversation already in them, so a scenario on a
// simulator starts inside the product instead of starting at registration.
//
// A home is exactly what the app keeps in its container — msngr.sqlite,
// .masterkey, session.json — so installing a fixture is a file copy and the app
// opens logged in, with its chats and their history in place.
//
//   swift run msngrfixture seed --base http://localhost:8787 --dir <fixtures>
//   swift run msngrfixture show --dir <fixtures>
//
// The keys of a device belong to one device: a home that has been copied onto a
// simulator moves on from there, and the copy left behind is a ratchet that has
// fallen behind. `scripts/fixture.py` is what hands them out and takes the state
// back; this tool only builds and reads them.

struct FixtureError: Error, CustomStringConvertible {
    let description: String
    init(_ text: String) { description = text }
}

struct Meta: Codable {
    var username: String
    var displayName: String
    var userId: String
    var deviceId: String
    var token: String
}

/// session.json as the app reads it.
struct SessionFile: Codable {
    var userId: String
    var deviceId: String
    var token: String
    var username: String
}

let cast: [(name: String, display: String)] = [
    ("alfa", "Alfa Service"),
    ("bravo", "Bravo Service"),
    ("charlie", "Charlie Service"),
]

let groupTitles = ["Design", "Standup", "Random"]

final class Person {
    let display: String
    let home: URL
    let db: DatabaseQueue
    let store: IdentityStore
    var api: APIClient
    var meta: Meta
    var e2ee: E2EEManager!
    var engine: SyncEngine!

    init(display: String, home: URL, db: DatabaseQueue, store: IdentityStore,
         api: APIClient, meta: Meta) {
        self.display = display
        self.home = home
        self.db = db
        self.store = store
        self.api = api
        self.meta = meta
    }

    var username: String { meta.username }
    var userId: String { meta.userId }
}

func arg(_ name: String, default def: String? = nil) throws -> String {
    let args = Array(CommandLine.arguments.dropFirst())
    if let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count { return args[i + 1] }
    if let def { return def }
    throw FixtureError("--\(name) is required")
}

func flag(_ name: String) -> Bool {
    CommandLine.arguments.contains("--\(name)")
}

func wsURL(base: URL, token: String) -> URL {
    var comps = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false)!
    comps.scheme = base.scheme == "https" ? "wss" : "ws"
    comps.queryItems = [URLQueryItem(name: "token", value: token)]
    return comps.url!
}

/// Opens the home of one account, registering it when the directory holds no
/// session yet. A session that the server no longer knows is registered again
/// under a free handle: the account behind it cannot be reached without its
/// token, so the handle is what has to move.
func openPerson(name: String, display: String, dir: URL, base: URL) async throws -> Person {
    let home = dir.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let location = StorageLocation(root: home)
    let db = try AppDatabase.open(at: location.databaseURL)
    let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: location))
    let api = APIClient(baseURL: base)

    let metaURL = home.appendingPathComponent("meta.json")
    if let data = try? Data(contentsOf: metaURL),
       let kept = try? JSONDecoder().decode(Meta.self, from: data) {
        api.token = kept.token
        if (try? await api.me()) != nil {
            print("· \(kept.username) is already there (\(kept.userId))")
            return Person(display: display, home: home, db: db, store: store, api: api, meta: kept)
        }
        print("· \(kept.username) has a session the stand does not know; registering again")
    }

    let identity = try store.identity()
    let prekeys = try store.generatePrekeys(count: 30)
    var handle = name
    var attempt = 1
    while true {
        do {
            let reg = try await api.register(.init(
                username: handle, displayName: display, deviceName: "fixture",
                identityKey: identity.dh.publicKey.rawRepresentation.base64urlEncodedString(),
                identitySignKey: identity.signing.publicKey.rawRepresentation.base64urlEncodedString(),
                identityKeySig: try identity.dhSignature.base64urlEncodedString(),
                signedPrekey: .init(id: prekeys.signedPrekey.id,
                                    key: prekeys.signedPrekey.key.publicKey.rawRepresentation.base64urlEncodedString(),
                                    sig: prekeys.signedPrekey.signature.base64urlEncodedString()),
                oneTimePrekeys: prekeys.oneTime.map {
                    .init(id: $0.id, key: $0.key.publicKey.rawRepresentation.base64urlEncodedString())
                },
                phoneHash: nil))
            api.token = reg.token
            let meta = Meta(username: handle, displayName: display, userId: reg.userId,
                            deviceId: reg.deviceId, token: reg.token)
            try StorageOwnership.stamp(db, userId: reg.userId)
            try JSONEncoder().encode(meta).write(to: metaURL, options: .atomic)
            print("· \(handle) registered (\(reg.userId))")
            return Person(display: display, home: home, db: db, store: store, api: api, meta: meta)
        } catch let e as APIError where e.code == "username_taken" {
            attempt += 1
            handle = "\(name)\(attempt)"
            if attempt > 20 { throw FixtureError("no free handle for \(name)") }
        }
    }
}

func startEngine(_ p: Person, base: URL) async {
    p.e2ee = E2EEManager(store: p.store, api: p.api, ownUserId: p.userId, ownDeviceId: p.meta.deviceId)
    p.engine = SyncEngine(db: p.db, api: p.api, e2ee: p.e2ee,
                          wsURL: wsURL(base: base, token: p.meta.token),
                          ownUserId: p.userId, ownDeviceId: p.meta.deviceId)
    await p.engine.start()
    try? await p.engine.refreshSnapshot()
}

/// Waits until a condition holds, polling ten times a second. Everything here
/// travels over a socket, so nothing is ready the instant it is asked for.
func settle(_ what: String, seconds: Double = 20, _ check: () async throws -> Bool) async throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if try await check() { return }
        try await Task.sleep(nanoseconds: 100_000_000)
    }
    throw FixtureError("timed out waiting for \(what)")
}

func chatExists(_ p: Person, _ chatId: String) async throws -> Bool {
    (try await p.db.read { dbc in
        try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM chat WHERE id = ?", arguments: [chatId])
    } ?? 0) > 0
}

func textCount(_ p: Person, _ chatId: String) async throws -> Int {
    try await p.db.read { dbc in
        try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND kind = 'text'",
                         arguments: [chatId]) ?? 0
    }
}

/// One line of the conversation: the sender enqueues it, and it is not done
/// until every other member can read it — that is what makes the fixture a chat
/// with history rather than a chat with ciphertext in it.
func say(_ text: String, from sender: Person, in chatId: String, to others: [Person]) async throws {
    let before = try await withThrowingTaskGroup(of: (String, Int).self) { group -> [String: Int] in
        for p in others { group.addTask { (p.username, try await textCount(p, chatId)) } }
        var seen: [String: Int] = [:]
        for try await (name, n) in group { seen[name] = n }
        return seen
    }
    var content = ContentPayload(kind: "text")
    content.text = text
    try await sender.engine.enqueue(content: content, chatId: chatId)
    try await settle("«\(text)» to reach \(others.map(\.username).joined(separator: ", "))") {
        for p in others {
            if try await textCount(p, chatId) <= (before[p.username] ?? 0) { return false }
        }
        return true
    }
}

func seed(dir: URL, base: URL) async throws {
    var people: [Person] = []
    for (name, display) in cast {
        people.append(try await openPerson(name: name, display: display, dir: dir, base: base))
    }
    for p in people { await startEngine(p, base: base) }

    // The direct chats: three pairs, each accepted by the one who did not open
    // it, so neither side is left holding a request.
    var directs: [(String, Person, Person)] = []
    for i in 0..<people.count {
        for j in (i + 1)..<people.count {
            let a = people[i], b = people[j]
            let chatId = try await a.api.createChat(kind: "direct", memberIds: [b.userId], title: nil)
            try await settle("\(b.username) to see the chat with \(a.username)") { try await chatExists(b, chatId) }
            await b.engine.acceptChatRequest(chatId: chatId)
            directs.append((chatId, a, b))
            print("· direct \(a.username) ↔ \(b.username): \(chatId)")
        }
    }

    // The groups: all three in each, created by a different member every time,
    // so the fixture holds a chat every one of them started.
    var groups: [(String, Person)] = []
    for (n, title) in groupTitles.enumerated() {
        let creator = people[n % people.count]
        let others = people.filter { $0.userId != creator.userId }
        let chatId = try await creator.api.createChat(kind: "group",
                                                      memberIds: others.map(\.userId), title: title)
        for p in others {
            try await settle("\(p.username) to see «\(title)»") { try await chatExists(p, chatId) }
        }
        groups.append((chatId, creator))
        print("· group «\(title)»: \(chatId)")
    }

    // Something to read in every chat. The lines are plain on purpose: a
    // screenshot of a scenario should not be arguing with its own fixture text.
    for (chatId, a, b) in directs {
        if try await textCount(a, chatId) >= 4 { continue }
        try await say("Hi, \(b.display.split(separator: " ").first.map(String.init) ?? b.username).",
                      from: a, in: chatId, to: [b])
        try await say("Hey. Everything is up on my side.", from: b, in: chatId, to: [a])
        try await say("Good. I am watching the feed here.", from: a, in: chatId, to: [b])
        try await say("Say the word when you need a second pair of eyes.", from: b, in: chatId, to: [a])
    }
    for (chatId, creator) in groups {
        if try await textCount(creator, chatId) >= 3 { continue }
        let others = people.filter { $0.userId != creator.userId }
        try await say("Opened this one for us three.", from: creator, in: chatId, to: others)
        try await say("Reading you.", from: others[0], in: chatId, to: [creator, others[1]])
        try await say("Same here.", from: others[1], in: chatId, to: [creator, others[0]])
    }

    for p in people {
        await p.engine.stop()
        // the app copies the file, so the journal has to be folded back into it
        try await p.db.writeWithoutTransaction { dbc in
            try dbc.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let location = StorageLocation(root: p.home)
        let session = SessionFile(userId: p.userId, deviceId: p.meta.deviceId,
                                  token: p.meta.token, username: p.username)
        try JSONEncoder().encode(session).write(to: location.sessionURL, options: .atomic)
    }

    print("")
    print("Three accounts, three direct chats and three groups, all with history:")
    for p in people { print("  \(p.username) — \(p.userId) — \(p.home.path)") }
}

/// A headless conversational peer for one-simulator scenarios: opens a fixture
/// account, waits for the next incoming text, accepts the chat if it arrived as
/// a request, and answers in the same chat through the real engine.
func answer(dir: URL, base: URL, name: String, text: String, seconds: Double) async throws {
    guard let member = cast.first(where: { $0.name == name }) else {
        throw FixtureError("unknown account \(name)")
    }
    let p = try await openPerson(name: member.name, display: member.display, dir: dir, base: base)
    await startEngine(p, base: base)
    // messages older than this run are history, not the thing to answer
    let since = Date().timeIntervalSince1970 - 5
    var found: (chatId: String, text: String)?
    try await settle("an incoming message", seconds: seconds) {
        found = try await p.db.read { dbc in
            let row = try Row.fetchOne(dbc, sql: """
                SELECT chatId, text FROM message
                WHERE isOutgoing = 0 AND kind = 'text' AND sentAt >= ?
                ORDER BY sentAt DESC LIMIT 1
                """, arguments: [since])
            return row.map { ($0["chatId"], $0["text"] ?? "") }
        }
        return found != nil
    }
    let msg = found!
    print("· got «\(msg.text)» in \(msg.chatId)")
    await p.engine.acceptChatRequest(chatId: msg.chatId)
    var content = ContentPayload(kind: "text")
    content.text = text
    try await p.engine.enqueue(content: content, chatId: msg.chatId)
    try await settle("the answer to leave the outbox", seconds: 30) {
        try await p.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        } == 0
    }
    await p.engine.stop()
    print("· answered «\(text)»")
}

/// Sends one text into the existing direct chat with a named peer, so a
/// one-simulator scenario can receive a message it did not ask for. With
/// `shader` (a file: Shadertoy GLSL or a JSON export) the message carries
/// that document instead, as `kind` — "shader" or "sticker".
func send(dir: URL, base: URL, name: String, peer: String, text: String, repeatCount: Int = 1,
          shader: URL? = nil, kind: String = "shader") async throws {
    // a seeded account, or one `knock` registered under the same directory
    let display = cast.first(where: { $0.name == name })?.display ?? name
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent("meta.json").path) else {
        throw FixtureError("unknown account \(name)")
    }
    let p = try await openPerson(name: name, display: display, dir: dir, base: base)
    let peerMetaURL = dir.appendingPathComponent(peer).appendingPathComponent("meta.json")
    let chatId: String?
    if let data = try? Data(contentsOf: peerMetaURL),
       let peerMeta = try? JSONDecoder().decode(Meta.self, from: data) {
        chatId = try await p.db.read { dbc in
            try String.fetchOne(dbc, sql: """
                SELECT c.id FROM chat c
                JOIN member m ON m.chatId = c.id AND m.userId = ?
                WHERE c.kind = 'direct'
                """, arguments: [peerMeta.userId])
        }
    } else {
        // not a seeded account: a group is addressed by its title
        chatId = try await p.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT id FROM chat WHERE kind = 'group' AND title = ?",
                                arguments: [peer])
        }
    }
    guard let chatId else { throw FixtureError("no chat between \(name) and \(peer)") }
    // --reply quotes the peer's latest message, so the text lands as a reply
    var replyTo: ReplyPreview?
    if flag("reply") {
        replyTo = try await p.db.read { dbc in
            guard let row = try Row.fetchOne(dbc, sql: """
                SELECT seq, fromUserId, text, kind FROM message
                WHERE chatId = ? AND isOutgoing = 0 AND seq IS NOT NULL
                ORDER BY seq DESC LIMIT 1
                """, arguments: [chatId]) else { return nil }
            return ReplyPreview(seq: row["seq"], authorId: row["fromUserId"],
                                text: row["text"] ?? "", kind: row["kind"])
        }
        guard replyTo != nil else { throw FixtureError("no incoming message to reply to") }
    }
    await startEngine(p, base: base)
    let document = try shader.map { try ShaderDocument.parse(String(contentsOf: $0, encoding: .utf8)) }
    for i in 1...max(1, repeatCount) {
        var content: ContentPayload
        if let document {
            content = ContentPayload(kind: kind)
            content.shader = document
        } else {
            content = ContentPayload(kind: "text")
            content.text = repeatCount > 1 ? "\(text) \(i)" : text
        }
        content.replyTo = replyTo
        try await p.engine.enqueue(content: content, chatId: chatId)
    }
    try await settle("the messages to leave the outbox", seconds: 300) {
        try await p.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        } == 0
    }
    await p.engine.stop()
    print("· sent \(document == nil ? "«\(text)»" : "a \(kind)") ×\(max(1, repeatCount)) to \(peer) in \(chatId)")
}

/// Reacts to the peer's latest message in their direct chat.
func react(dir: URL, base: URL, name: String, peer: String, emoji: String) async throws {
    // a seeded account, or one `knock` registered under the same directory
    let display = cast.first(where: { $0.name == name })?.display ?? name
    guard FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).appendingPathComponent("meta.json").path) else {
        throw FixtureError("unknown account \(name)")
    }
    let p = try await openPerson(name: name, display: display, dir: dir, base: base)
    let peerMetaURL = dir.appendingPathComponent(peer).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: peerMetaURL),
          let peerMeta = try? JSONDecoder().decode(Meta.self, from: data) else {
        throw FixtureError("no meta for \(peer)")
    }
    // the engine first: the latest message may not have been synced yet
    await startEngine(p, base: base)
    func latest() async throws -> (chatId: String, id: String, text: String?)? {
        try await p.db.read { dbc in
            guard let chatId = try String.fetchOne(dbc, sql: """
                SELECT c.id FROM chat c
                JOIN member m ON m.chatId = c.id AND m.userId = ?
                WHERE c.kind = 'direct'
                """, arguments: [peerMeta.userId]) else { return nil }
            guard let row = try Row.fetchOne(dbc, sql: """
                SELECT id, text FROM message
                WHERE chatId = ? AND isOutgoing = 0 AND seq IS NOT NULL
                ORDER BY seq DESC LIMIT 1
                """, arguments: [chatId]) else { return nil }
            return (chatId, row["id"], row["text"])
        }
    }
    var found: (chatId: String, id: String, text: String?)?
    try await settle("a message from \(peer) to react to", seconds: 30) {
        found = try await latest()
        return found != nil
    }
    guard let target = found else { throw FixtureError("no incoming message from \(peer) to react to") }
    var content = ContentPayload(kind: "reaction")
    content.targetLocalId = target.id
    content.emoji = emoji
    try await p.engine.enqueue(content: content, chatId: target.chatId)
    try await settle("the reaction to leave the outbox", seconds: 300) {
        try await p.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        } == 0
    }
    await p.engine.stop()
    print("· reacted \(emoji) to «\(target.text ?? "")» in \(target.chatId)")
}

/// Writes to a fixture account from someone it has never talked to: a fresh
/// account is registered under `name`, opens a direct chat with the peer and
/// sends one text, so the peer's device receives a message request.
func knock(dir: URL, base: URL, name: String, display: String, peer: String, text: String) async throws {
    let peerMetaURL = dir.appendingPathComponent(peer).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: peerMetaURL),
          let peerMeta = try? JSONDecoder().decode(Meta.self, from: data) else {
        throw FixtureError("\(peer) is not seeded")
    }
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    let p = try await openPerson(name: name, display: display, dir: dir, base: base)
    await startEngine(p, base: base)
    let chatId = try await p.api.createChat(kind: "direct", memberIds: [peerMeta.userId], title: nil)
    try await settle("the chat to reach \(p.username)") { try await chatExists(p, chatId) }
    var content = ContentPayload(kind: "text")
    content.text = text
    try await p.engine.enqueue(content: content, chatId: chatId)
    try await settle("the message to leave the outbox", seconds: 60) {
        try await p.db.read { dbc in
            try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        } == 0
    }
    await p.engine.stop()
    print("· \(p.username) knocked on \(peer) with «\(text)» in \(chatId)")
}

/// Holds a typing indicator up in the direct chat with a named peer for a few
/// seconds, so its rendering can be watched on a screen.
func typing(dir: URL, base: URL, name: String, peer: String, seconds: Double) async throws {
    guard let member = cast.first(where: { $0.name == name }) else {
        throw FixtureError("unknown account \(name)")
    }
    let peerMetaURL = dir.appendingPathComponent(peer).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: peerMetaURL),
          let peerMeta = try? JSONDecoder().decode(Meta.self, from: data) else {
        throw FixtureError("\(peer) is not seeded")
    }
    let p = try await openPerson(name: member.name, display: member.display, dir: dir, base: base)
    let chatId = try await p.db.read { dbc in
        try String.fetchOne(dbc, sql: """
            SELECT c.id FROM chat c
            JOIN member m ON m.chatId = c.id AND m.userId = ?
            WHERE c.kind = 'direct'
            """, arguments: [peerMeta.userId])
    }
    guard let chatId else { throw FixtureError("no direct chat between \(name) and \(peer)") }
    await startEngine(p, base: base)
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        await p.engine.sendTyping(chatId: chatId, kind: "text")
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }
    await p.engine.sendTyping(chatId: chatId, kind: nil)
    await p.engine.stop()
    print("· typed for \(Int(seconds)) s in \(chatId)")
}

/// Prints the 60-digit safety number this account computes for a peer, so a
/// screen showing the same pair can be checked against an independent side.
func safety(dir: URL, base: URL, name: String, peer: String) async throws {
    guard let member = cast.first(where: { $0.name == name }) else {
        throw FixtureError("unknown account \(name)")
    }
    let peerMetaURL = dir.appendingPathComponent(peer).appendingPathComponent("meta.json")
    guard let data = try? Data(contentsOf: peerMetaURL),
          let peerMeta = try? JSONDecoder().decode(Meta.self, from: data) else {
        throw FixtureError("\(peer) is not seeded")
    }
    let p = try await openPerson(name: member.name, display: member.display, dir: dir, base: base)
    var keys = try await p.db.read { dbc -> (String, String)? in
        let row = try Row.fetchOne(dbc, sql: "SELECT identitySigning, identityDH FROM user WHERE id = ?",
                                   arguments: [peerMeta.userId])
        guard let row, let s: String = row["identitySigning"], let d: String = row["identityDH"]
        else { return nil }
        return (s, d)
    }
    if keys == nil, let b = try await p.api.prekeys(userId: peerMeta.userId).bundles.first {
        keys = (b.identitySignKey, b.identityKey)
    }
    guard let (signingB64, dhB64) = keys,
          let signing = Data(base64urlEncoded: signingB64),
          let dh = Data(base64urlEncoded: dhB64) else {
        throw FixtureError("no identity keys for \(peer)")
    }
    let mine = try p.store.identity()
    print(SafetyNumbers.generate(
        ourIdentitySigning: mine.signing.publicKey.rawRepresentation,
        ourIdentityDH: mine.dh.publicKey.rawRepresentation,
        ourUserId: p.userId,
        theirIdentitySigning: signing, theirIdentityDH: dh,
        theirUserId: peerMeta.userId))
}

// MARK: - The shader showcase

/// The accounts the showcase runs on. They are registered fresh, apart from
/// the service trio, so the history in the frame holds nothing but the demo.
let showcaseCast: [(name: String, display: String)] = [
    ("demo", "Demo"),
    ("nova", "Nova"),
    ("iris", "Iris"),
]

/// The direct chat between two people, opened and accepted if it is not there yet.
func directChat(_ a: Person, _ b: Person) async throws -> String {
    if let existing = try await a.db.read({ dbc in
        try String.fetchOne(dbc, sql: """
            SELECT c.id FROM chat c
            JOIN member m ON m.chatId = c.id AND m.userId = ?
            WHERE c.kind = 'direct'
            """, arguments: [b.userId])
    }) { return existing }
    let chatId = try await a.api.createChat(kind: "direct", memberIds: [b.userId], title: nil)
    try await settle("\(b.username) to see the chat with \(a.username)") { try await chatExists(b, chatId) }
    await b.engine.acceptChatRequest(chatId: chatId)
    return chatId
}

func kindCount(_ p: Person, _ chatId: String, _ kind: String) async throws -> Int {
    try await p.db.read { dbc in
        try Int.fetchOne(dbc, sql: "SELECT COUNT(*) FROM message WHERE chatId = ? AND kind = ?",
                         arguments: [chatId, kind]) ?? 0
    }
}

/// One message of any kind, done when every other member holds one more row of it.
func deliver(_ content: ContentPayload, from sender: Person, in chatId: String, to others: [Person]) async throws {
    var before: [String: Int] = [:]
    for p in others { before[p.username] = try await kindCount(p, chatId, content.kind) }
    try await sender.engine.enqueue(content: content, chatId: chatId)
    let label = content.text ?? content.shader?.name ?? content.kind
    try await settle("«\(label)» to reach \(others.map(\.username).joined(separator: ", "))", seconds: 60) {
        for p in others {
            if try await kindCount(p, chatId, content.kind) <= (before[p.username] ?? 0) { return false }
        }
        return true
    }
}

/// Puts the shader gallery onto the stand: `nova` and the «Showcase» group
/// wear shader avatars, the demo chat with `nova` holds every sticker and a
/// text on each bubble shader, and `demo`'s own home gets the aurora as that
/// chat's background. Running it again adds nothing to a chat already dressed.
func showcase(dir: URL, base: URL) async throws {
    var people: [Person] = []
    for (name, display) in showcaseCast {
        people.append(try await openPerson(name: name, display: display, dir: dir, base: base))
    }
    let demo = people[0], nova = people[1], iris = people[2]
    for p in people { await startEngine(p, base: base) }

    let novaChat = try await directChat(nova, demo)
    let irisChat = try await directChat(iris, demo)
    print("· direct demo ↔ nova: \(novaChat)")
    print("· direct demo ↔ iris: \(irisChat)")

    let groupTitle = "Showcase"
    var group = try await iris.db.read { dbc in
        try String.fetchOne(dbc, sql: "SELECT id FROM chat WHERE kind = 'group' AND title = ?", arguments: [groupTitle])
    }
    if group == nil {
        let id = try await iris.api.createChat(kind: "group", memberIds: [demo.userId, nova.userId], title: groupTitle)
        for p in [demo, nova] { try await settle("\(p.username) to see «\(groupTitle)»") { try await chatExists(p, id) } }
        group = id
    }
    let groupId = group!
    print("· group «\(groupTitle)»: \(groupId)")

    // the avatars: nova's own, and the group's
    let novaAvatar = try await nova.api.uploadShaderAvatar(ShaderGallery.nebula)
    try await nova.db.write { dbc in
        try dbc.execute(sql: "UPDATE user SET avatarId = ? WHERE id = ?", arguments: [novaAvatar, nova.userId])
    }
    let groupAvatar = try await iris.api.uploadShaderAvatar(ShaderGallery.orbit, chatId: groupId)
    print("· avatars: nova \(novaAvatar), «\(groupTitle)» \(groupAvatar)")

    // the demo chat: every sticker, a text on each bubble shader
    if try await kindCount(demo, novaChat, "sticker") < ShaderGallery.stickers.count {
        var hello = ContentPayload(kind: "text")
        hello.text = "Every one of these is a tiny program. Tap them."
        try await deliver(hello, from: nova, in: novaChat, to: [demo])
        let captions = [
            "Pond": "Drop a finger in.",
            "Fireworks": "Tap where the next one should go.",
            "Eye": "It follows your finger. Tap to make it blink.",
            "Ink": "Stir it.",
            "Clock": "This one knows the time.",
        ]
        for doc in ShaderGallery.stickers {
            var sticker = ContentPayload(kind: "sticker")
            sticker.shader = doc
            try await deliver(sticker, from: nova, in: novaChat, to: [demo])
            if let caption = captions[doc.name ?? ""] {
                var line = ContentPayload(kind: "text")
                line.text = caption
                try await deliver(line, from: nova, in: novaChat, to: [demo])
            }
        }
        var foil = ContentPayload(kind: "text")
        foil.text = "This text sits on holographic foil. Scroll, and the card tilts."
        foil.bubbleShader = ShaderGallery.foil
        try await deliver(foil, from: nova, in: novaChat, to: [demo])
        var ember = ContentPayload(kind: "text")
        ember.text = "And this one is written over embers."
        ember.bubbleShader = ShaderGallery.ember
        try await deliver(ember, from: nova, in: novaChat, to: [demo])
        var close = ContentPayload(kind: "text")
        close.text = "Send me one back. The pack is under the sticker button."
        try await deliver(close, from: nova, in: novaChat, to: [demo])
    }
    if try await kindCount(demo, irisChat, "text") < 1 {
        var line = ContentPayload(kind: "text")
        line.text = "Hi. Nova has the good stuff, I just hold the group."
        try await deliver(line, from: iris, in: irisChat, to: [demo])
    }
    if try await kindCount(demo, groupId, "sticker") < 1 {
        var welcome = ContentPayload(kind: "text")
        welcome.text = "Opened this one for the three of us."
        try await deliver(welcome, from: iris, in: groupId, to: [demo, nova])
        var burst = ContentPayload(kind: "sticker")
        burst.shader = ShaderGallery.fireworks
        try await deliver(burst, from: nova, in: groupId, to: [demo, iris])
    }

    // the peers' avatars land in demo's home with the snapshot
    try? await demo.engine.refreshSnapshot()
    try await settle("nova's avatar to reach demo") {
        try await demo.db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT avatarId FROM user WHERE id = ?", arguments: [nova.userId])
        } == novaAvatar
    }

    for p in people {
        await p.engine.stop()
        try await p.db.writeWithoutTransaction { dbc in
            try dbc.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let location = StorageLocation(root: p.home)
        let session = SessionFile(userId: p.userId, deviceId: p.meta.deviceId,
                                  token: p.meta.token, username: p.username)
        try JSONEncoder().encode(session).write(to: location.sessionURL, options: .atomic)
    }

    // demo's own surfaces: the aurora behind the chat with nova. The sticker
    // pack needs nothing here: the app seeds the bundled stickers into a new home.
    let aurora = String(decoding: try JSONEncoder().encode(ShaderGallery.aurora), as: UTF8.self)
    try await demo.db.write { dbc in
        try dbc.execute(sql: "INSERT OR REPLACE INTO kv (key, value) VALUES (?, ?)",
                        arguments: ["shader.background:\(novaChat)", aurora])
    }
    try await demo.db.writeWithoutTransaction { dbc in
        try dbc.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    print("")
    print("The showcase is on the stand. Hand `demo` to a simulator:")
    print("  scripts/fixture.py install demo <udid> --launch")
    for p in people { print("  \(p.username) — \(p.userId) — \(p.home.path)") }
}

func show(dir: URL) throws {
    for (name, _) in cast {
        let metaURL = dir.appendingPathComponent(name).appendingPathComponent("meta.json")
        guard let data = try? Data(contentsOf: metaURL),
              let meta = try? JSONDecoder().decode(Meta.self, from: data) else {
            print("\(name): not seeded")
            continue
        }
        print("\(meta.username): \(meta.userId) device \(meta.deviceId)")
    }
}

let command = CommandLine.arguments.dropFirst().first ?? "help"
do {
    switch command {
    case "seed":
        let dir = URL(fileURLWithPath: try arg("dir"))
        let base = URL(string: try arg("base", default: "http://localhost:8787"))!
        if flag("reset") {
            for (name, _) in cast {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try await seed(dir: dir, base: base)
    case "showcase":
        try await showcase(dir: URL(fileURLWithPath: try arg("dir")),
                           base: URL(string: try arg("base", default: "http://localhost:8787"))!)
    case "show":
        try show(dir: URL(fileURLWithPath: try arg("dir")))
    case "send":
        try await send(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "bravo"),
            peer: try arg("to", default: "alfa"),
            text: try arg("text", default: "Checking in."),
            repeatCount: Int(try arg("repeat", default: "1")) ?? 1,
            shader: (try? arg("shader")).map { URL(fileURLWithPath: $0) },
            kind: try arg("kind", default: "shader"))
    case "react":
        try await react(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "bravo"),
            peer: try arg("to", default: "alfa"),
            emoji: try arg("emoji", default: "❤️"))
    case "knock":
        try await knock(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "delta"),
            display: try arg("name", default: "Delta Service"),
            peer: try arg("to", default: "alfa"),
            text: try arg("text", default: "Hi! Is this the right place to ask about the beta?"))
    case "typing":
        try await typing(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "charlie"),
            peer: try arg("to", default: "alfa"),
            seconds: Double(try arg("seconds", default: "10")) ?? 10)
    case "safety":
        try await safety(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "charlie"),
            peer: try arg("with", default: "alfa"))
    case "answer":
        try await answer(
            dir: URL(fileURLWithPath: try arg("dir")),
            base: URL(string: try arg("base", default: "http://localhost:8787"))!,
            name: try arg("as", default: "alfa"),
            text: try arg("text", default: "Loud and clear."),
            seconds: Double(try arg("timeout", default: "180")) ?? 180)
    default:
        print("""
        usage:
          msngrfixture seed --dir <fixtures> [--base http://localhost:8787] [--reset]
          msngrfixture show --dir <fixtures>
          msngrfixture showcase --dir <fixtures> [--base …]   the shader gallery on fresh demo accounts
          msngrfixture send --dir <fixtures> [--as bravo] [--to alfa | --to <group title>] [--base …] [--text …]
          msngrfixture send --dir <fixtures> --shader <file.glsl|export.json> [--kind shader|sticker] [--as bravo] [--to alfa]
          msngrfixture knock --dir <fixtures> [--as delta] [--name "Delta Service"] [--to alfa] [--base …] [--text …]
          msngrfixture typing --dir <fixtures> [--as charlie] [--to alfa] [--base …] [--seconds 10]
          msngrfixture answer --dir <fixtures> [--as alfa] [--base …] [--text …] [--timeout 180]
        """)
    }
} catch {
    FileHandle.standardError.write(Data("msngrfixture: \(error)\n".utf8))
    exit(1)
}
