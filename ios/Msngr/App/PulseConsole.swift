import SwiftUI
import MsngrCore
#if DEBUG
import Pulse
import PulseUI
import PulseProxy
#endif

/// The URLSession the app's HTTP goes through. In debug builds Pulse records
/// every request on it; release builds get the plain shared session and none
/// of the Pulse code below exists.
enum AppNet {
    /// A request that hangs is worse than one that fails: a stale connection —
    /// the far side of a tunnel restarted, a network switch the socket never
    /// noticed — swallows requests silently, and the default 60 s is a frozen
    /// screen. 15 s turns it into a failure the caller's retry can act on.
    private static var config: URLSessionConfiguration {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return cfg
    }

    #if DEBUG
    /// Recording rides on PulseProxy's session swizzle (`NetworkLogger.enableProxy()`
    /// in `install`): the delegate-based hook cannot see async/await requests
    /// finish — Pulse's own docs mark URLSessionProxyDelegate as not working with
    /// the async URLSession APIs, and every request showed as pending forever.
    static let session = URLSession(configuration: config)
    /// Called once at startup, before the first request.
    static func install() {
        NetworkLogger.enableProxy()
    }
    #else
    static let session = URLSession(configuration: config)
    static func install() {}
    #endif

    /// The one way the app builds its API client, so every caller records alike.
    static func client(token: String? = nil) -> APIClient {
        APIClient(baseURL: AppState.httpBase, token: token, session: session)
    }
}

#if DEBUG
/// A shake anywhere opens the Pulse console over whatever is on screen.
/// UIKit delivers the shake to the window, and an override in an extension is
/// the one place the SwiftUI app lifecycle lets us catch it.
extension UIWindow {
    open override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        super.motionEnded(motion, with: event)
        if motion == .motionShake {
            NotificationCenter.default.post(name: .msngrShake, object: nil)
        }
    }
}

extension Notification.Name {
    static let msngrShake = Notification.Name("msngr.shake")
}

private struct PulseConsoleHost: ViewModifier {
    // "-msngr.console" opens it on launch: a shake cannot be sent into a
    // simulator from outside, and the live check needs a way in
    @State private var shown = ProcessInfo.processInfo.arguments.contains("-msngr.console")
    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .msngrShake)) { _ in shown = true }
            .sheet(isPresented: $shown) {
                NavigationView { ConsoleView() }
            }
    }
}

extension View {
    func pulseConsoleOnShake() -> some View { modifier(PulseConsoleHost()) }
}
#else
extension View {
    func pulseConsoleOnShake() -> some View { self }
}
#endif
