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

    /// Counter in the header, in Russian plural forms of "N messages".
    static func title(count: Int) -> String {
        let mod100 = count % 100
        let mod10 = count % 10
        let noun: String
        if mod100 / 10 == 1 {
            noun = "сообщений"
        } else if mod10 == 1 {
            noun = "сообщение"
        } else if (2...4).contains(mod10) {
            noun = "сообщения"
        } else {
            noun = "сообщений"
        }
        return "\(count) \(noun)"
    }
}
