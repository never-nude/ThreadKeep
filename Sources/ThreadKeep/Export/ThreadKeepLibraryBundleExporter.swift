import Foundation
import UniformTypeIdentifiers

enum ThreadKeepLibraryBundleExportError: LocalizedError, Equatable {
    case noConversationsAvailable
    case noExportableConversations(skippedCount: Int)

    var errorDescription: String? {
        switch self {
        case .noConversationsAvailable:
            return "There aren’t any imported conversations on this Mac yet."
        case .noExportableConversations(let skippedCount):
            if skippedCount > 0 {
                return "ThreadKeep couldn’t prepare any conversations for iPhone. \(skippedCount) conversation(s) were skipped."
            }
            return "ThreadKeep couldn’t prepare any conversations for iPhone."
        }
    }
}

struct ThreadKeepLibraryBundleExportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing
        case exportingArchives
        case packaging
    }

    let phase: Phase
    let completedCount: Int
    let totalCount: Int
    let currentThreadTitle: String?
}

struct ThreadKeepLibraryBundleSkippedThread: Sendable, Equatable {
    let threadID: String
    let threadTitle: String
    let reason: String
}

struct ThreadKeepLibraryBundleExportResult: Sendable, Equatable {
    let bundleURL: URL
    let containerURL: URL
    let suggestedFilename: String
    let requestedThreadCount: Int
    let includedArchiveCount: Int
    let skippedThreads: [ThreadKeepLibraryBundleSkippedThread]

    var skippedCount: Int {
        skippedThreads.count
    }

    func cleanup(fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: containerURL)
    }
}

struct ThreadKeepLibraryBundleExporter {
    private let fileManager: FileManager
    private let appVersion: String?

    init(
        fileManager: FileManager = .default,
        appVersion: String? = ThreadKeepLibraryDesktopAppVersion.current
    ) {
        self.fileManager = fileManager
        self.appVersion = appVersion
    }

    func suggestedFilename(for exportedAt: Date = Date()) -> String {
        "ThreadKeep-Library-\(ThreadKeepLibraryBundleTimestampFormatter.dateStamp(from: exportedAt)).threadkeeplibrary"
    }

    func export(
        threads: [ThreadSummary],
        exportedAt: Date = Date(),
        progress: (@Sendable (ThreadKeepLibraryBundleExportProgress) async -> Void)? = nil,
        archiveDataProvider: @Sendable (String) async throws -> Data
    ) async throws -> ThreadKeepLibraryBundleExportResult {
        guard !threads.isEmpty else {
            throw ThreadKeepLibraryBundleExportError.noConversationsAvailable
        }

        await progress?(
            ThreadKeepLibraryBundleExportProgress(
                phase: .preparing,
                completedCount: 0,
                totalCount: threads.count,
                currentThreadTitle: nil
            )
        )

        let containerURL = fileManager.temporaryDirectory
            .appendingPathComponent("ThreadKeepLibraryBundle-\(UUID().uuidString)", isDirectory: true)
        let suggestedFilename = suggestedFilename(for: exportedAt)
        let bundleURL = containerURL.appendingPathComponent(suggestedFilename, isDirectory: true)
        let archivesDirectoryURL = bundleURL.appendingPathComponent("archives", isDirectory: true)

        try fileManager.createDirectory(at: archivesDirectoryURL, withIntermediateDirectories: true)

        do {
            var archiveEntries: [ThreadKeepLibraryBundleManifest.ArchiveEntry] = []
            var skippedThreads: [ThreadKeepLibraryBundleSkippedThread] = []

            for (index, thread) in threads.enumerated() {
                await progress?(
                    ThreadKeepLibraryBundleExportProgress(
                        phase: .exportingArchives,
                        completedCount: index,
                        totalCount: threads.count,
                        currentThreadTitle: thread.title
                    )
                )

                do {
                    let data = try await archiveDataProvider(thread.id)
                    let archiveFilename = archiveFilename(for: thread)
                    let archiveURL = archivesDirectoryURL.appendingPathComponent(archiveFilename, isDirectory: false)
                    try data.write(to: archiveURL, options: [.atomic])
                    archiveEntries.append(
                        ThreadKeepLibraryBundleManifest.ArchiveEntry(
                            threadID: thread.id,
                            threadTitle: thread.title,
                            fileName: archiveFilename
                        )
                    )
                } catch {
                    skippedThreads.append(
                        ThreadKeepLibraryBundleSkippedThread(
                            threadID: thread.id,
                            threadTitle: thread.title,
                            reason: error.localizedDescription
                        )
                    )
                }
            }

            guard !archiveEntries.isEmpty else {
                throw ThreadKeepLibraryBundleExportError.noExportableConversations(
                    skippedCount: skippedThreads.count
                )
            }

            await progress?(
                ThreadKeepLibraryBundleExportProgress(
                    phase: .packaging,
                    completedCount: archiveEntries.count,
                    totalCount: threads.count,
                    currentThreadTitle: nil
                )
            )

            let manifest = ThreadKeepLibraryBundleManifest(
                bundleID: UUID().uuidString,
                exportedAt: exportedAt,
                appVersion: appVersion,
                requestedThreadCount: threads.count,
                archiveEntries: archiveEntries,
                skippedThreads: skippedThreads
            )

            let manifestURL = bundleURL.appendingPathComponent("manifest.json", isDirectory: false)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(to: manifestURL, options: [.atomic])

            return ThreadKeepLibraryBundleExportResult(
                bundleURL: bundleURL,
                containerURL: containerURL,
                suggestedFilename: suggestedFilename,
                requestedThreadCount: threads.count,
                includedArchiveCount: archiveEntries.count,
                skippedThreads: skippedThreads
            )
        } catch {
            try? fileManager.removeItem(at: containerURL)
            throw error
        }
    }

    private func archiveFilename(for thread: ThreadSummary) -> String {
        let titleSlug = thread.title.slugified
        let resolvedTitle = titleSlug.isEmpty ? "conversation" : titleSlug
        let idSlug = thread.id.slugified
        let resolvedID = idSlug.isEmpty ? UUID().uuidString.lowercased() : idSlug
        return "\(resolvedTitle)--\(resolvedID).threadkeeparchive"
    }
}

extension UTType {
    static let threadkeepLibrary = UTType(exportedAs: "com.threadkeep.library", conformingTo: .package)
}

private enum ThreadKeepLibraryDesktopAppVersion {
    static var current: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

private struct ThreadKeepLibraryBundleManifest: Encodable {
    let schemaVersion: Int
    let bundleID: String
    let exportedAt: String
    let source: Source
    let requestedThreadCount: Int
    let includedArchiveCount: Int
    let skippedArchiveCount: Int
    let archives: [ArchiveEntry]
    let skippedThreads: [SkippedThreadEntry]

    init(
        bundleID: String,
        exportedAt: Date,
        appVersion: String?,
        requestedThreadCount: Int,
        archiveEntries: [ArchiveEntry],
        skippedThreads: [ThreadKeepLibraryBundleSkippedThread]
    ) {
        schemaVersion = 1
        self.bundleID = bundleID
        self.exportedAt = ThreadKeepLibraryBundleTimestampFormatter.timestamp(from: exportedAt)
        source = Source(kind: "threadkeep-desktop-library", appVersion: appVersion)
        self.requestedThreadCount = requestedThreadCount
        includedArchiveCount = archiveEntries.count
        skippedArchiveCount = skippedThreads.count
        archives = archiveEntries
        self.skippedThreads = skippedThreads.map(SkippedThreadEntry.init(skippedThread:))
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case bundleID = "bundle_id"
        case exportedAt = "exported_at"
        case source
        case requestedThreadCount = "requested_thread_count"
        case includedArchiveCount = "included_archive_count"
        case skippedArchiveCount = "skipped_archive_count"
        case archives
        case skippedThreads = "skipped_threads"
    }

    struct Source: Encodable {
        let kind: String
        let appVersion: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case appVersion = "app_version"
        }
    }

    struct ArchiveEntry: Encodable {
        let threadID: String
        let threadTitle: String
        let fileName: String

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case threadTitle = "thread_title"
            case fileName = "file_name"
        }
    }

    struct SkippedThreadEntry: Encodable {
        let threadID: String
        let threadTitle: String
        let reason: String

        init(skippedThread: ThreadKeepLibraryBundleSkippedThread) {
            threadID = skippedThread.threadID
            threadTitle = skippedThread.threadTitle
            reason = skippedThread.reason
        }

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case threadTitle = "thread_title"
            case reason
        }
    }
}

private enum ThreadKeepLibraryBundleTimestampFormatter {
    static func timestamp(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func dateStamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
