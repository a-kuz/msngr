import OSLog

/// Каналы логирования ядра. Пишем сюда то, что иначе потерялось бы молча:
/// отказ записи на диск, недоступное размещение данных.
public enum MsngrLog {
    public static let subsystem = "ai.enface.msngr"

    /// Хранилище: размещение данных, создание каталогов, перенос в контейнер группы.
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Сессия: сохранение и чтение session.json.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Очередь отправки: постановка сообщения и исходники вложений.
    public static let outbox = Logger(subsystem: subsystem, category: "outbox")
    /// Нечитаемые сообщения: причина отказа, счётчик попыток, запрос отправителю
    /// и его результат. Нечитаемое — дефект, поэтому оно не остаётся молчаливым.
    public static let repair = Logger(subsystem: subsystem, category: "repair")
}
