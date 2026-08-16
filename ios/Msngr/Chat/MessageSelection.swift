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

    /// «Удалить у всех» is available only when every selected message is our own: someone
    /// else's the server tombstones for a group admin alone, and in a direct chat such a
    /// request silently does nothing.
    static func canDeleteForAll(_ selected: [Message]) -> Bool {
        !selected.isEmpty && selected.allSatisfy(\.isOutgoing)
    }

    /// Counter in the header, with plural forms: «1 сообщение», «2 сообщения», «5 сообщений».
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
