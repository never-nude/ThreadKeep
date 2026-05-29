import Foundation
import os

enum MessagesStoreAutoDetectionResult: Equatable {
    case ready(URL)
    case messagesFolderMissing(URL)
}

struct MessagesStoreLocationResolver {
    private static let messagesFolderBookmarkDefaultsKey = "threadkeep.messagesFolderBookmark"

    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let userDefaults: UserDefaults

    init(
        fileManager: FileManager = .default,
        homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
        userDefaults: UserDefaults = .standard
    ) {
        self.fileManager = fileManager
        self.homeDirectoryURL = homeDirectoryURL
        self.userDefaults = userDefaults
    }

    var defaultMessagesFolderURL: URL {
        homeDirectoryURL.appendingPathComponent("Library/Messages", isDirectory: true)
    }

    var defaultMessagesDatabaseURL: URL {
        defaultMessagesFolderURL.appendingPathComponent("chat.db")
    }

    func autoDetectionResult() -> MessagesStoreAutoDetectionResult {
        if let savedFolderURL = restoredMessagesFolderURL(), folderExists(at: savedFolderURL) {
            log("Using saved Messages folder access at \(savedFolderURL.path)")
            return .ready(savedFolderURL)
        }

        let folderURL = defaultMessagesFolderURL
        guard folderExists(at: folderURL) else {
            log("Messages folder missing at \(folderURL.path)")
            return .messagesFolderMissing(folderURL)
        }

        log("Using default Messages folder at \(folderURL.path)")
        return .ready(folderURL)
    }

    func autoDetectedMessagesStoreURL() -> URL? {
        guard case let .ready(folderURL) = autoDetectionResult() else {
            return nil
        }
        return folderURL
    }

    func displayFolderURL(for selectedURL: URL) -> URL {
        selectedURL.hasDirectoryPath ? selectedURL : selectedURL.deletingLastPathComponent()
    }

    var hasSavedMessagesFolderAccess: Bool {
        userDefaults.data(forKey: Self.messagesFolderBookmarkDefaultsKey) != nil
    }

    /// Forgets a previously chosen Messages folder by dropping the persisted security-scoped
    /// bookmark. A subsequent `autoDetectionResult()` no longer auto-restores that folder, so the
    /// user can break out of an auto-resolved location and pick a different one.
    func forgetSavedMessagesFolderAccess() {
        guard hasSavedMessagesFolderAccess else { return }
        userDefaults.removeObject(forKey: Self.messagesFolderBookmarkDefaultsKey)
        log("Cleared saved Messages folder access")
    }

    func rememberMessagesFolderAccess(for selectedURL: URL) {
        let folderURL = displayFolderURL(for: selectedURL)

        do {
            let bookmarkData = try folderURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            userDefaults.set(bookmarkData, forKey: Self.messagesFolderBookmarkDefaultsKey)
            log("Saved Messages folder access for \(folderURL.path)")
        } catch {
            log("Failed to save Messages folder access for \(folderURL.path): \(error.localizedDescription)")
        }
    }

    private func restoredMessagesFolderURL() -> URL? {
        guard let bookmarkData = userDefaults.data(forKey: Self.messagesFolderBookmarkDefaultsKey) else {
            return nil
        }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            let folderURL = displayFolderURL(for: resolvedURL)
            if isStale {
                rememberMessagesFolderAccess(for: folderURL)
            }
            return folderURL
        } catch {
            userDefaults.removeObject(forKey: Self.messagesFolderBookmarkDefaultsKey)
            log("Saved Messages folder access could not be restored: \(error.localizedDescription)")
            return nil
        }
    }

    private func folderExists(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func log(_ message: String) {
        ThreadKeepLog.messagesAutoDetect.debug("\(message, privacy: .public)")
    }
}
