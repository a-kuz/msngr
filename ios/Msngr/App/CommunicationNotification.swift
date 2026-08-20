import Foundation
import Intents
import UserNotifications
import MsngrCore

/// Message notification shaped as a Communication Notification: the sender's
/// round avatar in place of the app icon and their name in the title.
///
/// SpringBoard draws the picture from `INSendMessageIntent`, and only when all
/// three conditions hold: the `com.apple.developer.usernotifications.communication`
/// entitlement, `INSendMessageIntent` in `NSUserActivityTypes`, and
/// `INPerson(isMe: true)` among the recipients. Miss any of them and
/// `updating(from:)` returns the content unchanged without throwing, so the
/// banner comes out as the plain one with the app icon.
enum CommunicationNotification {

    /// - Parameters:
    ///   - avatarFile: sender avatar file from AvatarCache; nil gives a banner without a picture.
    ///   - groupMembers: group participants other than yourself. The system tells a
    ///     group conversation by the number of recipients: with a single recipient the
    ///     banner comes out as a direct one and carries no group title.
    ///   - groupAvatarFile: group avatar; the banner shows the sender's avatar instead.
    static func content(_ built: NotificationContent,
                        sender: NotificationContentBuilder.SenderInfo,
                        ownUserId: String,
                        isGroup: Bool,
                        avatarFile: URL?,
                        groupMembers: [NotificationContentBuilder.SenderInfo] = [],
                        groupAvatarFile: URL? = nil,
                        userInfo: [String: Any]) -> UNNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = built.title
        if let subtitle = built.subtitle { content.subtitle = subtitle }
        content.body = built.body
        content.threadIdentifier = built.threadIdentifier
        content.sound = .default
        content.userInfo = userInfo

        let senderImage = avatarFile.flatMap { try? Data(contentsOf: $0) }.map { INImage(imageData: $0) }
        let senderPerson = INPerson(
            personHandle: INPersonHandle(value: sender.userId, type: .unknown),
            nameComponents: nil,
            displayName: built.title,
            image: senderImage,
            contactIdentifier: nil,
            customIdentifier: sender.userId)
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
            recipients += groupMembers.map { member in
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
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: built.subtitle ?? String(localized: "Group")) : nil,
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
