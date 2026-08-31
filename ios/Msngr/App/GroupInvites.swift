import Foundation
import MsngrCore

/// Someone whose privacy keeps them out of a straight group add still gets
/// the invitation — as a message with the group's invite link, sent into the
/// direct chat by the person who tried to add them. Sending the invitation
/// is exactly what that person meant by the add, so it needs no extra tap.
enum GroupInvites {
    static func deliver(groupChatId: String, title: String?, to userIds: [String]) async {
        guard !userIds.isEmpty else { return }
        let app = AppState.shared
        guard let invite = try? await app.api.createInvite(groupChatId) else { return }
        let text: String
        if let title, !title.isEmpty {
            text = String(format: String(localized: "Invitation to «%@»: %@"), title, invite.link)
        } else {
            text = String(format: String(localized: "Invitation to a group: %@"), invite.link)
        }
        for userId in userIds {
            guard let directId = await DirectChat.open(userId: userId) else { continue }
            var content = ContentPayload(kind: "text")
            content.text = text
            try? await app.engine.enqueue(content: content, chatId: directId)
        }
    }
}
