import Foundation
import MsngrCore

/// The set of selected messages and which actions are available on it.
struct MessageSelection: Equatable {
    private(set) var ids: Set<String> = []

    var isEmpty: Bool { ids.isEmpty }
    var count: Int { ids.count }

    func contains(_ msg: Message) -> Bool { ids.contains(msg.id) }
    func contains(id: String) -> Bool { ids.contains(id) }

    mutating func select(_ msg: Message) { ids.insert(msg.id) }

    mutating func toggle(_ msg: Message) {
        if ids.contains(msg.id) { ids.remove(msg.id) } else { ids.insert(msg.id) }
    }

    mutating func clear() { ids.removeAll() }

    /// The selected messages in feed order.
    func messages(in msgs: [Message]) -> [Message] {
        msgs.filter { ids.contains($0.id) }
    }

    static func canDeleteForAll(_ selected: [Message]) -> Bool {
        MessageDeletion.canDeleteForAll(selected)
    }

    /// Counter in the header: "N messages" in the plural form of the current locale.
    static func title(count: Int) -> String {
        String(localized: "\(count) messages")
    }
}
