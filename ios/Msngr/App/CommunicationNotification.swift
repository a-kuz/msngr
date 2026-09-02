import Foundation
import Intents
import UserNotifications
import MsngrCore

/// Message notification shaped as a Communication Notification: the sender's
/// round avatar in place of the app icon and their name in the title. Shared
/// by the app (a local notification while the socket is up) and the extension
/// (the mutated push).
///
/// SpringBoard draws the picture from `INSendMessageIntent`, and only when all
/// three conditions hold: the `com.apple.developer.usernotifications.communication`
/// entitlement, `INSendMessageIntent` in `NSUserActivityTypes`, and
/// `INPerson(isMe: true)` among the recipients. Miss any of them and
/// `updating(from:)` returns the content unchanged without throwing, so the
/// banner comes out as the plain one with the app icon.
enum CommunicationNotification {

    /// Avatars live as files in the container shared with the extension:
    /// `avatars/<avatarId>.jpg`. Nil when the picture is not on disk.
    static func cachedAvatarFile(_ avatarId: String?) -> URL? {
        guard let avatarId, !avatarId.isEmpty else { return nil }
        let url = AppContainer.resolve().avatarsDir.appendingPathComponent(avatarId + ".jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fresh content for a local notification.
    static func content(_ built: NotificationContent,
                        ownUserId: String,
                        avatarFile: URL?,
                        groupAvatarFile: URL? = nil,
                        attachmentFile: URL? = nil,
                        userInfo: [String: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.sound = .default
        content.userInfo = userInfo
        return apply(to: content, built: built, ownUserId: ownUserId,
                     avatarFile: avatarFile, groupAvatarFile: groupAvatarFile,
                     attachmentFile: attachmentFile)
    }

    /// Writes the text into `content` and shapes it as a conversation from the
    /// sender; the push's own sound, badge and userInfo stay as they are.
    /// - Parameters:
    ///   - avatarFile: sender avatar file; nil gives a banner without a picture.
    ///   - groupAvatarFile: group avatar; the banner shows the sender's avatar instead.
    ///   - attachmentFile: the message's picture, shown as the banner's
    ///     thumbnail; the system moves the file, so it has to be a copy.
    static func apply(to content: UNMutableNotificationContent,
                      built: NotificationContent,
                      ownUserId: String,
                      avatarFile: URL?,
                      groupAvatarFile: URL? = nil,
                      attachmentFile: URL? = nil) -> UNNotificationContent {
        content.title = built.title
        content.subtitle = built.subtitle ?? ""
        content.body = built.body
        content.threadIdentifier = built.threadIdentifier
        content.categoryIdentifier = NotificationCategory.message
        if let attachmentFile,
           let attachment = try? UNNotificationAttachment(identifier: "preview", url: attachmentFile) {
            content.attachments = [attachment]
        }

        let isGroup = built.chat?.isGroup ?? false
        let senderId = built.sender?.userId ?? ""
        let senderImage = avatarFile.flatMap { try? Data(contentsOf: $0) }.map { INImage(imageData: $0) }
        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: senderId, type: .unknown),
            nameComponents: nil,
            displayName: built.title,
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: senderId)
        let me = INPerson(
            personHandle: INPersonHandle(value: ownUserId, type: .unknown),
            nameComponents: nil,
            displayName: nil,
            image: nil,
            contactIdentifier: nil,
            customIdentifier: ownUserId,
            isMe: true,
            suggestionType: .none)

        var recipients = [me]
        if isGroup {
            recipients += built.groupMembers
                .filter { $0.userId != ownUserId }
                .map { member in
                    INPerson(personHandle: INPersonHandle(value: member.userId, type: .unknown),
                             nameComponents: nil,
                             displayName: member.displayName.isEmpty ? nil : member.displayName,
                             image: nil,
                             contactIdentifier: nil,
                             customIdentifier: member.userId)
                }
        }

        let intent = INSendMessageIntent(
            recipients: recipients,
            outgoingMessageType: .outgoingMessageText,
            content: built.body,
            speakableGroupName: isGroup
                ? INSpeakableString(spokenPhrase: built.subtitle ?? CoreStrings.string("Group")) : nil,
            conversationIdentifier: built.threadIdentifier,
            serviceName: nil,
            sender: senderPerson,
            attachments: nil)
        if isGroup, let data = groupAvatarFile.flatMap({ try? Data(contentsOf: $0) }) {
            intent.setImage(INImage(imageData: data), forParameterNamed: \.speakableGroupName)
        }

        return (try? content.updating(from: intent)) ?? content
    }
}
