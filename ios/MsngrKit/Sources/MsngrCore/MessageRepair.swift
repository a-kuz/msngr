import Foundation

/// Policy for messages this device could not read.
///
/// An unreadable message is a defect, so the device works on it by itself: the
/// envelope is kept and replayed, and when a replay cannot help, the sender is
/// asked for a fresh copy. Everything here is a pure decision over the counters
/// stored on the `pendingDecrypt` row — the schedule is testable without a
/// network or a clock.
public enum MessageRepair {
    /// Failures a later replay can still resolve on its own: the key may be in
    /// flight (group message ahead of its sender key, ratchet message ahead of
    /// its prekey) or the state was momentarily unavailable.
    public static let retryableReasons: Set<String> = ["no_sender_key", "no_session", "exception"]

    /// Failures no replay resolves: the ciphertext this device holds will never
    /// open. Only a fresh copy from the sender can close them.
    public static let terminalReasons: Set<String> = [
        "bad_envelope", "bad_box", "bad_skm", "bad_pk", "unknown_mode",
        "pk_decrypt_failed", "empty_inner", "no_ciphertext", "unbound_identity",
        stalePrekeyReason,
    ]

    /// The envelope is written in a format newer than this build reads.
    public static let envelopeAheadReason = "envelope_too_new"

    /// A prekey envelope whose handshake this device has already run. The
    /// session it would have built is the one already in place.
    public static let stalePrekeyReason = "stale_pk"

    /// Failures a fresh copy cannot fix. The sender would answer in the format
    /// this device already cannot read, or — for a handshake already run — with
    /// nothing this device is missing. The envelope is kept and replayed
    /// instead, and no repair attempt is spent on it.
    public static let unrepairableReasons: Set<String> = [envelopeAheadReason, stalePrekeyReason]

    /// Failures that say the pairwise session itself is unusable: the request
    /// for a fresh copy would travel in that same session, so it is sent after
    /// the session is rebuilt from scratch.
    public static let sessionReasons: Set<String> = [
        "no_session", "pk_decrypt_failed", "bad_pk", "no_ciphertext", "exception",
    ]

    /// Shortest wait between two replays of the same envelope by the sweep.
    /// The replay that follows a freshly arrived key is not held back by it:
    /// that one runs the moment the key lands.
    public static let retryInterval: TimeInterval = 20

    /// How long a retryable failure is left to resolve by itself before the
    /// sender is asked. A terminal failure does not wait.
    public static let repairGrace: TimeInterval = 60

    /// Repair requests spent on one message before the device stops asking.
    public static let maxAttempts = 5

    /// Wait before repair attempt n+1, counted from the previous request.
    static let backoff: [TimeInterval] = [30, 120, 600, 1800, 7200]

    /// Age at which a kept envelope stops being useful: its session is long
    /// gone and every repair attempt has been spent.
    public static let envelopeTTL: TimeInterval = 7 * 24 * 3600

    /// Wait before a sender key that was handed out but never confirmed is
    /// handed out again.
    public static let redistributeAfter: TimeInterval = 60

    public static func retryDue(lastTriedAt: Double, now: Double) -> Bool {
        now - lastTriedAt >= retryInterval
    }

    /// True when the sender should be asked now: the failure is terminal (or has
    /// outlived the grace period), attempts are left, and the wait after the
    /// previous request is over.
    public static func repairDue(reason: String?, firstSeenAt: Double, repairAttempts: Int,
                                 repairAskedAt: Double, now: Double) -> Bool {
        if let reason, unrepairableReasons.contains(reason) { return false }
        guard repairAttempts < maxAttempts else { return false }
        let terminal = reason.map { !retryableReasons.contains($0) } ?? false
        guard terminal || now - firstSeenAt >= repairGrace else { return false }
        guard repairAttempts > 0 else { return true }
        return now - repairAskedAt >= backoff[min(repairAttempts, backoff.count) - 1]
    }

    /// True when the envelope is past its lifetime with every attempt spent.
    /// An envelope no repair can fix spends none, so it is kept: it is the only
    /// copy this device has, and a build that knows its format opens it.
    public static func expired(firstSeenAt: Double, repairAttempts: Int, now: Double) -> Bool {
        repairAttempts >= maxAttempts && now - firstSeenAt >= envelopeTTL
    }

    /// Deterministic id of a repair request, so a request repeated within the
    /// same attempt is deduplicated by the server instead of reaching the sender
    /// twice, while the next attempt still gets through.
    public static func requestId(msgId: String, attempt: Int) -> String {
        "rq:\(msgId):\(attempt)"
    }

    /// Deterministic id of the sender's answer, same reasoning.
    public static func replyId(msgId: String, attempt: Int) -> String {
        "rp:\(msgId):\(attempt)"
    }
}
