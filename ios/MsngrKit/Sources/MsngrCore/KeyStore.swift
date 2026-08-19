import Foundation
import CryptoKit
import GRDB
import MsngrCrypto

/// Supplies the master key that encrypts crypto state in the database.
public protocol MasterKeyProvider: Sendable {
    func masterKey() throws -> SymmetricKey
}

/// Keychain-backed: the key is generated once with kSecAttrAccessibleAfterFirstUnlock,
/// which is what lets the extension open pushes while the screen is locked.
public struct KeychainMasterKey: MasterKeyProvider {
    let service: String
    let accessGroup: String?

    public init(service: String = "ai.enface.msngr.masterkey", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func masterKey() throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let keyData = key.withUnsafeBytes { Data($0) }
        var add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if let accessGroup { add[kSecAttrAccessGroup as String] = accessGroup }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw CryptoError.invalidKey }
        return key
    }
}

/// For tests: a fixed in-memory key.
public struct StaticMasterKey: MasterKeyProvider {
    let key: SymmetricKey
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func masterKey() throws -> SymmetricKey { key }
}

/// The master key in a protected file inside the shared container, which lets the app
/// and the extension read the same key without keychain sharing. Data Protection is
/// completeUntilFirstUserAuthentication, so the extension can read it on a locked
/// screen once the device has been unlocked at least once.
public struct SharedFileMasterKey: MasterKeyProvider {
    let url: URL

    public init(containerURL: URL) {
        self.url = containerURL.appendingPathComponent(StorageLocation.masterKeyFileName)
    }

    public init(location: StorageLocation) {
        self.url = location.masterKeyURL
    }

    public func masterKey() throws -> SymmetricKey {
        if let data = try? Data(contentsOf: url), data.count == 32 {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: url, options: [.completeFileProtectionUntilFirstUserAuthentication, .atomic])
        return key
    }
}

/// Encrypts state blobs (ratchet, sender keys) with the master key.
enum StateCrypto {
    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(data, using: key).combined
    }
    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
    }
}

public enum IdentityStoreError: Error, Equatable {
    case identityAlreadyPresent
}

/// This device's own keys: the identity and the private halves of the prekeys, kept in
/// the kv table under the master key.
public final class IdentityStore: @unchecked Sendable {
    private let db: DatabaseQueue
    private let master: SymmetricKey

    public init(db: DatabaseQueue, masterKeyProvider: MasterKeyProvider) throws {
        self.db = db
        self.master = try masterKeyProvider.masterKey()
    }

    // MARK: - Transaction the store is asked to join

    /// Runs `body` with every store access made on `dbc` instead of on a
    /// transaction of the store's own.
    ///
    /// The notification service extension decrypts a message and writes it in
    /// one transaction: the ratchet step and the row it produced commit
    /// together, so an extension the system kills mid-flight leaves neither a
    /// stepped session without its message nor a message without its step.
    /// Reading and writing through the queue from inside that transaction would
    /// deadlock, so the store is handed the open connection instead.
    ///
    /// The binding is per thread: it belongs to the transaction's own thread and
    /// leaves the store's other callers on their own connections.
    public func joining<T>(_ dbc: GRDB.Database, _ body: () throws -> T) rethrows -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[Self.boundKey]
        dictionary[Self.boundKey] = Box(dbc)
        defer { dictionary[Self.boundKey] = previous }
        return try body()
    }

    private static let boundKey = "MsngrCore.IdentityStore.boundDatabase"

    private final class Box {
        let dbc: GRDB.Database
        init(_ dbc: GRDB.Database) { self.dbc = dbc }
    }

    private var bound: GRDB.Database? {
        (Thread.current.threadDictionary[Self.boundKey] as? Box)?.dbc
    }

    private func read<T>(_ body: (GRDB.Database) throws -> T) throws -> T {
        if let bound { return try body(bound) }
        return try db.read(body)
    }

    private func write<T>(_ body: (GRDB.Database) throws -> T) throws -> T {
        if let bound { return try body(bound) }
        return try db.write(body)
    }

    private struct StoredIdentity: Codable {
        var dhRaw: Data
        var signingRaw: Data
    }
    private struct StoredPrekeys: Codable {
        var signedPrekeyId: UInt32
        var signedPrekeyRaw: Data
        var oneTime: [UInt32: Data]  // id -> raw priv
        var nextOneTimeId: UInt32
    }

    private func loadBlob<T: Codable>(_ key: String, as type: T.Type) throws -> T? {
        try read { dbc in
            guard let row = try KVRow.fetchOne(dbc, key: key),
                  let sealed = Data(base64Encoded: row.value) else { return nil }
            let plain = try StateCrypto.open(sealed, with: master)
            return try JSONDecoder().decode(T.self, from: plain)
        }
    }

    private func saveBlob<T: Codable>(_ key: String, _ value: T) throws {
        let plain = try JSONEncoder().encode(value)
        let sealed = try StateCrypto.seal(plain, with: master)
        try write { dbc in
            try KVRow(key: key, value: sealed.base64EncodedString()).save(dbc)
        }
    }

    /// The device identity, created on first use.
    public func identity() throws -> IdentityKeyPair {
        if let stored = try loadBlob("identity", as: StoredIdentity.self) {
            return try IdentityKeyPair(dhRaw: stored.dhRaw, signingRaw: stored.signingRaw)
        }
        let pair = IdentityKeyPair()
        try saveBlob("identity", StoredIdentity(dhRaw: pair.dh.rawRepresentation,
                                                signingRaw: pair.signing.rawRepresentation))
        return pair
    }

    /// Installs the account identity a device that is already signed in handed
    /// over. The identity belongs to the account, not to the device: a linked
    /// device that made one of its own would show every contact a changed
    /// security code and would be blocked from sending
    /// (`docs/research/2026-08-16-second-device.md`).
    ///
    /// Storage is empty at this point — linking wipes it the way registration
    /// does — so an identity already in place means the caller is installing
    /// over a live account, which is a bug rather than a state to merge.
    public func adoptIdentity(dhRaw: Data, signingRaw: Data) throws -> IdentityKeyPair {
        guard try loadBlob("identity", as: StoredIdentity.self) == nil else {
            throw IdentityStoreError.identityAlreadyPresent
        }
        let pair = try IdentityKeyPair(dhRaw: dhRaw, signingRaw: signingRaw)
        try saveBlob("identity", StoredIdentity(dhRaw: dhRaw, signingRaw: signingRaw))
        return pair
    }

    /// Generates the prekey set for registration, keeping the private halves.
    public struct GeneratedPrekeys {
        public let signedPrekey: SignedPreKey
        public let oneTime: [OneTimePreKey]
    }
    public func generatePrekeys(count: Int = 100) throws -> GeneratedPrekeys {
        let id = try identity()
        let spk = try SignedPreKey(id: 1, identity: id)
        var oneTime: [OneTimePreKey] = []
        var stored = StoredPrekeys(signedPrekeyId: spk.id,
                                   signedPrekeyRaw: spk.key.rawRepresentation,
                                   oneTime: [:], nextOneTimeId: UInt32(count) + 1)
        for i in 1...count {
            let otp = OneTimePreKey(id: UInt32(i))
            oneTime.append(otp)
            stored.oneTime[otp.id] = otp.key.rawRepresentation
        }
        try saveBlob("prekeys", stored)
        return GeneratedPrekeys(signedPrekey: spk, oneTime: oneTime)
    }

    /// Tops up the one-time prekeys as the server spends them.
    public func generateMoreOneTime(count: Int = 50) throws -> [OneTimePreKey] {
        guard var stored = try loadBlob("prekeys", as: StoredPrekeys.self) else {
            throw CryptoError.noSession
        }
        var out: [OneTimePreKey] = []
        for _ in 0..<count {
            let otp = OneTimePreKey(id: stored.nextOneTimeId)
            stored.oneTime[otp.id] = otp.key.rawRepresentation
            stored.nextOneTimeId += 1
            out.append(otp)
        }
        try saveBlob("prekeys", stored)
        return out
    }

    public func signedPrekey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let stored = try loadBlob("prekeys", as: StoredPrekeys.self),
              stored.signedPrekeyId == id else { return nil }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: stored.signedPrekeyRaw)
    }

    public func oneTimePrekey(id: UInt32) throws -> Curve25519.KeyAgreement.PrivateKey? {
        guard let stored = try loadBlob("prekeys", as: StoredPrekeys.self),
              let raw = stored.oneTime[id] else { return nil }
        return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }

    /// A one-time prekey is good for a single session, so it is dropped after use.
    public func consumeOneTimePrekey(id: UInt32) throws {
        guard var stored = try loadBlob("prekeys", as: StoredPrekeys.self) else { return }
        stored.oneTime.removeValue(forKey: id)
        try saveBlob("prekeys", stored)
    }

    // MARK: - Ratchet sessions

    public func loadSession(peerUserId: String, peerDeviceId: String) throws -> DoubleRatchetSession? {
        try read { dbc in
            guard let row = try Row.fetchOne(
                dbc,
                sql: "SELECT state FROM ratchetSession WHERE peerUserId = ? AND peerDeviceId = ?",
                arguments: [peerUserId, peerDeviceId]
            ) else { return nil }
            let sealed: Data = row["state"]
            let plain = try StateCrypto.open(sealed, with: master)
            return try JSONDecoder().decode(DoubleRatchetSession.self, from: plain)
        }
    }

    public func saveSession(_ session: DoubleRatchetSession, peerUserId: String,
                            peerDeviceId: String) throws {
        let plain = try JSONEncoder().encode(session)
        let sealed = try StateCrypto.seal(plain, with: master)
        try write { dbc in
            try dbc.execute(
                sql: """
                INSERT INTO ratchetSession (peerUserId, peerDeviceId, state)
                VALUES (?,?,?)
                ON CONFLICT(peerUserId, peerDeviceId) DO UPDATE SET state = excluded.state
                """,
                arguments: [peerUserId, peerDeviceId, sealed]
            )
        }
    }

    /// Archived sessions no longer encrypt anything, but they still open late messages
    /// that were sent into the old session after a divergence, a glare or a reinstall.
    private static let maxArchived = 5

    public func archivedSessions(peerUserId: String, peerDeviceId: String) throws -> [DoubleRatchetSession] {
        try read { dbc in
            guard let row = try Row.fetchOne(
                dbc, sql: "SELECT archived FROM ratchetSession WHERE peerUserId = ? AND peerDeviceId = ?",
                arguments: [peerUserId, peerDeviceId]),
                let blob = row["archived"] as Data? else { return [] }
            let plain = try StateCrypto.open(blob, with: master)
            return (try? JSONDecoder().decode([DoubleRatchetSession].self, from: plain)) ?? []
        }
    }

    public func saveArchivedSessions(_ sessions: [DoubleRatchetSession],
                                     peerUserId: String, peerDeviceId: String) throws {
        let trimmed = Array(sessions.suffix(Self.maxArchived))
        let sealed = try StateCrypto.seal(try JSONEncoder().encode(trimmed), with: master)
        try write { dbc in
            try dbc.execute(
                sql: "UPDATE ratchetSession SET archived = ? WHERE peerUserId = ? AND peerDeviceId = ?",
                arguments: [sealed, peerUserId, peerDeviceId])
        }
    }

    /// Marks that the next message to this peer starts the session over. Set when their
    /// messages open under neither the active session nor the archived ones: a fresh
    /// X3DH from a new bundle is then the only way back into step.
    public func requestSessionReset(peerUserId: String) throws {
        try write { dbc in
            try KVRow(key: "sessionReset:" + peerUserId, value: "1").save(dbc)
        }
    }

    /// Clears the mark and reports whether it was there.
    public func consumeSessionReset(peerUserId: String) throws -> Bool {
        try write { dbc in
            try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: ["sessionReset:" + peerUserId])
            return dbc.changesCount > 0
        }
    }

    /// Moves the active session into the archive, ahead of replacing it with a new one.
    public func archiveCurrentSession(peerUserId: String, peerDeviceId: String) throws {
        guard let current = try loadSession(peerUserId: peerUserId, peerDeviceId: peerDeviceId) else { return }
        var archive = try archivedSessions(peerUserId: peerUserId, peerDeviceId: peerDeviceId)
        archive.append(current)
        try saveArchivedSessions(archive, peerUserId: peerUserId, peerDeviceId: peerDeviceId)
    }

    // MARK: - Sender keys

    /// This device's chain for a chat: the state, the addresses that confirmed the
    /// distribution, and the addresses it went out to without a confirmation yet
    /// (address to the moment it was sent).
    public func loadSenderKeyOut(chatId: String) throws -> (SenderKeyState, Set<String>, [String: Double])? {
        try read { dbc in
            guard let row = try Row.fetchOne(
                dbc, sql: "SELECT state, distributedTo, attemptedAt FROM senderKeyOut WHERE chatId = ?",
                arguments: [chatId]
            ) else { return nil }
            let plain = try StateCrypto.open(row["state"], with: master)
            let state = try JSONDecoder().decode(SenderKeyState.self, from: plain)
            let dist = (try? JSONDecoder().decode(Set<String>.self,
                                                  from: Data((row["distributedTo"] as String).utf8))) ?? []
            let attempted = (try? JSONDecoder().decode([String: Double].self,
                                                       from: Data((row["attemptedAt"] as String).utf8))) ?? [:]
            return (state, dist, attempted)
        }
    }

    public func saveSenderKeyOut(chatId: String, state: SenderKeyState,
                                 distributedTo: Set<String>, attemptedAt: [String: Double]) throws {
        let plain = try JSONEncoder().encode(state)
        let sealed = try StateCrypto.seal(plain, with: master)
        let dist = String(data: try JSONEncoder().encode(distributedTo), encoding: .utf8)!
        let attempted = String(data: try JSONEncoder().encode(attemptedAt), encoding: .utf8)!
        try write { dbc in
            try dbc.execute(
                sql: """
                INSERT INTO senderKeyOut (chatId, state, distributedTo, attemptedAt) VALUES (?,?,?,?)
                ON CONFLICT(chatId) DO UPDATE SET state = excluded.state,
                  distributedTo = excluded.distributedTo, attemptedAt = excluded.attemptedAt
                """,
                arguments: [chatId, sealed, dist, attempted]
            )
        }
    }

    public func deleteSenderKeyOut(chatId: String) throws {
        _ = try write { dbc in
            try dbc.execute(sql: "DELETE FROM senderKeyOut WHERE chatId = ?", arguments: [chatId])
        }
    }

    public func deleteAllSenderKeyOut() throws {
        _ = try write { dbc in
            try dbc.execute(sql: "DELETE FROM senderKeyOut")
        }
    }

    public func loadSenderKeyIn(chatId: String, senderUserId: String, keyId: String) throws -> SenderKeyReceiver? {
        try read { dbc in
            guard let row = try Row.fetchOne(
                dbc,
                sql: "SELECT state FROM senderKeyIn WHERE chatId = ? AND senderUserId = ? AND keyId = ?",
                arguments: [chatId, senderUserId, keyId]
            ) else { return nil }
            let plain = try StateCrypto.open(row["state"], with: master)
            return try JSONDecoder().decode(SenderKeyReceiver.self, from: plain)
        }
    }

    public func saveSenderKeyIn(chatId: String, senderUserId: String, keyId: String, state: SenderKeyReceiver) throws {
        let plain = try JSONEncoder().encode(state)
        let sealed = try StateCrypto.seal(plain, with: master)
        try write { dbc in
            try dbc.execute(
                sql: """
                INSERT INTO senderKeyIn (chatId, senderUserId, keyId, state) VALUES (?,?,?,?)
                ON CONFLICT(chatId, senderUserId, keyId) DO UPDATE SET state = excluded.state
                """,
                arguments: [chatId, senderUserId, keyId, sealed]
            )
        }
    }

    // MARK: - TOFU

    public enum TrustResult { case firstUse, trusted, changed(previous: String) }

    /// Checks a peer's identity key, trust on first use.
    public func checkTrust(userId: String, identitySigning: String) throws -> TrustResult {
        try write { dbc in
            if let row = try Row.fetchOne(
                dbc, sql: "SELECT identitySigning FROM trustedIdentity WHERE userId = ?",
                arguments: [userId]
            ) {
                let known: String = row["identitySigning"]
                if known == identitySigning { return .trusted }
                try dbc.execute(
                    sql: "UPDATE trustedIdentity SET changedPending = ? WHERE userId = ?",
                    arguments: [identitySigning, userId]
                )
                return .changed(previous: known)
            }
            try dbc.execute(
                sql: "INSERT INTO trustedIdentity (userId, identitySigning, verified) VALUES (?,?,0)",
                arguments: [userId, identitySigning]
            )
            return .firstUse
        }
    }

    /// The user explicitly accepted the new key after the warning.
    public func acceptChangedKey(userId: String) throws {
        try write { dbc in
            try dbc.execute(
                sql: """
                UPDATE trustedIdentity SET identitySigning = COALESCE(changedPending, identitySigning),
                changedPending = NULL, verified = 0 WHERE userId = ?
                """,
                arguments: [userId]
            )
        }
    }

    public func markVerified(userId: String, verified: Bool) throws {
        try write { dbc in
            try dbc.execute(sql: "UPDATE trustedIdentity SET verified = ? WHERE userId = ?",
                            arguments: [verified, userId])
        }
    }
}
