import Foundation

/// State of the unread-count banner inside an open chat.
/// It lives from the moment the chat is entered (in ChatViewModel); the rules are:
/// - entering with unread messages puts the banner above the first of them;
/// - messages arriving while the chat is visible raise the active banner's counter;
/// - sending something or reacting removes the banner;
/// - the screen going into the background or under the shade removes the banner, and
///   messages arriving meanwhile pile up and come back as a new banner on return.
struct UnreadMarkerState: Equatable {
    /// seq of the first unread message, the banner stands above it; nil means no banner
    private(set) var anchorSeq: Int?
    private(set) var count = 0
    private var obscured = false
    /// piled up while obscured: the seq of the first arrival and how many there were
    private var pendingFirstSeq: Int?
    private var pendingCount = 0

    var isActive: Bool { anchorSeq != nil && count > 0 }

    /// Entering the chat: the anchor is the seq right after the last read one.
    mutating func enterChat(unreadCount: Int, myReadUpTo: Int) {
        guard unreadCount > 0 else { return }
        anchorSeq = myReadUpTo + 1
        count = unreadCount
    }

    /// An incoming message from the peer with a new seq.
    mutating func incoming(seq: Int) {
        if obscured {
            if pendingFirstSeq == nil { pendingFirstSeq = seq }
            pendingCount += 1
        } else if isActive {
            count += 1
        }
    }

    /// Sending something or reacting takes the banner away.
    mutating func dismiss() {
        anchorSeq = nil
        count = 0
    }

    /// The screen went into the background or under the shade: the banner goes, later
    /// arrivals pile up.
    mutating func becameObscured() {
        obscured = true
        dismiss()
        pendingFirstSeq = nil
        pendingCount = 0
    }

    /// Back on screen: what piled up while away becomes a new banner.
    mutating func becameActive() {
        obscured = false
        if pendingCount > 0 {
            anchorSeq = pendingFirstSeq
            count = pendingCount
        }
        pendingFirstSeq = nil
        pendingCount = 0
    }
}
