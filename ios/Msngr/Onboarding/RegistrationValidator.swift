import Foundation

/// Validation rules for the registration form.
enum RegistrationValidator {
    static func isValidUsername(_ username: String) -> Bool {
        username.range(of: "^[a-zA-Z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isValidName(_ name: String) -> Bool {
        trimmedName(name).count >= 3
    }
}
