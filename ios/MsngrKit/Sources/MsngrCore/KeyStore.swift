import Foundation
import CryptoKit
import GRDB
import MsngrCrypto

/// Поставщик мастер-ключа для шифрования крипто-состояний в БД.
public protocol MasterKeyProvider: Sendable {
    func masterKey() throws -> SymmetricKey
}

/// Keychain-реализация: ключ генерируется один раз, kSecAttrAccessibleAfterFirstUnlock
/// (нужен NSE для расшифровки пушей при заблокированном экране).
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

/// Для тестов: фиксированный ключ в памяти.
public struct StaticMasterKey: MasterKeyProvider {
    let key: SymmetricKey
    public init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    public func masterKey() throws -> SymmetricKey { key }
}

/// Мастер-ключ в защищённом файле внутри общего контейнера (app group).
/// Приложение и NSE читают один и тот же ключ без keychain-sharing.
/// Файл защищён Data Protection (completeUntilFirstUserAuthentication — доступен
/// NSE при заблокированном экране после первой разблокировки).
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

/// Шифрование блобов состояния (ratchet, sender keys) мастер-ключом.
enum StateCrypto {
    static func seal(_ data: Data, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.seal(data, using: key).combined
    }
    static func open(_ data: Data, with key: SymmetricKey) throws -> Data {
        try ChaChaPoly.open(ChaChaPoly.SealedBox(combined: data), using: key)
    }
}

/// Собственные ключи устройства: identity в Keychain-совместимом хранилище (kv,
/// зашифровано мастер-ключом), приватные prekey — там же.
public final class IdentityStore: @unchecked Sendable {
    private let db: DatabaseQueue
    private let master: SymmetricKey

    public init(db: DatabaseQueue, masterKeyProvider: MasterKeyProvider) throws {
        self.db = db
        self.master = try masterKeyProvider.masterKey()
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
        try db.read { dbc in
            guard let row = try KVRow.fetchOne(dbc, key: key),
                  let sealed = Data(base64Encoded: row.value) else { return nil }
            let plain = try StateCrypto.open(sealed, with: master)
            return try JSONDecoder().decode(T.self, from: plain)
        }
    }

    private func saveBlob<T: Codable>(_ key: String, _ value: T) throws {
        let plain = try JSONEncoder().encode(value)
        let sealed = try StateCrypto.seal(plain, with: master)
        try db.write { dbc in
            try KVRow(key: key, value: sealed.base64EncodedString()).save(dbc)
        }
    }

    /// Возвращает (или создаёт) identity устройства.
    public func identity() throws -> IdentityKeyPair {
        if let stored = try loadBlob("identity", as: StoredIdentity.self) {
            return try IdentityKeyPair(dhRaw: stored.dhRaw, signingRaw: stored.signingRaw)
        }
        let pair = IdentityKeyPair()
        try saveBlob("identity", StoredIdentity(dhRaw: pair.dh.rawRepresentation,
                                                signingRaw: pair.signing.rawRepresentation))
        return pair
    }

    /// Генерация prekey-набора для регистрации; приватные части сохраняются.
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

    /// Пополнение one-time prekeys (когда сервер расходует).
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

    /// One-time prekey одноразовый: удалить после использования.
    public func consumeOneTimePrekey(id: UInt32) throws {
        guard var stored = try loadBlob("prekeys", as: StoredPrekeys.self) else { return }
        stored.oneTime.removeValue(forKey: id)
        try saveBlob("prekeys", stored)
    }

    // MARK: - Ratchet-сессии

    public func loadSession(peerUserId: String, peerDeviceId: String) throws -> DoubleRatchetSession? {
        try db.read { dbc in
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
                            peerDeviceId: String, theirIdentityDH: String) throws {
        let plain = try JSONEncoder().encode(session)
        let sealed = try StateCrypto.seal(plain, with: master)
        try db.write { dbc in
            try dbc.execute(
                sql: """
                INSERT INTO ratchetSession (peerUserId, peerDeviceId, state, theirIdentityDH)
                VALUES (?,?,?,?)
                ON CONFLICT(peerUserId, peerDeviceId) DO UPDATE SET state = excluded.state
                """,
                arguments: [peerUserId, peerDeviceId, sealed, theirIdentityDH]
            )
        }
    }

    /// Архивные сессии: ими больше не шифруем, но ещё расшифровываем «догоняющие»
    /// сообщения, отправленные в старую сессию (рассинхрон, glare, переустановка).
    private static let maxArchived = 5

    public func archivedSessions(peerUserId: String, peerDeviceId: String) throws -> [DoubleRatchetSession] {
        try db.read { dbc in
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
        try db.write { dbc in
            try dbc.execute(
                sql: "UPDATE ratchetSession SET archived = ? WHERE peerUserId = ? AND peerDeviceId = ?",
                arguments: [sealed, peerUserId, peerDeviceId])
        }
    }

    /// Пометка «следующее сообщение этому собеседнику начинает сессию заново».
    /// Ставится, когда его сообщения не открываются ни активной сессией, ни
    /// архивными: X3DH из свежего бандла — единственный способ сойтись.
    public func requestSessionReset(peerUserId: String) throws {
        try db.write { dbc in
            try KVRow(key: "sessionReset:" + peerUserId, value: "1").save(dbc)
        }
    }

    /// Снимает пометку и сообщает, была ли она.
    public func consumeSessionReset(peerUserId: String) throws -> Bool {
        try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: ["sessionReset:" + peerUserId])
            return dbc.changesCount > 0
        }
    }

    /// Текущую активную сессию — в архив (перед заменой на новую).
    public func archiveCurrentSession(peerUserId: String, peerDeviceId: String) throws {
        guard let current = try loadSession(peerUserId: peerUserId, peerDeviceId: peerDeviceId) else { return }
        var archive = try archivedSessions(peerUserId: peerUserId, peerDeviceId: peerDeviceId)
        archive.append(current)
        try saveArchivedSessions(archive, peerUserId: peerUserId, peerDeviceId: peerDeviceId)
    }

    // MARK: - Sender keys

    /// Своя цепочка на чат: состояние, адреса с подтверждённой раздачей и
    /// адреса, которым раздача ушла и подтверждения ещё нет (адрес → момент).
    public func loadSenderKeyOut(chatId: String) throws -> (SenderKeyState, Set<String>, [String: Double])? {
        try db.read { dbc in
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
        try db.write { dbc in
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
        _ = try db.write { dbc in
            try dbc.execute(sql: "DELETE FROM senderKeyOut WHERE chatId = ?", arguments: [chatId])
        }
    }

    public func loadSenderKeyIn(chatId: String, senderUserId: String, keyId: String) throws -> SenderKeyReceiver? {
        try db.read { dbc in
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
        try db.write { dbc in
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

    /// Проверка identity-ключа собеседника (TOFU).
    public func checkTrust(userId: String, identitySigning: String) throws -> TrustResult {
        try db.write { dbc in
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

    /// Есть ли непринятая смена ключа у собеседника.
    public func pendingKeyChange(userId: String) throws -> Bool {
        try db.read { dbc in
            let row = try Row.fetchOne(
                dbc, sql: "SELECT changedPending FROM trustedIdentity WHERE userId = ?",
                arguments: [userId])
            return (row?["changedPending"] as String?) != nil
        }
    }

    /// Пользователь явно принял новый ключ после предупреждения.
    public func acceptChangedKey(userId: String) throws {
        try db.write { dbc in
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
        try db.write { dbc in
            try dbc.execute(sql: "UPDATE trustedIdentity SET verified = ? WHERE userId = ?",
                            arguments: [verified, userId])
        }
    }
}
