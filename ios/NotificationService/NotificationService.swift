import UserNotifications
import GRDB
import MsngrCore
import MsngrCrypto

/// NSE: пуш приходит с mutable-content и без plaintext. Расширение открывает ту же
/// БД (app group), тем же мастер-ключом (Keychain access group) расшифровывает
/// последнее сообщение чата для превью. Ключи не покидают устройство.
final class NotificationService: UNNotificationServiceExtension {
    var contentHandler: ((UNNotificationContent) -> Void)?
    var bestAttempt: UNMutableNotificationContent?

    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent)!
        self.bestAttempt = content

        guard let chatId = request.content.userInfo["chatId"] as? String else {
            contentHandler(content)
            return
        }

        Task {
            await enrich(content: content, chatId: chatId,
                         msgId: request.content.userInfo["msgId"] as? String)
            contentHandler(content)
        }
    }

    private func enrich(content: UNMutableNotificationContent, chatId: String, msgId: String?) async {
        guard let groupURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppGroup.identifier) else { return }
        let dbURL = groupURL.appendingPathComponent("msngr.sqlite")
        guard FileManager.default.fileExists(atPath: dbURL.path) else { return }

        let ownId = UserDefaults(suiteName: AppGroup.identifier)?.string(forKey: "ownUserId") ?? ""
        do {
            // текст уже расшифрован движком приложения и лежит в общей БД;
            // NSE только читает его для превью (ключи не нужны для чтения plaintext-колонки)
            let db = try AppDatabase.open(at: dbURL)
            // заголовок чата
            let (title, kind) = try await db.read { dbc -> (String, String) in
                let chat = try Chat.fetchOne(dbc, key: chatId)
                if chat?.kind == .group {
                    return (chat?.title ?? "Группа", "group")
                }
                let peerId = try String.fetchOne(dbc,
                    sql: "SELECT userId FROM member WHERE chatId = ? AND userId != ?",
                    arguments: [chatId, ownId])
                let peer = peerId.flatMap { try? User.fetchOne(dbc, key: $0) }
                return (peer?.displayName ?? "Сообщение", "direct")
            }
            content.title = title

            // последнее сообщение уже расшифровано движком и лежит в БД (пуш приходит
            // после WS-доставки в fg; в bg сокет закрыт, но сообщение в inbox сервера).
            // Пробуем показать локально записанный текст, иначе — нейтральное превью.
            if let text = try await db.read({ dbc -> String? in
                if let id = msgId,
                   let m = try Message.fetchOne(dbc, sql: "SELECT * FROM message WHERE msgId = ?", arguments: [id]) {
                    return NotificationService.preview(m, group: kind == "group",
                                                       authorName: try? String.fetchOne(dbc,
                                                        sql: "SELECT displayName FROM user WHERE id = ?",
                                                        arguments: [m.fromUserId]))
                }
                return nil
            }) {
                content.body = text
            }

            // бейдж = сумма непрочитанного
            let unread = try await db.read { dbc in
                try Int.fetchOne(dbc, sql: "SELECT COALESCE(SUM(unreadCount),0) FROM chat") ?? 0
            }
            content.badge = NSNumber(value: unread)
        } catch {
            // молча оставляем нейтральное превью
        }
    }

    static func preview(_ m: Message, group: Bool, authorName: String?) -> String {
        let body: String
        switch m.kind {
        case .photo: body = "📷 Фото"
        case .video: body = "🎥 Видео"
        case .voice: body = "🎤 Голосовое сообщение"
        case .file: body = "📎 " + (m.media?.name ?? "Файл")
        case .album: body = "🖼 Альбом"
        default: body = m.text ?? ""
        }
        if group, let name = authorName {
            return "\(name): \(body)"
        }
        return body
    }

    override func serviceExtensionTimeWillExpire() {
        if let handler = contentHandler, let content = bestAttempt {
            handler(content)
        }
    }
}

enum AppGroup {
    static let identifier = "group.ai.enface.msngr"
    static let keychainGroup = "ai.enface.msngr.shared"
}
