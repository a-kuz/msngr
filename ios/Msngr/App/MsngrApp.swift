import SwiftUI
import MsngrCore

@main
struct MsngrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var app = AppState.shared
    @Environment(\.scenePhase) private var scenePhase

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
                // пин-код: оверлей поверх всего
                if app.isLocked {
                    LockScreenView()
                        .environmentObject(app)
                        .transition(.opacity)
                        .zIndex(10)
                }
                // блюр в app switcher
                if app.obscured && !app.isLocked {
                    PrivacyShieldView().zIndex(9)
                }
            }
            .animation(.easeOut(duration: 0.2), value: app.isLocked)
            .onChange(of: scenePhase) { _, phase in
                app.scenePhaseChanged(phase)
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
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
