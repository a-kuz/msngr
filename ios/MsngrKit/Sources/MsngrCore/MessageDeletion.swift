import Foundation

/// The rule shared by every client: which deletion is worth offering at all.
/// Lives in the core because iOS and macOS show the same menu over the same
/// messages.
public enum MessageDeletion {
    /// "Delete for everyone" is available only when every selected message is the
    /// user's own: someone else's the server tombstones for a group admin alone, in
    /// a direct chat such a request silently does nothing, and the message would
    /// disappear on this device only.
    public static func canDeleteForAll(_ selected: [Message]) -> Bool {
        !selected.isEmpty && selected.allSatisfy(\.isOutgoing)
    }
}
