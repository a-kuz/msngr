import Foundation
import Combine

/// How far the attachments of a message still on their way out have got:
/// preparation on this device (a video transcode) and the upload after it, as
/// one fraction per album slot. The feed draws it over the tile while the
/// message is in the sending state. Nothing here is stored: a relaunch starts
/// the outbox again and the fraction with it.
public final class MediaProgress: ObservableObject, @unchecked Sendable {
    public static let shared = MediaProgress()

    public init() {}

    /// Fractions in 0…1 by `key(_:index:)`, published on the main thread.
    @Published public private(set) var fractions: [String: Double] = [:]
    private var shadow: [String: Double] = [:]
    private let lock = NSLock()

    public static func key(_ clientMsgId: String, index: Int?) -> String {
        "\(clientMsgId)#\(index ?? 0)"
    }

    public func fraction(_ clientMsgId: String, index: Int?) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return shadow[Self.key(clientMsgId, index: index)]
    }

    /// Steps under a hundredth are dropped: an upload delegate reports every
    /// packet, and the feed has nothing to redraw for them.
    public func set(_ clientMsgId: String, index: Int?, fraction: Double) {
        let k = Self.key(clientMsgId, index: index)
        let value = max(0, min(1, fraction))
        lock.lock()
        if let old = shadow[k], abs(old - value) < 0.01, value < 1 { lock.unlock(); return }
        shadow[k] = value
        lock.unlock()
        publish { $0[k] = value }
    }

    /// The message was acknowledged, or failed for good: its slots go.
    public func clear(_ clientMsgId: String) {
        let prefix = clientMsgId + "#"
        lock.lock()
        shadow = shadow.filter { !$0.key.hasPrefix(prefix) }
        lock.unlock()
        publish { $0 = $0.filter { !$0.key.hasPrefix(prefix) } }
    }

    private func publish(_ change: @escaping (inout [String: Double]) -> Void) {
        if Thread.isMainThread {
            change(&fractions)
        } else {
            DispatchQueue.main.async { change(&self.fractions) }
        }
    }
}
