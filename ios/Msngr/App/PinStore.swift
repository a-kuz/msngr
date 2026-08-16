import Foundation
import CryptoKit

/// Passcode kept as SHA-256(salt + pin); the pin itself is never stored.
enum PinStore {
    private static let defaults = UserDefaults.standard
    static let autolockInterval: TimeInterval = 30

    static func hasPin() -> Bool {
        defaults.data(forKey: "pin.hash") != nil
    }

    static func setPin(_ pin: String) {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let hash = Data(SHA256.hash(data: salt + Data(pin.utf8)))
        defaults.set(salt, forKey: "pin.salt")
        defaults.set(hash, forKey: "pin.hash")
    }

    static func verify(_ pin: String) -> Bool {
        guard let salt = defaults.data(forKey: "pin.salt"),
              let stored = defaults.data(forKey: "pin.hash") else { return false }
        return Data(SHA256.hash(data: salt + Data(pin.utf8))) == stored
    }

    static func removePin() {
        defaults.removeObject(forKey: "pin.salt")
        defaults.removeObject(forKey: "pin.hash")
    }

    static func biometricsEnabled() -> Bool {
        defaults.bool(forKey: "pin.biometrics")
    }
    static func setBiometricsEnabled(_ on: Bool) {
        defaults.set(on, forKey: "pin.biometrics")
    }
}
