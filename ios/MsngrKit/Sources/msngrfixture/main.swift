import Foundation
import GRDB
import MsngrCore

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
    case "show":
        try show(dir: URL(fileURLWithPath: try arg("dir")))
    default:
        print("""
        usage:
          msngrfixture seed --dir <fixtures> [--base http://localhost:8787] [--reset]
          msngrfixture show --dir <fixtures>
        """)
    }
} catch {
    FileHandle.standardError.write(Data("msngrfixture: \(error)\n".utf8))
    exit(1)
}
