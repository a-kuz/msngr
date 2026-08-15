import Foundation
import MsngrCore

/// Общий контейнер приложения и NSE.
enum AppGroup {
    static let identifier = AppContainer.appGroupIdentifier
    static let keychainGroup = "ai.enface.msngr.shared"
    /// Settings both the app and the extension read.
    static let defaults = UserDefaults(suiteName: identifier) ?? .standard
}
