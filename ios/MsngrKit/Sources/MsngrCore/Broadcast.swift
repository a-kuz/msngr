import Foundation

/// Мультикаст поверх AsyncStream: каждое значение доставляется каждому
/// подписчику. Голый AsyncStream доставляет значение только одному
/// потребителю, а отмена его итерации терминирует continuation — все
/// последующие yield теряются для любых будущих подписчиков.
/// Здесь у каждого подписчика собственный стрим; отмена отписывает только его.
public final class Broadcast<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    private let replayLast: Bool
    private var last: Element?

    /// replayLast: новый подписчик сразу получает последнее отправленное
    /// значение (для состояний вроде «подключено», где важен текущий снапшот).
    public init(replayLast: Bool = false) {
        self.replayLast = replayLast
    }

    /// Стрим с начальным значением: подписчик получает его (или более свежее)
    /// первым элементом.
    public convenience init(initial: Element) {
        self.init(replayLast: true)
        last = initial
    }

    public func subscribe() -> AsyncStream<Element> {
        AsyncStream { continuation in
            lock.lock()
            let id = UUID()
            continuations[id] = continuation
            let replay = replayLast ? last : nil
            lock.unlock()
            if let replay { continuation.yield(replay) }
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    public func send(_ value: Element) {
        lock.lock()
        if replayLast { last = value }
        let subscribers = Array(continuations.values)
        lock.unlock()
        for c in subscribers { c.yield(value) }
    }
}
