import Foundation
import MsngrCore

/// The user's choice for how much decrypted media the cache may hold. Stored
/// in UserDefaults; AppState applies it to MediaManager at startup, the
/// settings screen on change. Everything evicted is re-downloadable.
enum MediaCacheCeiling: String, CaseIterable, Identifiable {
    case small, medium, gigabyte, large, unlimited

    static let key = "mediaCacheCeiling"
    var id: String { rawValue }

    var bytes: Int64 {
        switch self {
        case .small: 100 << 20
        case .medium: 500 << 20
        case .gigabyte: 1 << 30
        case .large: 5 << 30
        case .unlimited: 0
        }
    }

    var label: String {
        switch self {
        case .small: String(localized: "100 MB")
        case .medium: String(localized: "500 MB")
        case .gigabyte: String(localized: "1 GB")
        case .large: String(localized: "5 GB")
        case .unlimited: String(localized: "No limit")
        }
    }

    static var current: MediaCacheCeiling {
        UserDefaults.standard.string(forKey: key).flatMap(MediaCacheCeiling.init) ?? .gigabyte
    }
}
