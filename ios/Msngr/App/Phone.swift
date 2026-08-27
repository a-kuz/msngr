import Foundation
import CryptoKit

/// The phone number as discovery sees it: E.164 on the device, SHA-256 of it
/// on the wire. The raw number never leaves the device.
enum Phone {
    /// Digits and a leading plus; the Russian 8-prefixed form is folded into +7.
    /// Anything that does not normalize to a plausible international number
    /// comes back empty.
    static func e164(_ raw: String) -> String {
        var digits = raw.filter { $0.isNumber || $0 == "+" }
        if digits.hasPrefix("8") && digits.count == 11 {
            digits = "+7" + digits.dropFirst() // Russian format
        }
        guard digits.hasPrefix("+"), digits.count >= 11 else { return "" }
        return digits
    }

    /// The hash the server stores and matches by.
    static func hash(_ e164: String) -> String {
        SHA256.hash(data: Data(e164.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
