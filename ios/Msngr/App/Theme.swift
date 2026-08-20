import SwiftUI

/// App palette: one coherent set of every colour role.
/// The user's choice is kept in UserDefaults("palette"), see `ThemeStore`.
enum Palette: String, CaseIterable, Identifiable {
    /// Neutral light background, blue outgoing, grey incoming.
    case imessage
    /// White background with a faint tint, mint-sage outgoing, blue accent.
    case telegram
    /// Cream background, indigo outgoing, orange accent.
    case graphite

    var id: String { rawValue }

    /// Preset name shown in settings.
    var title: String {
        switch self {
        case .imessage: return "iMessage"
        case .telegram: return "Telegram"
        case .graphite: return String(localized: "Graphite")
        }
    }

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

    var incomingBubble: Color {
        switch self {
        case .imessage: return Color(light: Color(red: 0.91, green: 0.91, blue: 0.93),
                                     dark: Color(white: 0.16))
        case .telegram: return Color(light: .white, dark: Color(white: 0.16))
        case .graphite: return Color(light: .white, dark: Color(white: 0.16))
        }
    }

    /// Accent: buttons, links, replies, controls.
    var accent: Color {
        switch self {
        case .imessage: return Color(red: 0.17, green: 0.48, blue: 0.92)
        case .telegram: return Color(red: 0.16, green: 0.56, blue: 0.89)
        case .graphite: return Color(red: 0.90, green: 0.49, blue: 0.13)
        }
    }

    /// Read tick outside a bubble (chat list).
    var readTick: Color {
        switch self {
        case .imessage: return Color(red: 0.17, green: 0.48, blue: 0.92)
        case .telegram: return Color(red: 0.13, green: 0.59, blue: 0.42)
        case .graphite: return Color(red: 0.90, green: 0.49, blue: 0.13)
        }
    }

    var outgoingText: Color {
        switch self {
        case .imessage: return .white
        case .telegram: return Color(light: Color(white: 0.08), dark: .white)
        case .graphite: return Color(red: 0.98, green: 0.97, blue: 0.94)
        }
    }

    /// Timestamp and unread ticks on an outgoing bubble.
    var outgoingMeta: Color {
        switch self {
        case .imessage: return Color.white.opacity(0.65)
        case .telegram: return Color(light: Color(red: 0.28, green: 0.47, blue: 0.36),
                                     dark: Color(red: 0.55, green: 0.75, blue: 0.63))
        case .graphite: return Color(red: 0.78, green: 0.80, blue: 0.92)
        }
    }

    /// Read tick on an outgoing bubble. Colour is the only thing that separates a
    /// read message from a delivered one, so it carries a hue of its own rather
    /// than a brighter shade of the meta colour: against a blue or a green bubble
    /// a lighter version of the same green reads as the same tick.
    var outgoingTickRead: Color {
        switch self {
        case .imessage: return Color(red: 0.42, green: 0.93, blue: 1.0)
        case .telegram: return Color(light: Color(red: 0.05, green: 0.45, blue: 0.82),
                                     dark: Color(red: 0.45, green: 0.85, blue: 1.0))
        case .graphite: return Color(red: 1.0, green: 0.73, blue: 0.35)
        }
    }

    /// Label on a filled accent control. Every accent here is dark enough to
    /// carry white except the graphite orange, where white holds only 2.9:1;
    /// the dark label on it holds 6.0:1.
    var accentLabel: Color {
        switch self {
        case .imessage, .telegram: return .white
        case .graphite: return Color(red: 0.16, green: 0.09, blue: 0.02)
        }
    }
}

/// Palette selection: persisted in UserDefaults "palette", observable from SwiftUI.
/// Switching the palette clears the bubble image cache and is broadcast to every
/// open screen.
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
    /// Preferred content size category changed: every measured layout is stale.
    static let typeScaleChanged = Notification.Name("typeScaleChanged")
}

// MARK: - Type scale

/// One named text role: a base size at the default content size category, the
/// system style it grows along with, and a ceiling that keeps fixed-height
/// chrome (navigation bar, list row, badge) from overflowing at accessibility
/// sizes.
struct TextRole: Hashable {
    var size: CGFloat
    var weight: UIFont.Weight = .regular
    var relativeTo: UIFont.TextStyle = .body
    var design: UIFontDescriptor.SystemDesign = .default
    var italic: Bool = false
    var maxSize: CGFloat

    var uiFont: UIFont { TypeScale.font(self) }
    var font: Font { Font(uiFont) }
    /// Height of one line at the current scale: cells and capsules size from
    /// this instead of a hardcoded number.
    var lineHeight: CGFloat { uiFont.lineHeight }
}

/// Dynamic Type, resolved once per content size category.
///
/// Bubble layout is measured away from the view hierarchy (and off the main
/// thread), so the category is snapshotted here rather than read from
/// `UITraitCollection.current` at measure time. `start()` keeps the snapshot in
/// step with the system and tells the app to re-measure.
enum TypeScale {
    nonisolated(unsafe) private(set) static var category: UIContentSizeCategory = .large
    nonisolated(unsafe) private static var cache: [TextRole: UIFont] = [:]
    private static let lock = NSLock()

    static func start() {
        category = UIScreen.main.traitCollection.preferredContentSizeCategory
        NotificationCenter.default.addObserver(
            forName: UIContentSizeCategory.didChangeNotification, object: nil, queue: .main
        ) { note in
            let next = note.userInfo?[UIContentSizeCategory.newValueUserInfoKey] as? UIContentSizeCategory
                ?? UIScreen.main.traitCollection.preferredContentSizeCategory
            guard next != category else { return }
            apply(next)
        }
    }

    /// Swaps the scale and invalidates everything measured against the old one.
    static func apply(_ next: UIContentSizeCategory) {
        category = next
        lock.lock()
        cache.removeAll()
        lock.unlock()
        BubbleLayout.clearCache()
        NotificationCenter.default.post(name: .typeScaleChanged, object: nil)
    }

    static func font(_ role: TextRole) -> UIFont {
        lock.lock()
        if let hit = cache[role] { lock.unlock(); return hit }
        lock.unlock()
        let made = resolve(role, category: category)
        lock.lock()
        cache[role] = made
        lock.unlock()
        return made
    }

    static func resolve(_ role: TextRole, category: UIContentSizeCategory) -> UIFont {
        var base = UIFont.systemFont(ofSize: role.size, weight: role.weight)
        var descriptor = base.fontDescriptor
        if role.design != .default, let d = descriptor.withDesign(role.design) { descriptor = d }
        if role.italic, let d = descriptor.withSymbolicTraits(.traitItalic) { descriptor = d }
        base = UIFont(descriptor: descriptor, size: role.size)
        return UIFontMetrics(forTextStyle: role.relativeTo)
            .scaledFont(for: base, maximumPointSize: role.maxSize,
                        compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
    }

    /// Scales a fixed dimension (icon box, capsule height, inset) the same way
    /// the text next to it scales, so the two never drift apart.
    static func scaled(_ value: CGFloat, relativeTo style: UIFont.TextStyle = .body,
                       max limit: CGFloat) -> CGFloat {
        min(limit, UIFontMetrics(forTextStyle: style).scaledValue(
            for: value, compatibleWith: UITraitCollection(preferredContentSizeCategory: category)))
    }
}

extension Theme {
    /// Every text size in the app. Call sites name a role; nobody spells a
    /// point size, so changing the scale is one edit here.
    enum Text {
        // Feed
        static let bubble = TextRole(size: 17, relativeTo: .body, maxSize: 53)
        static let bubbleTime = TextRole(size: 12, relativeTo: .caption1, maxSize: 26)
        static let bubbleName = TextRole(size: 14, weight: .semibold, relativeTo: .footnote, maxSize: 30)
        static let bubbleForward = TextRole(size: 13, relativeTo: .footnote, italic: true, maxSize: 28)
        static let replyAuthor = TextRole(size: 13, weight: .semibold, relativeTo: .footnote, maxSize: 28)
        static let replyText = TextRole(size: 13, relativeTo: .footnote, maxSize: 28)
        static let reaction = TextRole(size: 14, relativeTo: .footnote, maxSize: 26)
        static let feedNote = TextRole(size: 13, weight: .medium, relativeTo: .footnote, maxSize: 26)
        static let voiceDuration = TextRole(size: 11, relativeTo: .caption2, maxSize: 22)
        static let fileName = TextRole(size: 15, weight: .medium, relativeTo: .subheadline, maxSize: 32)
        /// Code spans and blocks inside a bubble: two points under body text.
        static let bubbleCode = TextRole(size: 15, relativeTo: .body, design: .monospaced, maxSize: 48)

        // Chat header
        /// The inline navigation bar keeps its height at every text size, so
        /// title and subtitle stop well before the accessibility sizes do.
        static let headerTitle = TextRole(size: 16, weight: .semibold, relativeTo: .subheadline, maxSize: 19)
        static let headerSubtitle = TextRole(size: 12, relativeTo: .caption1, maxSize: 13)

        // Chat list row
        static let rowTitle = TextRole(size: 16, weight: .semibold, relativeTo: .subheadline, maxSize: 30)
        static let rowPreview = TextRole(size: 15, relativeTo: .subheadline, maxSize: 28)
        static let rowTime = TextRole(size: 13, relativeTo: .caption1, maxSize: 20)
        static let rowBadge = TextRole(size: 13, weight: .semibold, relativeTo: .caption1, maxSize: 20)
        static let tabBadge = TextRole(size: 12, weight: .semibold, relativeTo: .caption1, maxSize: 18)
        static let folderTab = TextRole(size: 15, relativeTo: .subheadline, maxSize: 24)
        static let folderTabActive = TextRole(size: 15, weight: .semibold, relativeTo: .subheadline, maxSize: 24)
        /// The @handle next to a display name in people search: the one thing
        /// that tells apart two accounts sharing the same display name, so it
        /// reads close to the name itself rather than as a caption.
        static let personHandle = TextRole(size: 15, weight: .medium, relativeTo: .subheadline, maxSize: 30)

        // Composer
        static let input = TextRole(size: 17, relativeTo: .body, maxSize: 40)
        static let recordTimer = TextRole(size: 16, relativeTo: .body, design: .monospaced, maxSize: 28)

        // General chrome
        static let body = TextRole(size: 16, relativeTo: .body, maxSize: 34)
        static let caption = TextRole(size: 12, relativeTo: .caption1, maxSize: 22)
        static let controlTitle = TextRole(size: 17, weight: .semibold, relativeTo: .body, maxSize: 30)
        static let menuItem = TextRole(size: 17, relativeTo: .body, maxSize: 30)
        /// Oversized tappable glyph: keypad digit, quick-reaction emoji.
        static let largeControl = TextRole(size: 28, relativeTo: .title2, maxSize: 40)
        static let monospacedTag = TextRole(size: 11, relativeTo: .caption2, design: .monospaced, maxSize: 18)
        /// Label burned into a fixed-size thumbnail: grows barely, or it covers
        /// the picture it annotates.
        static let thumbnailCaption = TextRole(size: 11, weight: .medium, relativeTo: .caption2, maxSize: 15)
    }

    /// Control glyphs (SF Symbols in buttons) grow with text but stop early:
    /// the bar they sit in has a fixed height.
    static func glyph(_ size: CGFloat, max limit: CGFloat) -> Font {
        .system(size: TypeScale.scaled(size, max: limit))
    }
}

/// Applies a named role and re-resolves it when the reader changes their text
/// size: reading `dynamicTypeSize` is what makes SwiftUI rebuild the body.
private struct TextRoleModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize
    let role: TextRole

    func body(content: Content) -> some View {
        content.font(Font(TypeScale.resolve(role, category: typeSize.contentSizeCategory)))
    }
}

extension View {
    func textRole(_ role: TextRole) -> some View { modifier(TextRoleModifier(role: role)) }
}

extension DynamicTypeSize {
    /// Scales a fixed dimension against the size this view is rendering at.
    func scaled(_ value: CGFloat, relativeTo style: UIFont.TextStyle = .body,
                max limit: CGFloat) -> CGFloat {
        min(limit, UIFontMetrics(forTextStyle: style).scaledValue(
            for: value, compatibleWith: UITraitCollection(preferredContentSizeCategory: contentSizeCategory)))
    }

    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: return .extraSmall
        case .small: return .small
        case .medium: return .medium
        case .large: return .large
        case .xLarge: return .extraLarge
        case .xxLarge: return .extraExtraLarge
        case .xxxLarge: return .extraExtraExtraLarge
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        @unknown default: return .large
        }
    }
}

/// Single point of style: colours, fonts, animation curves. Nothing linear by default.
enum Theme {
    /// The palette the user picked in settings.
    static var palette: Palette { ThemeStore.shared.palette }

    // Colour roles
    static var chatBackground: Color { palette.chatBackground }
    static var outgoingBubble: Color { palette.outgoingBubble }
    static var incomingBubble: Color { palette.incomingBubble }
    static var accent: Color { palette.accent }
    static var readTick: Color { palette.readTick }
    static var outgoingText: Color { palette.outgoingText }
    static var outgoingMeta: Color { palette.outgoingMeta }
    static var outgoingTickRead: Color { palette.outgoingTickRead }

    /// A large decorative glyph on an empty screen. A single opacity cannot
    /// serve both appearances: the accent at 55% sits well on a light ground and
    /// turns to mud on the dark one, where the screen is nearly black and the
    /// glyph has nothing left to stand on.
    static var decorativeGlyph: Color {
        Color(light: palette.accent.opacity(0.55), dark: palette.accent.opacity(0.92))
    }

    // A filled action button, the one thing a screen is for.
    static var controlFill: Color { palette.accent }
    static var controlLabel: Color { palette.accentLabel }
    /// A control that cannot be used yet is a neutral surface rather than a
    /// pale accent: the accent at 40% left its white label 1.4:1 in the light
    /// appearance, and the button read as painted over rather than as waiting.
    /// These greys hold 5.3:1 light and 5.1:1 dark.
    static var controlFillDisabled: Color {
        Color(light: Color(white: 0.88), dark: Color(white: 0.24))
    }
    static var controlLabelDisabled: Color {
        Color(light: Color(white: 0.35), dark: Color(white: 0.70))
    }

    // Animations: one set of spring constants
    static let springFast = Animation.spring(response: 0.35, dampingFraction: 0.82)
    static let spring = Animation.spring(response: 0.45, dampingFraction: 0.84)
    static let springSlow = Animation.spring(response: 0.55, dampingFraction: 0.86)

    static let bubbleCorner: CGFloat = 17
    static let bubbleMaxWidthRatio: CGFloat = 0.76
}

/// The filled action a screen is built around: "Create account", "Next",
/// "Log in". The box grows with the label instead of holding 48 pt, so an
/// accessibility size wraps the text rather than clipping it.
struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Filled(configuration: configuration) }

    private struct Filled: View {
        // `isEnabled` only reaches a ButtonStyle through a view of its own.
        @Environment(\.isEnabled) private var enabled
        @Environment(\.dynamicTypeSize) private var typeSize
        let configuration: Configuration

        var body: some View {
            let label = enabled ? Theme.controlLabel : Theme.controlLabelDisabled
            configuration.label
                .textRole(Theme.Text.controlTitle)
                .foregroundStyle(label)
                .tint(label)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, typeSize.scaled(12, max: 20))
                .frame(maxWidth: .infinity)
                .frame(minHeight: typeSize.scaled(48, max: 78))
                .background(enabled ? Theme.controlFill : Theme.controlFillDisabled,
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .opacity(configuration.isPressed ? 0.82 : 1)
        }
    }
}

extension ButtonStyle where Self == PrimaryActionButtonStyle {
    static var primaryAction: PrimaryActionButtonStyle { PrimaryActionButtonStyle() }
}

extension Color {
    init(light: Color, dark: Color) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

/// Deterministic hash for picking an avatar or name colour.
/// Swift randomises hashValue between launches, so a name would land on a
/// different colour after every restart of the app.
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
