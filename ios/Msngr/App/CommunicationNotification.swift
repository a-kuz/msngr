import Foundation
import Intents
import UserNotifications
import MsngrCore

/// Уведомление о сообщении в виде Communication Notification: круглый аватар
/// отправителя вместо иконки приложения и его имя в заголовке.
///
/// Картинку рисует SpringBoard по `INSendMessageIntent`, и только если сошлись
/// три условия: entitlement `com.apple.developer.usernotifications.communication`,
/// `INSendMessageIntent` в `NSUserActivityTypes` и `INPerson(isMe: true)` среди
/// recipients. При любом пропуске `updating(from:)` возвращает контент без
/// изменений и ошибку не бросает — баннер тогда обычный, с иконкой приложения.
enum CommunicationNotification {

    /// - Parameters:
    ///   - avatarFile: файл аватара отправителя из AvatarCache; nil — баннер без картинки.
    ///   - groupMembers: участники группы кроме себя. Групповой разговор система
    ///     распознаёт по числу recipients: при одном получателе баннер выходит
    ///     как личный и название группы в нём не показывается.
    ///   - groupAvatarFile: аватар группы; в баннере не используется (там аватар отправителя).
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
            speakableGroupName: isGroup ? INSpeakableString(spokenPhrase: built.subtitle ?? "Группа") : nil,
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
