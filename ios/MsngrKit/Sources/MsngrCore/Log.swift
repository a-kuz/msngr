import OSLog

/// Core log channels. Everything that would otherwise fail silently goes here:
/// a refused disk write, an unreachable data location.
public enum MsngrLog {
    public static let subsystem = "msngr.msngr"

    /// Storage: data location, directory creation, migration into the group container.
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    /// Session: writing and reading session.json.
    public static let session = Logger(subsystem: subsystem, category: "session")
    /// Send queue: enqueued messages and attachment originals.
    public static let outbox = Logger(subsystem: subsystem, category: "outbox")
    /// Undecryptable messages: the reason, the attempt counter, the request sent to the
    /// sender and its outcome. An undecryptable message is a defect, so it never stays silent.
    public static let repair = Logger(subsystem: subsystem, category: "repair")
    /// Notifications: what willPresent decided about a push and from which inputs.
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    /// compiling and running user shaders
    public static let shader = Logger(subsystem: subsystem, category: "shader")
}
