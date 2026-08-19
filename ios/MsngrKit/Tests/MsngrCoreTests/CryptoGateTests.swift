import XCTest
import GRDB
@testable import MsngrCore

/// Two processes over one ratchet.
///
/// The app and the notification service extension open envelopes from separate
/// processes over the same database file. A ratchet step is read-modify-write,
/// so two of them at once end with one step overwriting the other and the
/// session unable to read anything after it. Here each "process" is its own
/// database connection, its own store and its own gate instance — which is
/// exactly what `flock` sees: separate open files contend even inside one test
/// process.
final class CryptoGateTests: XCTestCase {
    private struct Process {
        let db: DatabaseQueue
        let store: IdentityStore
        let gate: CryptoGate
        let decryptor: IncomingDecryptor
    }

    private func open(_ location: StorageLocation, gated: Bool) throws -> Process {
        let db = try AppDatabase.open(at: location.databaseURL)
        let store = try IdentityStore(db: db, masterKeyProvider: SharedFileMasterKey(location: location))
        let gate = CryptoGate(url: gated ? location.cryptoGateURL : nil)
        return Process(db: db, store: store, gate: gate,
                       decryptor: IncomingDecryptor(store: store, ownUserId: "me",
                                                    ownDeviceId: "dev", gate: gate))
    }

    /// The app sends while the extension opens what arrives — one session, two
    /// processes, at the same moment.
    ///
    /// The sending chain is the part that cannot be redone: a number used twice
    /// is a message the peer will never open, because the key for that position
    /// is spent by the first one. Every outgoing header here must therefore be
    /// its own position, and every incoming envelope must come out readable.
    ///
    /// Without the gate this run produces repeated positions within a few
    /// messages: the app loads a session, the extension stores a stepped one
    /// underneath it, and the app writes its own back over the top.
    func testSendingAndReceivingAtOnceKeepOneChain() throws {
        let location = try TestStorage.temporary()
        defer { TestStorage.remove(location) }
        let sending = try open(location, gated: true)
        let receiving = try open(location, gated: true)
        var peer = try RatchetPair(store: sending.store)

        let count = 40
        var envelopes: [JSONValue] = []
        for i in 0..<count { envelopes.append(try peer.envelope(text: "m\(i)")) }

        let lock = NSLock()
        var headers: [String] = []
        var opened: [Int: String] = [:]
        let group = DispatchGroup()
        // both sides start together, or the race is only a sequence
        let startLine = DispatchSemaphore(value: 0)

        // The app's side of it: load, step, store — the shape of what
        // `E2EEManager.encryptPairwise` does behind the same gate.
        DispatchQueue.global().async(group: group) {
            startLine.wait()
            for i in 0..<count {
                try? sending.gate.withLock { _ in
                    guard var session = try sending.store.loadSession(peerUserId: "peer",
                                                                      peerDeviceId: "peerdev")
                    else { return }
                    let message = try session.encrypt(Data("out\(i)".utf8))
                    // A send is more than one step in life — a device list, a
                    // box per device, the encoding of each — and the window
                    // between reading a session and storing it is what the
                    // other process falls into. Here it is made plain.
                    Thread.sleep(forTimeInterval: 0.002)
                    try sending.store.saveSession(session, peerUserId: "peer",
                                                  peerDeviceId: "peerdev")
                    lock.lock()
                    headers.append("\(message.header.dhPub.base64EncodedString())/\(message.header.n)")
                    lock.unlock()
                }
            }
        }
        // The extension's side: the envelopes its pushes carried.
        DispatchQueue.global().async(group: group) {
            startLine.wait()
            for i in 0..<count {
                // paced to the sending side and jittered, so the two of them
                // meet over the whole burst and at every phase of it
                Thread.sleep(forTimeInterval: Double.random(in: 0...0.004))
                guard let result = try? receiving.decryptor.decrypt(
                    envelopeJSON: envelopes[i], chatId: "c1",
                    fromUserId: "peer", fromDeviceId: "peerdev"),
                      case .content(let payload) = result, let text = payload.text
                else { continue }
                lock.lock()
                opened[i] = text
                lock.unlock()
            }
        }
        startLine.signal()
        startLine.signal()
        group.wait()

        XCTAssertEqual(headers.count, count)
        XCTAssertEqual(Set(headers).count, headers.count,
                       "a position used twice: \(headers.count - Set(headers).count) of \(count)")
        XCTAssertEqual(opened.count, count, "lost \(count - opened.count) of \(count) messages")
        for i in 0..<count {
            XCTAssertEqual(opened[i], "m\(i)")
        }
    }

    /// Opening an envelope takes the gate. While another process holds it, the
    /// decryptor waits and then gives up with the session exactly as it was —
    /// a step it cannot take exclusively is a step it does not take.
    func testDecryptRefusesWhileTheGateIsHeld() throws {
        let location = try TestStorage.temporary()
        defer { TestStorage.remove(location) }
        let process = try open(location, gated: true)
        var peer = try RatchetPair(store: process.store)
        let envelope = try peer.envelope(text: "held")

        let held = expectation(description: "the other process is inside")
        let release = expectation(description: "released")
        DispatchQueue.global().async {
            try? CryptoGate(url: location.cryptoGateURL).withLock { _ in
                held.fulfill()
                self.wait(for: [release], timeout: 5)
            }
        }
        wait(for: [held], timeout: 5)

        let before = try process.store.loadSession(peerUserId: "peer", peerDeviceId: "peerdev")
        let blocked = IncomingDecryptor(store: process.store, ownUserId: "me", ownDeviceId: "dev",
                                        gate: CryptoGate(url: location.cryptoGateURL, timeout: 0.2))
        XCTAssertThrowsError(try blocked.decrypt(envelopeJSON: envelope, chatId: "c1",
                                                 fromUserId: "peer", fromDeviceId: "peerdev")) {
            XCTAssertEqual($0 as? CryptoGate.Failure, .busy)
        }
        let after = try process.store.loadSession(peerUserId: "peer", peerDeviceId: "peerdev")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        XCTAssertEqual(try encoder.encode(before), try encoder.encode(after))

        release.fulfill()
        // released: the same envelope opens, and the message is not lost
        let result = try process.decryptor.decrypt(envelopeJSON: envelope, chatId: "c1",
                                                   fromUserId: "peer", fromDeviceId: "peerdev")
        guard case .content(let payload) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(payload.text, "held")
    }

    /// The lock is exclusive across instances over one file: the second holder
    /// waits, and gives up rather than working on a state it does not own.
    func testGateIsExclusiveAcrossInstances() throws {
        let location = try TestStorage.temporary()
        defer { TestStorage.remove(location) }
        let held = expectation(description: "inside the first gate")
        let release = expectation(description: "released")

        DispatchQueue.global().async {
            try? CryptoGate(url: location.cryptoGateURL).withLock { _ in
                held.fulfill()
                self.wait(for: [release], timeout: 5)
            }
        }
        wait(for: [held], timeout: 5)
        XCTAssertThrowsError(
            try CryptoGate(url: location.cryptoGateURL).withLock(timeout: 0.2) { _ in }
        ) { error in
            XCTAssertEqual(error as? CryptoGate.Failure, .busy)
        }
        release.fulfill()
    }

    /// A gate free again lets the next holder in.
    func testGateIsReusable() throws {
        let location = try TestStorage.temporary()
        defer { TestStorage.remove(location) }
        let gate = CryptoGate(url: location.cryptoGateURL)
        var runs = 0
        for _ in 0..<3 { try gate.withLock { _ in runs += 1 } }
        XCTAssertEqual(runs, 3)
        try CryptoGate(url: location.cryptoGateURL).withLock { _ in runs += 1 }
        XCTAssertEqual(runs, 4)
    }
}
