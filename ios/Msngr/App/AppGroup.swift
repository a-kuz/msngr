import Foundation
import MsngrCore

/// App group shared by the app and the notification service extension.
enum AppGroup {
    static let identifier = AppContainer.appGroupIdentifier
    static let keychainGroup = "msngr.msngr.shared"
    /// Settings both the app and the extension read.
    static let defaults = UserDefaults(suiteName: identifier) ?? .standard
}
