import Foundation

/// Measurement trace for a run on a large chat: every SQL statement the local
/// database executes, plus the spans the screens mark on the main thread.
///
/// Off unless the process is launched with `MSNGR_PERF=1`; then the events go
/// as JSON lines into `perf-trace.jsonl` in the storage root, where the host
/// reads them out of the simulator container. Timestamps are wall clock, so a
/// scenario is cut out of the trace by the time the host performed it.
///
/// The first statement of every distinct SQL text carries the call stack that
/// issued it: that is what turns a count into a place in the code.
public final class PerfTrace: @unchecked Sendable {
    public static let shared = PerfTrace()

    /// One recorded event. Serialised on the writer queue, not at the call site.
    private struct Entry {
        let t: Double
        let kind: String
        let name: String
        let duration: Double
        let onMain: Bool
        let stack: [String]?
        let info: [String: Double]?
    }

    public let isEnabled: Bool
    private let lock = NSLock()
    private var buffer: [Entry] = []
    private var seen: Set<String> = []
    private var handle: FileHandle?
    private let io = DispatchQueue(label: "ai.enface.msngr.perftrace")

    private init() {
        isEnabled = ProcessInfo.processInfo.environment["MSNGR_PERF"] == "1"
        guard isEnabled else { return }
        let root = (AppContainer.groupLocation() ?? AppContainer.legacyLocation()).root
        let url = root.appendingPathComponent("perf-trace.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        io.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
    }

    /// A statement the database executed, with the time SQLite spent on it.
    public func sql(_ text: String, duration: Double) {
        guard isEnabled else { return }
        let normalized = text.replacingOccurrences(of: "\\s+", with: " ",
                                                   options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var stack: [String]?
        lock.lock()
        let isNew = seen.insert(normalized).inserted
        lock.unlock()
        if isNew { stack = Self.callers() }
        append(Entry(t: Date().timeIntervalSince1970, kind: "sql", name: normalized,
                     duration: duration, onMain: Thread.isMainThread, stack: stack, info: nil))
    }

    /// A named span of work, in seconds, with whatever counts describe its size.
    public func span(_ name: String, duration: Double, info: [String: Double]? = nil) {
        guard isEnabled else { return }
        append(Entry(t: Date().timeIntervalSince1970, kind: "span", name: name,
                     duration: duration, onMain: Thread.isMainThread, stack: nil, info: info))
    }

    /// A point in time: a frame, a tap, the start of a scenario.
    public func mark(_ name: String, info: [String: Double]? = nil) {
        guard isEnabled else { return }
        append(Entry(t: Date().timeIntervalSince1970, kind: "mark", name: name,
                     duration: 0, onMain: Thread.isMainThread, stack: nil, info: info))
    }

    /// Measures the body and records it as a span.
    public func measure<T>(_ name: String, info: [String: Double]? = nil,
                           _ body: () throws -> T) rethrows -> T {
        guard isEnabled else { return try body() }
        let start = CFAbsoluteTimeGetCurrent()
        defer { span(name, duration: CFAbsoluteTimeGetCurrent() - start, info: info) }
        return try body()
    }

    /// Frames of the app's own code, nearest first. Everything links into one
    /// binary, so the frames are told apart by the module in the mangled name:
    /// the database library and the trace machinery are the plumbing between the
    /// statement and the place that asked for it, and only that place is an answer.
    private static func callers() -> [String] {
        Thread.callStackSymbols
            .filter { $0.contains("Msngr") && !$0.contains("PerfTrace")
                && !$0.contains("$s4GRDB") && !$0.contains("$s10Foundation") }
            .prefix(10)
            .map { symbol in
                // "  3   MsngrCore  0x0000 $s9MsngrCore... + 120" — the mangled
                // name in the middle is the only part worth keeping
                let parts = symbol.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count > 3 else { return symbol }
                return parts[1] + " " + parts[3...].joined(separator: " ")
            }
    }

    private func append(_ entry: Entry) {
        lock.lock()
        buffer.append(entry)
        let full = buffer.count >= 400
        lock.unlock()
        if full { io.async { [weak self] in self?.flush() } }
    }

    private func tick() {
        flush()
        io.asyncAfter(deadline: .now() + 1) { [weak self] in self?.tick() }
    }

    /// Writes what has piled up. Called on the writer queue, so the measured
    /// threads pay only for appending to the buffer.
    public func flush() {
        lock.lock()
        let entries = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !entries.isEmpty, let handle else { return }
        var out = Data()
        for e in entries {
            var object: [String: Any] = ["t": e.t, "k": e.kind, "n": e.name,
                                         "d": e.duration, "m": e.onMain]
            if let stack = e.stack { object["s"] = stack }
            if let info = e.info { object["i"] = info }
            guard let line = try? JSONSerialization.data(withJSONObject: object) else { continue }
            out.append(line)
            out.append(0x0A)
        }
        try? handle.write(contentsOf: out)
    }
}
