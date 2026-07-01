import OSLog

/// Central logging facade. SwiftLint forbids `print` — use these categories instead.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "dev.lanfermann.gbar"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let auth = Logger(subsystem: subsystem, category: "auth")
    static let network = Logger(subsystem: subsystem, category: "network")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let notifications = Logger(subsystem: subsystem, category: "notifications")
}
