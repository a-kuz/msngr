import Foundation

/// Trace of the notification service extension.
///
/// The extension runs in a process of its own, which the debugger and the app
/// console do not reach, and the system decides how many of the pushes of a
/// burst it is willing to service at all. The journal is the only way to learn
/// what actually ran: every entry into `didReceive`, every answer and every
/// expiry is appended to a file in the app group, and counting the lines after
/// a known burst gives the number of invocations the system granted.
public final class NotificationJournal: @unchecked Sendable {
    public enum Phase: String, Equatable, Sendable {
        /// `didReceive` was entered.
        case received
        /// The message the push carried was written into the database — or was
        /// not, and the detail says why. The hardware run reads this line to
        /// tell a banner that was only shown from one that was also kept.
        case stored
        /// The content handler was called.
        case answered
        /// The extension ran out of its budget.
        case expired
    }

    public struct Entry: Equatable, Sendable {
        public var at: Double
        public var phase: Phase
        public var chatId: String
        public var seq: Int
        /// Outcome of an answer, or whatever the phase has to add.
        public var detail: String

        public init(at: Double, phase: Phase, chatId: String, seq: Int, detail: String = "") {
            self.at = at
            self.phase = phase
            self.chatId = chatId
            self.seq = seq
            self.detail = detail
        }
    }

    public static let fileName = "nse-journal.log"
    /// Size at which the oldest half of the journal is dropped.
    public static let sizeLimit = 128 * 1024

    private let url: URL
    private let limit: Int
    private let lock = NSLock()

    public init(url: URL, limit: Int = NotificationJournal.sizeLimit) {
        self.url = url
        self.limit = limit
    }

    /// Journal of the shared container; nil when the group is unavailable.
    public static func shared() -> NotificationJournal? {
        AppContainer.groupLocation().map { NotificationJournal(url: $0.nseJournalURL) }
    }

    public func record(_ phase: Phase, chatId: String, seq: Int, detail: String = "",
                       at: Double = Date().timeIntervalSince1970) {
        let line = Self.line(Entry(at: at, phase: phase, chatId: chatId, seq: seq, detail: detail))
        lock.lock()
        defer { lock.unlock() }
        append(line)
        trimIfNeeded()
    }

    public func entries() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8)
        else { return [] }
        return Self.parse(text)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Format

    static func line(_ entry: Entry) -> String {
        let fields = [String(format: "%.3f", entry.at), entry.phase.rawValue,
                      entry.chatId, String(entry.seq), entry.detail]
        return fields.joined(separator: "\t") + "\n"
    }

    public static func parse(_ text: String) -> [Entry] {
        text.split(separator: "\n").compactMap { row in
            let f = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 4, let at = Double(f[0]), let phase = Phase(rawValue: String(f[1])),
                  let seq = Int(f[3]) else { return nil }
            return Entry(at: at, phase: phase, chatId: String(f[2]), seq: seq,
                         detail: f.count > 4 ? String(f[4]) : "")
        }
    }

    // MARK: - File

    private func append(_ line: String) {
        let data = Data(line.utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? data.write(to: url)
    }

    /// Keeps the newest half: the journal answers what just happened, and an
    /// extension has no room to carry a growing file.
    private func trimIfNeeded() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? Int, size > limit else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let tail = data.suffix(limit / 2)
        guard let cut = tail.firstIndex(of: UInt8(ascii: "\n")) else { return }
        try? Data(tail[tail.index(after: cut)...]).write(to: url)
    }
}
