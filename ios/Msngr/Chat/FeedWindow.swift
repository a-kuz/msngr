import Foundation
import MsngrCore

/// Нижняя граница окна ленты и его вместимость. Наблюдение читает состояние на
/// каждой выборке, с очереди базы, поэтому доступ под замком.
///
/// Окно держит не больше `capacity` сообщений в обоих положениях ленты. У низа
/// оно скользит: граница пересчитывается по вместимости, и приходящие сообщения
/// выталкивают самые старые. Пока пользователь смотрит историю, граница стоит на
/// месте — ничто из прочитанного не уезжает, — а вместимость отсекает сверху
/// всё, что пришло за это время. Без потолка окно растёт всё время, что открыт
/// чат, и каждая вставка перечитывает, декодирует и диффит всё, что в нём
/// накопилось.
final class FeedWindow: @unchecked Sendable {
    /// Что подставить в выборку и надо ли сперва пересчитать границу.
    struct Plan: Equatable {
        let floor: Int?
        let recompute: Bool
        let capacity: Int
    }

    private let lock = NSLock()
    private var seq: Int?
    private var capacity: Int
    private var atBottom = true

    init(capacity: Int = HistoryWindow.pageSize) {
        self.capacity = capacity
    }

    func get() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return seq
    }

    func set(_ value: Int?) {
        lock.lock(); seq = value; lock.unlock()
    }

    func plan() -> Plan {
        lock.lock(); defer { lock.unlock() }
        return Plan(floor: seq, recompute: seq == nil || atBottom, capacity: capacity)
    }

    /// Пользователь подгрузил историю: окну разрешено держать на столько больше.
    func grow(by count: Int) {
        lock.lock(); capacity += count; lock.unlock()
    }

    /// Переход к сообщению глубже окна: граница встаёт прямо на него, а
    /// вместимость растягивается до самого свежего сообщения — из точки перехода
    /// остаётся дорога вниз, к концу переписки.
    func anchor(floor: Int, capacity: Int) {
        lock.lock()
        seq = floor
        self.capacity = max(self.capacity, capacity)
        lock.unlock()
    }

    func setAtBottom(_ value: Bool) {
        lock.lock(); atBottom = value; lock.unlock()
    }
}
