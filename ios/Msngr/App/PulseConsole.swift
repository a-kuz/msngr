import SwiftUI
#if DEBUG
import Pulse
import PulseUI
#endif

/// The URLSession the app's HTTP goes through. In debug builds Pulse records
/// every request on it; release builds get the plain shared session and none
/// of the Pulse code below exists.
enum AppNet {
    #if DEBUG
    static let session = URLSession(
        configuration: .default,
        delegate: URLSessionProxyDelegate(),
        delegateQueue: nil)
    #else
    static let session = URLSession.shared
    #endif
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
