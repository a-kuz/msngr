import Foundation

/// What an account's handle and name may be. Registration and the profile
/// screen ask the same questions here, and the server repeats them on
/// `/api/register`, `/api/profile` and `/api/username`.
enum AccountValidator {
    static let usernameMinLength = 3
    static let usernameMaxLength = 32
    static let nameMaxLength = 64

    static func isValidUsername(_ username: String) -> Bool {
        username.range(of: "^[a-zA-Z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A name is required: it is the only place a person's own spelling of
    /// themselves lives, since a handle holds no Cyrillic. One character is
    /// enough — «Ян» and «Li» are names, and a floor of three refused them.
    static func isValidName(_ name: String) -> Bool {
        (1...nameMaxLength).contains(trimmedName(name).count)
    }

    /// What is wrong with the name as typed, or nil while it is fine. Silence
    /// on an empty field: the screen has not been filled in yet, it is not
    /// wrong yet.
    static func nameHint(_ name: String) -> String? {
        let trimmed = trimmedName(name)
        if trimmed.isEmpty { return nil }
        return trimmed.count > nameMaxLength
            ? String(localized: "Name — at most \(nameMaxLength) characters") : nil
    }

    static func usernameHint(_ username: String) -> String? {
        if username.isEmpty || isValidUsername(username) { return nil }
        return String(localized: "Username — \(usernameMinLength) to \(usernameMaxLength) characters: latin letters, digits and _")
    }
}
