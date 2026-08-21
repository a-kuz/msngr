import Foundation

/// The module's string table, reachable from outside the module: unit tests
/// compare against the same catalog the code reads, in whatever language the
/// host runs.
public enum CoreStrings {
    public static func string(_ key: String.LocalizationValue) -> String {
        String(localized: key, bundle: .module)
    }
}
