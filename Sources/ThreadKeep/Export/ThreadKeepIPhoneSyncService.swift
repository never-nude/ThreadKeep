import AppKit
import Foundation

enum ThreadKeepIPhoneSyncError: LocalizedError, Equatable {
    case airDropUnavailable

    var errorDescription: String? {
        switch self {
        case .airDropUnavailable:
            return "AirDrop isn’t available right now. Save the archive file instead and share it from Finder."
        }
    }
}

struct ThreadKeepStagedShareItem {
    let itemURL: URL
    let containerURL: URL
}

struct ThreadKeepIPhoneSyncStager {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func stageArchive(data: Data, suggestedFilename: String) throws -> ThreadKeepStagedShareItem {
        let containerURL = fileManager.temporaryDirectory
            .appendingPathComponent("ThreadKeepSync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)

        let filename = normalizedFilename(from: suggestedFilename, requiredExtension: "threadkeeparchive")
        let fileURL = containerURL.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: fileURL, options: [.atomic])

        return ThreadKeepStagedShareItem(itemURL: fileURL, containerURL: containerURL)
    }

    func stagePackage(at packageURL: URL, suggestedFilename: String) throws -> ThreadKeepStagedShareItem {
        let containerURL = fileManager.temporaryDirectory
            .appendingPathComponent("ThreadKeepSync-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: containerURL, withIntermediateDirectories: true)

        let filename = normalizedFilename(from: suggestedFilename, requiredExtension: "threadkeeplibrary")
        let destinationURL = containerURL.appendingPathComponent(filename, isDirectory: true)
        try fileManager.copyItem(at: packageURL, to: destinationURL)

        return ThreadKeepStagedShareItem(itemURL: destinationURL, containerURL: containerURL)
    }

    func cleanup(_ stagedItem: ThreadKeepStagedShareItem) {
        try? fileManager.removeItem(at: stagedItem.containerURL)
    }

    private func normalizedFilename(from suggestedFilename: String, requiredExtension: String) -> String {
        let rawName = suggestedFilename.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = rawName.isEmpty ? "ThreadKeep Export.\(requiredExtension)" : rawName
        let sanitizedName = baseName.replacingOccurrences(of: "/", with: "-")
        if sanitizedName.lowercased().hasSuffix(".\(requiredExtension)") {
            return sanitizedName
        }
        return "\(sanitizedName).\(requiredExtension)"
    }
}

final class ThreadKeepAirDropSyncSession: NSObject, NSSharingServiceDelegate {
    private let stagedItem: ThreadKeepStagedShareItem
    private let service: NSSharingService
    private let stager: ThreadKeepIPhoneSyncStager
    private let onDidShare: @MainActor () -> Void
    private let onDidFail: @MainActor (Error) -> Void
    private var hasCleanedUp = false

    init?(
        stagedItem: ThreadKeepStagedShareItem,
        stager: ThreadKeepIPhoneSyncStager = ThreadKeepIPhoneSyncStager(),
        onDidShare: @escaping @MainActor () -> Void,
        onDidFail: @escaping @MainActor (Error) -> Void
    ) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            return nil
        }

        self.stagedItem = stagedItem
        self.service = service
        self.stager = stager
        self.onDidShare = onDidShare
        self.onDidFail = onDidFail
        super.init()
        self.service.delegate = self
    }

    func start() throws {
        let items: [Any] = [stagedItem.itemURL]
        guard service.canPerform(withItems: items) else {
            throw ThreadKeepIPhoneSyncError.airDropUnavailable
        }

        service.perform(withItems: items)
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        finishCleanupIfNeeded()
        onDidShare()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        finishCleanupIfNeeded()
        onDidFail(error)
    }

    deinit {
        finishCleanupIfNeeded()
    }

    private func finishCleanupIfNeeded() {
        guard !hasCleanedUp else {
            return
        }

        hasCleanedUp = true
        service.delegate = nil
        stager.cleanup(stagedItem)
    }
}
