import Foundation

/// Which server this install talks to, shared with the notification extension.
///
/// The app takes the address from its build environment; the extension is
/// launched by the system and sees none of it, so the app writes the address
/// into the app group and the extension reads it there.
public enum ServerEndpoint {
    public static let key = "server.baseURL"

    public static func base(in defaults: UserDefaults) -> URL? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return URL(string: raw)
    }

    public static func setBase(_ url: URL, in defaults: UserDefaults) {
        defaults.set(url.absoluteString, forKey: key)
    }
}
