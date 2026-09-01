import SwiftUI
import MsngrCore

@main
struct MsngrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState.shared
    @StateObject private var theme = ThemeStore.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        AppNet.install()
        TypeScale.start()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if app.session != nil {
                    RootView()
                        .environmentObject(app)
                } else {
                    RegisterView()
                        .environmentObject(app)
                }
                // the call rides over the whole app and under the safety screens;
                // minimized it folds into the floating tile and the app is usable
                if app.callState.phase != .idle {
                    if app.callMinimized {
                        CallPipTile()
                            .environmentObject(app)
                            .transition(.opacity)
                            .zIndex(7)
                    } else {
                        CallScreenView()
                            .environmentObject(app)
                            .transition(.opacity)
                            .zIndex(7)
                    }
                }
                // revoked device: a dead end on top of everything but the passcode
                if app.sessionRevoked {
                    SessionEndedView()
                        .environmentObject(app)
                        .transition(.opacity)
                        .zIndex(8)
                }
                // build fell behind the server or its own storage
                if let reason = app.outdated {
                    AppOutdatedView(reason: reason)
                        .environmentObject(app)
                        .transition(.opacity)
                        .zIndex(8)
                }
                if app.isLocked {
                    LockScreenView()
                        .environmentObject(app)
                        .transition(.opacity)
                        .zIndex(10)
                }
                if app.obscured && !app.isLocked {
                    PrivacyShieldView().zIndex(9)
                }
            }
            .tint(Theme.accent)
            .pulseConsoleOnShake()
            .animation(.easeOut(duration: 0.2), value: app.isLocked)
            .animation(.easeOut(duration: 0.2), value: app.callState.phase != .idle)
            .onChange(of: scenePhase) { _, phase in
                app.scenePhaseChanged(phase)
            }
        }
    }
}

final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The Mac menu bar (and the iPad shortcut HUD) carries the commands the
    /// keyboard already answers. Each item names a selector the responder
    /// chain resolves — the focused composer implements them — so an item is
    /// enabled exactly where its key already works. The keystrokes themselves
    /// stay in the composer's keyCommands; the menu adds the clickable face.
    override func buildMenu(with builder: UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        var previous = UIMenu.Identifier.edit
        for menu in Self.keyboardMenus() {
            builder.insertSibling(menu, afterMenu: previous)
            previous = menu.identifier
        }
    }

    /// The menus buildMenu inserts, on their own so a test can hold them.
    static func keyboardMenus() -> [UIMenu] {
        let chats = UIMenu(title: String(localized: "Chats"), options: [], children: [
            UICommand(title: String(localized: "Next chat"),
                      action: #selector(GrowingTextView.PasteAwareTextView.switchChatForward)),
            UICommand(title: String(localized: "Previous chat"),
                      action: #selector(GrowingTextView.PasteAwareTextView.switchChatBackward)),
            UICommand(title: String(localized: "Edit last message"),
                      action: #selector(GrowingTextView.PasteAwareTextView.editLastMessage)),
        ])
        let format = UIMenu(title: String(localized: "Format"), options: [], children: [
            UICommand(title: String(localized: "Bold"),
                      action: #selector(GrowingTextView.PasteAwareTextView.makeBold)),
            UICommand(title: String(localized: "Italic"),
                      action: #selector(GrowingTextView.PasteAwareTextView.makeItalic)),
            UICommand(title: String(localized: "Link"),
                      action: #selector(GrowingTextView.PasteAwareTextView.makeLink)),
        ])
        return [chats, format]
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AppState.shared.registerPushToken(token) }
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        NotificationCoordinator.shared.setup()
        return true
    }
}
