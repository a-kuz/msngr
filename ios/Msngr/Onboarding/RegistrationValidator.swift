import Foundation

/// Правила валидации формы регистрации.
enum RegistrationValidator {
    /// Юзернейм: латиница, цифры, подчёркивание; 3–32 символа.
    static func isValidUsername(_ username: String) -> Bool {
        username.range(of: "^[a-zA-Z0-9_]{3,32}$", options: .regularExpression) != nil
    }

    /// Имя после обрезки пробелов/переводов строк.
    static func trimmedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Имя обязательно: минимум 3 символа после обрезки пробелов.
    static func isValidName(_ name: String) -> Bool {
        trimmedName(name).count >= 3
    }
}
