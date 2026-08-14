import Foundation

/// Состояние плашки «N непрочитанных сообщений» внутри открытого чата.
/// Живёт от входа в чат (в ChatViewModel), правила:
/// - вход с непрочитанными — плашка над первым непрочитанным;
/// - входящие при видимом чате увеличивают счётчик активной плашки;
/// - своя отправка или реакция убирает плашку;
/// - уход экрана в фон/шторку убирает плашку, входящие за время отсутствия
///   копятся и при возврате показываются новой плашкой.
struct UnreadMarkerState: Equatable {
    /// seq первого непрочитанного — плашка стоит над ним; nil — плашки нет
    private(set) var anchorSeq: Int?
    private(set) var count = 0
    private var obscured = false
    /// накопленное за время obscured: seq первого пришедшего и их число
    private var pendingFirstSeq: Int?
    private var pendingCount = 0

    var isActive: Bool { anchorSeq != nil && count > 0 }

    /// Вход в чат: якорь — следующий seq за последним прочитанным.
    mutating func enterChat(unreadCount: Int, myReadUpTo: Int) {
        guard unreadCount > 0 else { return }
        anchorSeq = myReadUpTo + 1
        count = unreadCount
    }

    /// Входящее сообщение собеседника с новым seq.
    mutating func incoming(seq: Int) {
        if obscured {
            if pendingFirstSeq == nil { pendingFirstSeq = seq }
            pendingCount += 1
        } else if isActive {
            count += 1
        }
    }

    /// Своя отправка или реакция — плашка убирается.
    mutating func dismiss() {
        anchorSeq = nil
        count = 0
    }

    /// Экран ушёл в фон/шторку: плашка убирается, входящие дальше копятся.
    mutating func becameObscured() {
        obscured = true
        dismiss()
        pendingFirstSeq = nil
        pendingCount = 0
    }

    /// Возврат на экран: накопленное за отсутствие становится новой плашкой.
    mutating func becameActive() {
        obscured = false
        if pendingCount > 0 {
            anchorSeq = pendingFirstSeq
            count = pendingCount
        }
        pendingFirstSeq = nil
        pendingCount = 0
    }
}
