import SwiftUI

/// Единая точка стиля: цвета, шрифты, кривые анимаций. Ничего линейного по умолчанию.
enum Theme {
    // Бабблы
    static let outgoingBubble = Color(light: Color(red: 0.88, green: 0.97, blue: 0.79),
                                      dark: Color(red: 0.18, green: 0.35, blue: 0.20))
    static let incomingBubble = Color(light: .white, dark: Color(white: 0.16))
    static let chatBackground = Color(light: Color(red: 0.85, green: 0.88, blue: 0.80),
                                      dark: Color(white: 0.06))
    static let accent = Color(red: 0.22, green: 0.56, blue: 0.94)
    static let readTick = Color(red: 0.30, green: 0.69, blue: 0.31)

    // Анимации: единые spring-константы
    static let springFast = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.84)
    static let springSlow = Animation.spring(response: 0.55, dampingFraction: 0.86)

    static let bubbleCorner: CGFloat = 17
    static let bubbleMaxWidthRatio: CGFloat = 0.76
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Детерминированный хэш для выбора цвета аватара/имени.
/// Swift рандомизирует hashValue между запусками, из-за чего цвета «прыгали»
/// после каждого перезапуска приложения.
enum StableHash {
    static func index(_ string: String, modulo: Int) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV-1a
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(max(modulo, 1)))
    }
}

enum Haptics {
    static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func rigid() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}
