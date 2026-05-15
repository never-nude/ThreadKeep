import Foundation

/// Migrates data laid down by versions of the app that used the internal "Threadkeeper" identifier.
///
/// v2 renames everything to "ThreadKeep". Existing users would otherwise appear to lose their
/// library because the app would look in a freshly-named folder and the old one would be orphaned.
enum LegacyDataMigration {
    /// Keys whose UserDefaults values should be copied to new identifiers if not already present.
    /// The value is the old key; the new key is derived by replacing `threadkeeper.` with `threadkeep.`.
    private static let legacyDefaultsKeyPrefix = "threadkeeper."

    private static let migrationCompletedKey = "threadkeep.migration.threadkeeperToThreadKeepCompleted"

    static func runIfNeeded(
        fileManager: FileManager = .default,
        defaults: UserDefaults = .standard
    ) {
        guard !defaults.bool(forKey: migrationCompletedKey) else {
            return
        }

        migrateApplicationSupportFolder(fileManager: fileManager)
        migrateUserDefaultsKeys(defaults: defaults)

        defaults.set(true, forKey: migrationCompletedKey)
        ThreadKeepLog.migration.info("Legacy Threadkeeper → ThreadKeep migration complete.")
    }

    // MARK: - Application Support folder

    private static func migrateApplicationSupportFolder(fileManager: FileManager) {
        guard let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return
        }

        let legacyFolder = appSupport.appendingPathComponent("Threadkeeper", isDirectory: true)
        let newFolder = appSupport.appendingPathComponent("ThreadKeep", isDirectory: true)

        guard fileManager.fileExists(atPath: legacyFolder.path) else {
            return
        }

        // Don't blow away an existing new folder. If the user somehow ends up with both,
        // leave the new one alone and log.
        if fileManager.fileExists(atPath: newFolder.path) {
            ThreadKeepLog.migration.warning("Both Threadkeeper and ThreadKeep folders exist; leaving the legacy folder in place.")
            return
        }

        do {
            try fileManager.moveItem(at: legacyFolder, to: newFolder)
            ThreadKeepLog.migration.info("Moved legacy Application Support folder to ThreadKeep/")
            renameSQLiteFileIfNeeded(in: newFolder, fileManager: fileManager)
        } catch {
            ThreadKeepLog.migration.error("Couldn't move legacy Application Support folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func renameSQLiteFileIfNeeded(in folder: URL, fileManager: FileManager) {
        let legacyDB = folder.appendingPathComponent("threadkeeper.sqlite")
        let newDB = folder.appendingPathComponent("threadkeep.sqlite")

        // Case-insensitive filesystems (default on macOS) will see these as the same file.
        // Check both by attempting to move only when they differ on disk.
        guard fileManager.fileExists(atPath: legacyDB.path) else {
            return
        }
        if fileManager.fileExists(atPath: newDB.path) {
            return
        }

        do {
            try fileManager.moveItem(at: legacyDB, to: newDB)
            // Rename the -shm and -wal companions that SQLite creates in WAL mode.
            for suffix in ["-shm", "-wal"] {
                let legacyCompanion = folder.appendingPathComponent("threadkeeper.sqlite\(suffix)")
                let newCompanion = folder.appendingPathComponent("threadkeep.sqlite\(suffix)")
                if fileManager.fileExists(atPath: legacyCompanion.path),
                   !fileManager.fileExists(atPath: newCompanion.path) {
                    try? fileManager.moveItem(at: legacyCompanion, to: newCompanion)
                }
            }
            ThreadKeepLog.migration.info("Renamed legacy sqlite database to threadkeep.sqlite")
        } catch {
            ThreadKeepLog.migration.error("Couldn't rename legacy database: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - UserDefaults

    private static func migrateUserDefaultsKeys(defaults: UserDefaults) {
        let dictionary = defaults.dictionaryRepresentation()
        for (key, value) in dictionary where key.hasPrefix(legacyDefaultsKeyPrefix) {
            let newKey = "threadkeep." + key.dropFirst(legacyDefaultsKeyPrefix.count)
            // Don't stomp a value that already exists under the new key.
            if defaults.object(forKey: newKey) == nil {
                defaults.set(value, forKey: newKey)
            }
            defaults.removeObject(forKey: key)
        }
    }
}
