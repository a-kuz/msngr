import Foundation

/// Category identifiers stamped on message notifications. The app registers the
/// category with its actions and handles the responses; the extension stamps the
/// same identifier on the banners it builds, so a push banner carries the same
/// actions as a local one.
public enum NotificationCategory {
    /// An incoming content message: quick reply and mute.
    public static let message = "message"
}
