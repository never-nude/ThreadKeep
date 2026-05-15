import Foundation
import os

/// Centralized logger for ThreadKeep. Uses the unified logging system so messages can be filtered
/// in Console.app using `subsystem:com.threadkeep.app` and the category name.
enum ThreadKeepLog {
    static let subsystem = "com.threadkeep.app"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let importer = Logger(subsystem: subsystem, category: "Import")
    static let messagesAutoDetect = Logger(subsystem: subsystem, category: "MessagesAutoDetect")
    static let fullDiskAccess = Logger(subsystem: subsystem, category: "FullDiskAccess")
    static let migration = Logger(subsystem: subsystem, category: "Migration")
    static let store = Logger(subsystem: subsystem, category: "Store")
    static let pdf = Logger(subsystem: subsystem, category: "PDF")
    static let sync = Logger(subsystem: subsystem, category: "Sync")
}
