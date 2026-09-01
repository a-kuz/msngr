import Foundation
import MsngrCore

/// `msngr://join/<code>` — the link a group hands out and the one a channel's
/// audience arrives by. Opening it joins and lands the reader in the chat; a
/// link that is already spent (the chat is in the list) just opens it.
enum InviteLink {
    static func code(in url: URL) -> String? {
        guard url.scheme == "msngr" else { return nil }
        // msngr://join/<code>: the host carries "join" and the path the code
        let parts = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" })
        guard parts.count == 2, parts[0] == "join", !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// Joins by the code and opens the chat. A repeat of the same link is not
    /// an error: the server answers with the chat that is already ours.
    @MainActor
    static func open(_ url: URL) {
        guard let code = code(in: url) else { return }
        Task {
            let app = AppState.shared
            guard app.session != nil, let chatId = try? await app.api.join(code: code) else { return }
            try? await app.engine.refreshSnapshot()
            NotificationCenter.default.post(name: .openChatRequested, object: chatId)
        }
    }
}
