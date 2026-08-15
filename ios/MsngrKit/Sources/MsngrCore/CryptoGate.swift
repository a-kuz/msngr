import Foundation

/// Mutual exclusion over the crypto state of the shared database.
///
/// The ratchet is read-modify-write: a session is loaded, stepped, and stored
/// again. The app and the notification service extension are separate processes
/// over one file, so two of those cycles running at once end with one of them
/// overwriting the other's step. The session that loses the write keeps keys the
/// peer has already moved past, and every message after it becomes unreadable.
/// SQLite alone does not prevent that — each process reads and writes in
/// transactions of its own, and nothing binds the read to the write.
///
/// The gate binds them. Every load-modify-store cycle over `ratchetSession`,
/// `senderKeyIn`, the prekey blob and `trustedIdentity` runs inside `withLock`,
/// which is exclusive across processes (`flock`) and across threads (`NSLock`).
///
/// Two rules keep it deadlock-free:
///
/// - the gate is taken **before** a database transaction, never inside one;
/// - a locked region is synchronous and contains no `await`, so the lock is
///   never held across a suspension.
///
/// `flock` is released by the kernel when the process dies, so a killed
/// extension — the system kills them routinely — cannot leave the gate shut.
public final class CryptoGate: @unchecked Sendable {
    /// Proof that the holder is inside a locked region. Operations that mutate
    /// crypto state without taking the lock themselves demand one, so a caller
    /// cannot reach them by accident.
    public struct Ticket: Sendable {
        fileprivate init() {}
    }

    /// Why a locked region was not entered.
    public enum Failure: Error, Equatable {
        /// Another process held the gate for longer than the caller could wait.
        case busy
    }

    public static let fileName = ".cryptogate"

    /// How long a caller waits for the other process by default. An extension
    /// has about thirty seconds in total, and the work behind the gate is a few
    /// database transactions, so a wait this long means the other side is stuck
    /// rather than busy.
    public static let defaultTimeout: TimeInterval = 5

    private let url: URL?
    private let timeout: TimeInterval
    private let mutex = NSLock()
    /// Held only while the file lock is being taken or released.
    private let fileLock = NSLock()
    private var descriptor: Int32 = -1

    /// - Parameters:
    ///   - url: file the cross-process lock is taken on. A gate without one is
    ///     exclusive inside the process only, which is all an in-memory
    ///     database can be shared by.
    ///   - timeout: how long a caller waits for the other process.
    public init(url: URL?, timeout: TimeInterval = CryptoGate.defaultTimeout) {
        self.url = url
        self.timeout = timeout
    }

    public convenience init(location: StorageLocation) {
        self.init(url: location.cryptoGateURL)
    }

    /// One gate per file in this process: the thread lock inside it is what
    /// makes the process's own callers wait for each other, and it only counts
    /// when they share an instance.
    public static func shared(location: StorageLocation) -> CryptoGate {
        shared(url: location.cryptoGateURL)
    }

    public static func shared(url: URL) -> CryptoGate {
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = registry[url.path] { return existing }
        let gate = CryptoGate(url: url)
        registry[url.path] = gate
        return gate
    }

    private static let registryLock = NSLock()
    private static var registry: [String: CryptoGate] = [:]

    /// Runs `body` with the crypto state of this database to itself.
    ///
    /// Throws `Failure.busy` when the other process did not let go in time; the
    /// caller then leaves the state untouched rather than stepping a ratchet it
    /// does not own.
    @discardableResult
    public func withLock<T>(timeout: TimeInterval? = nil,
                            _ body: (Ticket) throws -> T) throws -> T {
        let deadline = Date().addingTimeInterval(timeout ?? self.timeout)
        guard mutex.lock(before: deadline) else { throw Failure.busy }
        defer { mutex.unlock() }
        try lockFile(until: deadline)
        defer { unlockFile() }
        return try body(Ticket())
    }

    // MARK: - File lock

    private func lockFile(until deadline: Date) throws {
        guard let url else { return }
        fileLock.lock()
        defer { fileLock.unlock() }
        if descriptor < 0 {
            descriptor = open(url.path, O_RDWR | O_CREAT, 0o600)
            guard descriptor >= 0 else {
                // no lock file, no cross-process exclusion to take: the thread
                // lock above still holds, and refusing to work here would make
                // an unreadable container out of a missing file
                MsngrLog.repair.error("crypto gate file unavailable at \(url.path, privacy: .public)")
                return
            }
        }
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else {
                if errno == EWOULDBLOCK { throw Failure.busy }
                return // the lock cannot be taken at all: fall through to the thread lock
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private func unlockFile() {
        fileLock.lock()
        defer { fileLock.unlock() }
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
    }
}
