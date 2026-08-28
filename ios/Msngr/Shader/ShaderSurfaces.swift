import Foundation
import Combine
import GRDB
import MsngrCore

/// The shaders the user put on this device's own surfaces: a chat's
/// background, the effect played on a send or a reaction, the sticker pack.
/// All of it is local: nothing here goes to the server or to another device.
/// Backgrounds and effects live in `kv`, stickers in `savedSticker`.
@MainActor
final class ShaderSurfaces: ObservableObject {
    static let shared = ShaderSurfaces()

    enum Effect: String, CaseIterable {
        case send, reaction
    }

    /// chatId → the background document
    @Published private(set) var backgrounds: [String: ShaderDocument] = [:]
    /// an effect → the document replacing the bundled one
    @Published private(set) var effects: [Effect: ShaderDocument] = [:]
    /// The bundled effects play unless switched off here.
    @Published var effectsEnabled: Bool {
        didSet { UserDefaults.standard.set(effectsEnabled, forKey: "shaderEffectsEnabled") }
    }
    /// the sticker pack, newest first
    @Published private(set) var stickers: [ShaderDocument] = []

    private static let backgroundPrefix = "shader.background:"
    private static let effectPrefix = "shader.effect:"
    private var loaded = false

    private init() {
        effectsEnabled = UserDefaults.standard.object(forKey: "shaderEffectsEnabled") as? Bool ?? true
    }

    private var db: DatabaseQueue? { AppState.shared.db }

    /// Reads everything once the database is open; safe to call again.
    func load() {
        guard !loaded, let db else { return }
        loaded = true
        let dec = JSONDecoder()
        if let rows = try? db.read({ dbc in
            try KVRow.fetchAll(dbc, sql: "SELECT key, value FROM kv WHERE key LIKE 'shader.%'")
        }) {
            for row in rows {
                guard let doc = try? dec.decode(ShaderDocument.self, from: Data(row.value.utf8)) else { continue }
                if row.key.hasPrefix(Self.backgroundPrefix) {
                    backgrounds[String(row.key.dropFirst(Self.backgroundPrefix.count))] = doc
                } else if row.key.hasPrefix(Self.effectPrefix),
                          let e = Effect(rawValue: String(row.key.dropFirst(Self.effectPrefix.count))) {
                    effects[e] = doc
                }
            }
        }
        seedStickers(db)
        if let rows = try? db.read({ dbc in
            try String.fetchAll(dbc, sql: "SELECT document FROM savedSticker ORDER BY addedAt DESC")
        }) {
            stickers = rows.compactMap { try? dec.decode(ShaderDocument.self, from: Data($0.utf8)) }
        }
    }

    /// Puts the bundled stickers into a pack that has never had them, once per
    /// database: a sticker the user removed stays removed.
    private func seedStickers(_ db: DatabaseQueue) {
        let key = "shader.stickers.seeded"
        let seeded = (try? db.read { dbc in
            try String.fetchOne(dbc, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }) != nil
        if seeded { return }
        // oldest first, so the pack reads in the bundled order under the user's own
        let base = Date().timeIntervalSince1970 - Double(ShaderStickers.bundled.count)
        try? db.write { dbc in
            for (i, doc) in ShaderStickers.bundled.enumerated() {
                guard let json = Self.json(doc) else { continue }
                try dbc.execute(sql: "INSERT OR IGNORE INTO savedSticker (hash, document, addedAt) VALUES (?, ?, ?)",
                                arguments: [doc.contentHash, json, base + Double(ShaderStickers.bundled.count - i)])
            }
            try KVRow(key: key, value: "1").save(dbc)
        }
    }

    // MARK: - Backgrounds

    func background(for chatId: String) -> ShaderDocument? {
        load()
        return backgrounds[chatId]
    }

    func setBackground(_ doc: ShaderDocument?, for chatId: String) {
        load()
        backgrounds[chatId] = doc
        write(key: Self.backgroundPrefix + chatId, doc)
    }

    // MARK: - Effects

    func effect(_ e: Effect) -> ShaderDocument? {
        load()
        return effects[e]
    }

    func setEffect(_ doc: ShaderDocument?, for e: Effect) {
        load()
        effects[e] = doc
        write(key: Self.effectPrefix + e.rawValue, doc)
    }

    // MARK: - Stickers

    func hasSticker(_ doc: ShaderDocument) -> Bool {
        load()
        let h = doc.contentHash
        return stickers.contains { $0.contentHash == h }
    }

    func addSticker(_ doc: ShaderDocument) {
        load()
        guard !hasSticker(doc) else { return }
        stickers.insert(doc, at: 0)
        guard let db, let json = Self.json(doc) else { return }
        let hash = doc.contentHash
        try? db.write { dbc in
            try dbc.execute(sql: "INSERT OR REPLACE INTO savedSticker (hash, document, addedAt) VALUES (?, ?, ?)",
                            arguments: [hash, json, Date().timeIntervalSince1970])
        }
    }

    func removeSticker(_ doc: ShaderDocument) {
        load()
        let h = doc.contentHash
        stickers.removeAll { $0.contentHash == h }
        guard let db else { return }
        try? db.write { dbc in
            try dbc.execute(sql: "DELETE FROM savedSticker WHERE hash = ?", arguments: [h])
        }
    }

    // MARK: -

    private func write(key: String, _ doc: ShaderDocument?) {
        guard let db else { return }
        let json = doc.flatMap(Self.json)
        try? db.write { dbc in
            if let json {
                try KVRow(key: key, value: json).save(dbc)
            } else {
                try dbc.execute(sql: "DELETE FROM kv WHERE key = ?", arguments: [key])
            }
        }
    }

    private static func json(_ doc: ShaderDocument) -> String? {
        (try? JSONEncoder().encode(doc)).flatMap { String(data: $0, encoding: .utf8) }
    }
}
