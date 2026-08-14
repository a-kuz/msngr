import SwiftUI

/// Палитра приложения: согласованный набор всех цветовых ролей.
/// Выбор пользователя хранится в UserDefaults("palette") — см. `ThemeStore`.
enum Palette: String, CaseIterable, Identifiable {
    /// Нейтральный светлый фон, синий исходящий, серый входящий.
    case imessage
    /// Белый фон с лёгким тоном, мятно-шалфейный исходящий, синий акцент.
    case telegram
    /// Кремовый фон, индиго исходящий, оранжевый акцент.
    case graphite

    var id: String { rawValue }

    /// Название пресета в настройках.
    var title: String {
        switch self {
        case .imessage: return "iMessage"
        case .telegram: return "Telegram"
        case .graphite: return "Графит"
        }
    }

    /// Фон ленты сообщений.
    var chatBackground: Color {
        switch self {
        case .imessage: return Color(light: Color(red: 0.96, green: 0.96, blue: 0.97),
                                     dark: Color(white: 0.06))
        case .telegram: return Color(light: Color(red: 0.945, green: 0.96, blue: 0.935),
                                     dark: Color(white: 0.06))
        case .graphite: return Color(light: Color(red: 0.96, green: 0.94, blue: 0.89),
                                     dark: Color(red: 0.09, green: 0.09, blue: 0.11))
        }
    }

    /// Баббл исходящего сообщения.
    var outgoingBubble: Color {
        switch self {
        case .imessage: return Color(light: Color(red: 0.17, green: 0.48, blue: 0.92),
                                     dark: Color(red: 0.15, green: 0.41, blue: 0.82))
        case .telegram: return Color(light: Color(red: 0.84, green: 0.95, blue: 0.88),
                                     dark: Color(red: 0.13, green: 0.30, blue: 0.24))
        case .graphite: return Color(light: Color(red: 0.22, green: 0.25, blue: 0.45),
                                     dark: Color(red: 0.20, green: 0.23, blue: 0.40))
        }
    }

    /// Баббл входящего сообщения.
    var incomingBubble: Color {
        switch self {
        case .imessage: return Color(light: Color(red: 0.91, green: 0.91, blue: 0.93),
                                     dark: Color(white: 0.16))
        case .telegram: return Color(light: .white, dark: Color(white: 0.16))
        case .graphite: return Color(light: .white, dark: Color(white: 0.16))
        }
    }

    /// Акцент: кнопки, ссылки, реплаи, элементы управления.
    var accent: Color {
        switch self {
        case .imessage: return Color(red: 0.17, green: 0.48, blue: 0.92)
        case .telegram: return Color(red: 0.16, green: 0.56, blue: 0.89)
        case .graphite: return Color(red: 0.90, green: 0.49, blue: 0.13)
        }
    }

    /// Галочка «прочитано» вне баббла (список чатов).
    var readTick: Color {
        switch self {
        case .imessage: return Color(red: 0.17, green: 0.48, blue: 0.92)
        case .telegram: return Color(red: 0.13, green: 0.59, blue: 0.42)
        case .graphite: return Color(red: 0.90, green: 0.49, blue: 0.13)
        }
    }

    /// Основной текст на исходящем баббле.
    var outgoingText: Color {
        switch self {
        case .imessage: return .white
        case .telegram: return Color(light: Color(white: 0.08), dark: .white)
        case .graphite: return Color(red: 0.98, green: 0.97, blue: 0.94)
        }
    }

    /// Время и непрочитанные галочки на исходящем баббле.
    var outgoingMeta: Color {
        switch self {
        case .imessage: return Color.white.opacity(0.75)
        case .telegram: return Color(light: Color(red: 0.28, green: 0.47, blue: 0.36),
                                     dark: Color(red: 0.55, green: 0.75, blue: 0.63))
        case .graphite: return Color(red: 0.78, green: 0.80, blue: 0.92)
        }
    }

    /// Галочка «прочитано» на исходящем баббле.
    var outgoingTickRead: Color {
        switch self {
        case .imessage: return .white
        case .telegram: return Color(red: 0.13, green: 0.59, blue: 0.42)
        case .graphite: return Color(red: 1.0, green: 0.73, blue: 0.35)
        }
    }
}

/// Выбор палитры: персистентный (UserDefaults "palette"), наблюдаемый из SwiftUI.
/// Смена палитры сбрасывает кэш картинок бабблов и рассылается всем открытым экранам.
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published var palette: Palette {
        didSet {
            guard palette != oldValue else { return }
            UserDefaults.standard.set(palette.rawValue, forKey: "palette")
            BubbleBackground.clearCache()
            NotificationCenter.default.post(name: .paletteChanged, object: nil)
        }
    }

    private init() {
        palette = Palette(rawValue: UserDefaults.standard.string(forKey: "palette") ?? "") ?? .graphite
    }
}

extension Notification.Name {
    static let paletteChanged = Notification.Name("paletteChanged")
}

/// Единая точка стиля: цвета, шрифты, кривые анимаций. Ничего линейного по умолчанию.
enum Theme {
    /// Текущая палитра — выбранная пользователем в настройках.
    static var palette: Palette { ThemeStore.shared.palette }

    // Роли цветов
    static var chatBackground: Color { palette.chatBackground }
    static var outgoingBubble: Color { palette.outgoingBubble }
    static var incomingBubble: Color { palette.incomingBubble }
    static var accent: Color { palette.accent }
    static var readTick: Color { palette.readTick }
    static var outgoingText: Color { palette.outgoingText }
    static var outgoingMeta: Color { palette.outgoingMeta }
    static var outgoingTickRead: Color { palette.outgoingTickRead }

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
