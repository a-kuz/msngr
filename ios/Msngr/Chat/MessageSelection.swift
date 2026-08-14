import Foundation
import MsngrCore

/// Набор выбранных сообщений и доступность действий над ним.
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

    /// Выбранные сообщения в порядке ленты.
    func messages(in msgs: [Message]) -> [Message] {
        msgs.filter { ids.contains($0.id) }
    }

    /// «Удалить у всех» доступно, только когда все выбранные сообщения свои:
    /// чужие сервер тумбстоунит лишь администратору группы, в личной переписке
    /// такой запрос молча ничего не сделает.
    static func canDeleteForAll(_ selected: [Message]) -> Bool {
        !selected.isEmpty && selected.allSatisfy(\.isOutgoing)
    }

    /// Счётчик в шапке: «1 сообщение», «2 сообщения», «5 сообщений».
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
