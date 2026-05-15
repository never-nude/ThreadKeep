import Darwin
import Foundation

/// Reports whether this process can read `~/Library/Messages/chat.db`.
///
/// On macOS the Messages library lives under a TCC-protected path. Without
/// Full Disk Access (FDA) granted to ThreadKeep, `FileManager.fileExists` will
/// generally report the file as missing, and `open(2)` will fail with
/// `EPERM` ("Operation not permitted"). We distinguish the two cases so the
/// UI can show a precise, actionable prompt.
enum FullDiskAccessStatus: Equatable, Sendable {
    /// The Messages database is reachable and readable. FDA is almost certainly granted.
    case granted
    /// The Messages database exists at the expected location but the process can't read it.
    /// This is the "needs Full Disk Access" signal.
    case denied
    /// Messages has never been opened on this Mac, or the library truly isn't present yet.
    case messagesLibraryMissing
    /// Could not determine status (unexpected errno, etc.). Treat like `denied` for UI purposes
    /// but keep a debug message around.
    case unknown(errnoValue: Int32)
}

enum FullDiskAccessProbe {
    /// Performs a non-intrusive read attempt against `~/Library/Messages/chat.db`.
    ///
    /// This does not trigger an authorization prompt - macOS grants FDA only via System Settings.
    /// The probe simply observes whether a single byte can be read from the database file.
    static func currentStatus(
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> FullDiskAccessStatus {
        let chatDBPath = homeDirectoryURL
            .appendingPathComponent("Library/Messages/chat.db")
            .path

        // Try to open the file. POSIX gives us distinguishable errno values here in a way that
        // `FileManager.fileExists` does not.
        let fd = chatDBPath.withCString { open($0, O_RDONLY) }
        if fd >= 0 {
            close(fd)
            return .granted
        }

        let err = errno
        switch err {
        case EPERM, EACCES:
            ThreadKeepLog.fullDiskAccess.debug("chat.db open denied (errno=\(err))")
            return .denied
        case ENOENT:
            ThreadKeepLog.fullDiskAccess.debug("chat.db not present at \(chatDBPath, privacy: .public)")
            return .messagesLibraryMissing
        default:
            ThreadKeepLog.fullDiskAccess.debug("chat.db probe returned errno=\(err)")
            return .unknown(errnoValue: err)
        }
    }

    /// Deep-link URL for System Settings → Privacy & Security → Full Disk Access.
    static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!
}
