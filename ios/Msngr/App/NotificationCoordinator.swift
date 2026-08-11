import UIKit
import UserNotifications

/// Конфликт пушей и ин-апп: системный пуш гасится для открытого чата
/// (сокет и так доставит), для остальных чатов в fg показываем баннер.
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationCoordinator()
    var activeChatId: String?

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let chatId = notification.request.content.userInfo["chatId"] as? String
        // открытый чат: не показываем ничего (сообщение уже на экране)
        if let chatId, chatId == activeChatId {
            return []
        }
        // приложение в fg, другой чат: баннер без звука (лента и так обновится)
        return [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        // tap по пушу → открыть чат
        if let chatId = response.notification.request.content.userInfo["chatId"] as? String {
            NotificationCenter.default.post(name: .openChatRequested, object: chatId)
        }
    }
}

extension Notification.Name {
    static let openChatRequested = Notification.Name("openChatRequested")
}
