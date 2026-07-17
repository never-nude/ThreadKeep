import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct AppAlertInfo: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct ActivityStatusBanner: Equatable {
    let message: String
    let showsProgress: Bool
}

enum TranscriptScrollTarget: Hashable {
    case message(String)
    case day(Date)
}

struct MessageScrollRequest: Equatable {
    let id = UUID()
    let target: TranscriptScrollTarget
    let animated: Bool
}

enum InitialAppFlow: Equatable {
    case determining
    case welcome
    case library
}

@MainActor
final class AppViewModel: ObservableObject {
    static let defaultLibraryStatusMessage = "All your conversations in one place."

    @Published var libraryFilters = LibraryFilters()
    @Published private(set) var threads: [ThreadSummary] = []
    @Published private(set) var participantOptions: [ParticipantRecord] = []
    @Published var focusedThreadIDs: Set<String>?
    @Published var selectedThreadID: String? {
        didSet {
            guard selectedThreadID != oldValue else { return }
            Task { await loadSelectedThread() }
        }
    }
    @Published private(set) var selectedThread: ThreadDetail?
    @Published var librarySearchQuery = ""
    @Published private(set) var librarySearchResults: [LibrarySearchResult] = []
    @Published private(set) var librarySearchConversationCount = 0
    @Published var threadSearchQuery = ""
    @Published private(set) var threadSearchResults: [ThreadSearchResult] = []
    @Published var currentSearchResultIndex = 0
    @Published var focusedMessageID: String?
    @Published private(set) var scrollRequest: MessageScrollRequest?
    @Published var isShowingImportSheet = false
    @Published var isBusy = false
    @Published private(set) var initialAppFlow: InitialAppFlow = .determining
    @Published var statusMessage = AppViewModel.defaultLibraryStatusMessage
    @Published var alertInfo: AppAlertInfo?
    @Published var activityStatusBanner: ActivityStatusBanner?
    @Published private(set) var wifiSyncServer: ThreadKeepWiFiSyncServer?

    let store: ArchiveStore
    private let pdfExporter: ThreadPDFExporter
    private let jsonExporter: ThreadJSONExporter
    private let csvExporter: ThreadCSVExporter
    private let txtExporter: ThreadTextExporter
    private let htmlExporter: ThreadHTMLExporter
    private let demoLibrarySeedProvider: DemoLibrarySeedProvider?
    private let pdfContactsResolver = ContactDisplayResolver()
    private let libraryContactsResolver = ContactDisplayResolver()
    private var hasBootstrapped = false
    private var libraryRefreshTask: Task<Void, Never>?
    private var librarySearchTask: Task<Void, Never>?
    private var threadSearchTask: Task<Void, Never>?
    private var activityStatusDismissTask: Task<Void, Never>?
    private var activeThreadKeepSyncSession: ThreadKeepAirDropSyncSession?
    private var requiresExplicitThreadSelectionAfterLaunch = true
    private var mergedThreadComponentsByVisibleID: [String: [String]] = [:]
    private var visibleThreadIDByRawThreadID: [String: String] = [:]
    private var visibleThreadTitleByID: [String: String] = [:]
    private var contactsActivationObserver: NSObjectProtocol?
    private var lastContactsReadable = false

    init(
        store: ArchiveStore,
        pdfExporter: ThreadPDFExporter = ThreadPDFExporter(),
        jsonExporter: ThreadJSONExporter = ThreadJSONExporter(),
        csvExporter: ThreadCSVExporter = ThreadCSVExporter(),
        txtExporter: ThreadTextExporter = ThreadTextExporter(),
        htmlExporter: ThreadHTMLExporter = ThreadHTMLExporter(),
        demoLibrarySeedProvider: DemoLibrarySeedProvider? = nil
    ) {
        self.store = store
        self.pdfExporter = pdfExporter
        self.jsonExporter = jsonExporter
        self.csvExporter = csvExporter
        self.txtExporter = txtExporter
        self.htmlExporter = htmlExporter
        self.demoLibrarySeedProvider = demoLibrarySeedProvider
    }

    var demoMessagesFolderURL: URL? {
        try? demoLibrarySeedProvider?.messagesFolderURL()
    }

    static func live() -> AppViewModel {
        // Migrate from the old "Threadkeeper" identifier before the store looks for its files.
        LegacyDataMigration.runIfNeeded()

        do {
            return AppViewModel(store: try ArchiveStore())
        } catch {
            ThreadKeepLog.app.error("ArchiveStore init failed: \(error.localizedDescription, privacy: .public)")
            presentStartupFailureAndExit(error: error)
        }
    }

    /// Shown only when the store can't be opened at all (disk full, permissions, corrupt db path).
    /// Gives the user one click to reveal the library folder so they can investigate, then quits.
    private static func presentStartupFailureAndExit(error: Error) -> Never {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "ThreadKeep couldn’t open your library."
        alert.informativeText = """
            \(error.localizedDescription)

            Your conversations are stored in ~/Library/Application Support/ThreadKeep. \
            You can open that folder to inspect it, then try launching ThreadKeep again.
            """
        alert.addButton(withTitle: "Reveal Library Folder")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           let appSupport = try? FileManager.default.url(
               for: .applicationSupportDirectory,
               in: .userDomainMask,
               appropriateFor: nil,
               create: false
           ) {
            let libraryFolder = appSupport.appendingPathComponent("ThreadKeep", isDirectory: true)
            NSWorkspace.shared.activateFileViewerSelecting([libraryFolder])
        }

        exit(EXIT_FAILURE)
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        requiresExplicitThreadSelectionAfterLaunch = true
        selectedThreadID = nil
        resetSessionForPrivacy()
        startContactsAuthorizationMonitoring()

        if initialAppFlow == .determining {
            initialAppFlow = .welcome
        }
    }

    /// Watch for the app regaining focus (e.g. the user returning from System
    /// Settings after granting Contacts access) so a grant made while ThreadKeep
    /// is already running takes effect without a relaunch. `authorizationStatus`
    /// is read fresh per call, but nothing else observes OS permission changes,
    /// so before this the "Contacts access is off" state persisted until the app
    /// was relaunched.
    private func startContactsAuthorizationMonitoring() {
        guard contactsActivationObserver == nil else { return }
        lastContactsReadable = MessagesStoreImporter.contactsReadAllowed()
        contactsActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recheckContactsAuthorizationOnActivation()
            }
        }
    }

    /// On app activation, re-read Contacts authorization. If it flipped from
    /// not-readable to readable (authorized or the macOS limited tier) while we
    /// were running, rebuild the contact indexes and re-resolve the thread list
    /// and open conversation so names/photos populate immediately. Fires only on
    /// the off→on transition to avoid reloading on every focus change.
    private func recheckContactsAuthorizationOnActivation() {
        let useContactsNames = UserDefaults.standard.object(forKey: "threadkeep.import.useContactsNames") as? Bool ?? true
        let readable = MessagesStoreImporter.contactsReadAllowed()
        defer { lastContactsReadable = readable }
        guard useContactsNames, readable, !lastContactsReadable else { return }

        Task {
            await libraryContactsResolver.refresh(enabled: true, requestAccessIfNeeded: false)
            await refreshLibrary(autoSelect: false)
            // The sidebar and the open conversation each re-resolve their own
            // resolver on this notification.
            NotificationCenter.default.post(
                name: .threadKeepContactsAccessDidChange,
                object: MessagesContactAccessState.authorized
            )
        }
    }

    func prepareLibraryForAuthenticatedViewing() async {
        requiresExplicitThreadSelectionAfterLaunch = true
        await refreshLibrary(autoSelect: false)
    }

    func revealImportedLibrary(selecting preferredThreadIDs: [String], focusedOnly: Bool = false) async {
        requiresExplicitThreadSelectionAfterLaunch = false
        focusedThreadIDs = focusedOnly && !preferredThreadIDs.isEmpty ? Set(preferredThreadIDs) : nil

        if let preferredThreadID = preferredThreadIDs.first {
            selectedThreadID = preferredThreadID
            await refreshLibrary(autoSelect: false)
        } else {
            await refreshLibrary(autoSelect: true)
        }
    }

    func resetSessionForPrivacy() {
        libraryRefreshTask?.cancel()
        librarySearchTask?.cancel()
        threadSearchTask?.cancel()
        activityStatusDismissTask?.cancel()
        requiresExplicitThreadSelectionAfterLaunch = true
        focusedThreadIDs = nil
        libraryFilters = LibraryFilters()
        librarySearchQuery = ""
        librarySearchResults = []
        librarySearchConversationCount = 0
        selectedThreadID = nil
        selectedThread = nil
        threadSearchQuery = ""
        threadSearchResults = []
        currentSearchResultIndex = 0
        focusedMessageID = nil
        scrollRequest = nil
        threads = []
        participantOptions = []
        mergedThreadComponentsByVisibleID = [:]
        visibleThreadIDByRawThreadID = [:]
        visibleThreadTitleByID = [:]
        isShowingImportSheet = false
        activityStatusBanner = nil
        alertInfo = nil
        statusMessage = AppViewModel.defaultLibraryStatusMessage
    }

    func selectThread(_ threadID: String) {
        requiresExplicitThreadSelectionAfterLaunch = false
        selectedThreadID = threadID
    }

    func showLibraryHome() {
        requiresExplicitThreadSelectionAfterLaunch = true
        selectedThreadID = nil
        clearSelectedThreadState()
    }

    func refreshLibrary(autoSelect: Bool = true) async {
        do {
            let filters = libraryFilters
            let loadedThreads = try await store.loadThreadSummaries(filters: filters)
            let participants = try await store.loadParticipantOptions()
            let visibleThreadIDs = focusedThreadIDs
            let focusedThreads = loadedThreads.filter { summary in
                guard let visibleThreadIDs, !visibleThreadIDs.isEmpty else { return true }
                return visibleThreadIDs.contains(summary.id)
            }
            let threads = await mergedThreadSummaries(from: focusedThreads)

            self.threads = threads
            participantOptions = participants

            if autoSelect {
                guard !requiresExplicitThreadSelectionAfterLaunch else {
                    selectedThreadID = nil
                    clearSelectedThreadState()
                    return
                }

                if let selectedThreadID, !threads.contains(where: { $0.id == selectedThreadID }) {
                    self.selectedThreadID = threads.first?.id
                    await loadSelectedThread()
                } else if self.selectedThreadID == nil {
                    self.selectedThreadID = threads.first?.id
                    await loadSelectedThread()
                } else {
                    await loadSelectedThread()
                }
            } else if let selectedThreadID {
                if threads.contains(where: { $0.id == selectedThreadID }) {
                    await loadSelectedThread()
                } else {
                    self.selectedThreadID = nil
                    clearSelectedThreadState()
                }
            }
        } catch {
            present(error: error, title: "Unable to Refresh Library")
        }
    }

    func loadSelectedThread() async {
        threadSearchTask?.cancel()

        guard let selectedThreadID else {
            clearSelectedThreadState()
            return
        }

        guard !requiresExplicitThreadSelectionAfterLaunch else {
            self.selectedThreadID = nil
            return
        }

        do {
            let loadedThread: ThreadDetail?
            if let componentThreadIDs = mergedThreadComponentsByVisibleID[selectedThreadID] {
                let title = visibleThreadTitleByID[selectedThreadID] ?? "Merged Conversation"
                loadedThread = try await store.loadMergedThreadDetail(
                    id: selectedThreadID,
                    title: title,
                    threadIDs: componentThreadIDs
                )
            } else {
                loadedThread = try await store.loadThreadDetail(id: selectedThreadID)
            }
            guard self.selectedThreadID == selectedThreadID else { return }
            selectedThread = loadedThread
            await refreshThreadSearch()
        } catch {
            present(error: error, title: "Unable to Load Thread")
        }
    }

    func refreshThreadSearch() async {
        let query = threadSearchQuery
        let trimmedQuery = query.trimmed
        guard let selectedThreadID, !trimmedQuery.isEmpty, trimmedQuery.count >= 2 else {
            threadSearchResults = []
            currentSearchResultIndex = 0
            updateFocusedMessage(nil)
            return
        }

        do {
            let results: [ThreadSearchResult]
            if mergedThreadComponentsByVisibleID[selectedThreadID] != nil, let selectedThread {
                results = searchMessagesInMemory(selectedThread.messages, query: trimmedQuery)
            } else {
                results = try await store.searchInThread(threadID: selectedThreadID, query: trimmedQuery)
            }
            guard self.selectedThreadID == selectedThreadID, self.threadSearchQuery == query else { return }
            threadSearchResults = results
            currentSearchResultIndex = 0
            if let first = results.first?.messageID {
                updateFocusedMessage(first, animated: false)
            } else {
                updateFocusedMessage(nil)
            }
        } catch {
            present(error: error, title: "Search Failed")
        }
    }

    func scheduleLibraryRefresh(delay: Duration = .milliseconds(180)) {
        libraryRefreshTask?.cancel()
        libraryRefreshTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshLibrary()
        }
    }

    func scheduleLibrarySearch(delay: Duration = .milliseconds(250)) {
        librarySearchTask?.cancel()

        let trimmedQuery = librarySearchQuery.trimmed
        if trimmedQuery.isEmpty {
            librarySearchResults = []
            librarySearchConversationCount = 0
            return
        }

        librarySearchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshLibrarySearch()
        }
    }

    func clearLibrarySearch() {
        librarySearchTask?.cancel()
        librarySearchQuery = ""
        librarySearchResults = []
        librarySearchConversationCount = 0
    }

    func refreshLibrarySearch() async {
        let query = librarySearchQuery
        let trimmedQuery = query.trimmed
        guard !trimmedQuery.isEmpty else {
            librarySearchResults = []
            librarySearchConversationCount = 0
            return
        }

        do {
            let rawResults = try await store.searchLibrary(query: trimmedQuery)
            guard librarySearchQuery == query else { return }
            let mappedResults = rawResults.map { result -> LibrarySearchResult in
                let visibleThreadID = visibleThreadIDByRawThreadID[result.threadID] ?? result.threadID
                return LibrarySearchResult(
                    id: result.id,
                    threadID: visibleThreadID,
                    messageID: result.messageID,
                    threadTitle: visibleThreadTitleByID[visibleThreadID] ?? result.threadTitle,
                    participantNames: result.participantNames,
                    senderDisplayName: result.senderDisplayName,
                    timestamp: result.timestamp,
                    snippet: result.snippet
                )
            }
            librarySearchResults = mappedResults
            librarySearchConversationCount = Set(mappedResults.map(\.threadID)).count
        } catch {
            present(error: error, title: "Search Failed")
        }
    }

    func scheduleThreadSearch(delay: Duration = .milliseconds(280)) {
        threadSearchTask?.cancel()

        let trimmedQuery = threadSearchQuery.trimmed
        if trimmedQuery.isEmpty || trimmedQuery.count < 2 {
            threadSearchResults = []
            currentSearchResultIndex = 0
            updateFocusedMessage(nil)
            return
        }

        threadSearchTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.refreshThreadSearch()
        }
    }

    @discardableResult
    func importParsedArchive(_ payload: ParsedArchivePayload) async -> Bool {
        isBusy = true
        defer { isBusy = false }

        do {
            try await store.importArchive(payload)
            statusMessage = "Imported “\(payload.archive.title)”. It is ready to read now, and you can search all conversations any time."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
            clearSelectedThreadState()
            selectThread(payload.archive.id)
            await refreshLibrary(autoSelect: false)
            return true
        } catch {
            present(error: error, title: "Import Failed")
            return false
        }
    }

    func focusSearchResult(at index: Int) {
        guard threadSearchResults.indices.contains(index) else { return }
        currentSearchResultIndex = index
        updateFocusedMessage(threadSearchResults[index].messageID, animated: true)
    }

    func navigateSearchResult(delta: Int) {
        guard !threadSearchResults.isEmpty else { return }
        let resultCount = threadSearchResults.count
        let currentMessageID = focusedMessageID
        var next = currentSearchResultIndex

        for _ in 0..<resultCount {
            next = (next + delta + resultCount) % resultCount
            if threadSearchResults[next].messageID != currentMessageID || resultCount == 1 {
                focusSearchResult(at: next)
                return
            }
        }

        focusSearchResult(at: next)
    }

    func openLibrarySearchResult(_ result: LibrarySearchResult) {
        requiresExplicitThreadSelectionAfterLaunch = false
        selectedThreadID = result.threadID
        focusedMessageID = result.messageID
        scrollRequest = MessageScrollRequest(target: .message(result.messageID), animated: true)
    }

    func jumpToDate(_ date: Date) {
        guard let target = selectedThread?.dateJumpTarget(onOrAfter: date) else { return }
        focusedMessageID = target.messageID
        scrollRequest = MessageScrollRequest(target: .message(target.messageID), animated: true)

        if !target.isExactDayMatch() {
            let requested = AppFormatters.libraryRangeStart.string(from: date)
            let actual = AppFormatters.libraryRangeStart.string(from: target.messageDate)
            announceStatus("No messages on \(requested). Jumped to \(actual).", autoDismissAfter: 3)
        }
    }

    func jumpToTimelineBucket(_ bucket: TimelineBucket) {
        jumpToDate(bucket.startDate)
    }

    func jumpToMonth(_ monthID: String) {
        guard let target = selectedThread?.dateJumpTarget(forMonthID: monthID) else { return }
        focusedMessageID = target.messageID
        scrollRequest = MessageScrollRequest(target: .message(target.messageID), animated: true)
    }

    func exportSelectedThreadPDF(mode: PDFExportMode = .review) async {
        guard let thread = selectedThread else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = pdfExporter.suggestedFilename(for: thread, mode: mode)
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let resolution = await pdfNameResolution(for: thread)
            let data = try pdfExporter.export(thread: thread, mode: mode, resolution: resolution)
            try data.write(to: destinationURL, options: .atomic)
            statusMessage = "Saved a searchable PDF as \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            present(error: error, title: "Export Failed")
        }
    }

    func exportSelectedThreadJSON() async {
        guard let thread = selectedThread else { return }

        NSApp.activate(ignoringOtherApps: true)
        guard let choice = jsonExportFolderChoice(prompt: "Export JSON") else { return }

        isBusy = true
        showActivityStatus("Exporting JSON…", showsProgress: true)
        defer { isBusy = false }

        do {
            let resolution = await jsonNameResolution(for: thread)
            let result = try jsonExporter.export(
                thread: thread,
                to: choice.destinationURL,
                includeAttachments: choice.includeAttachments,
                nameResolution: resolution
            )
            statusMessage = "Saved JSON export in \(result.folderURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            showActivityStatus(nil)
            present(error: error, title: "JSON Export Failed")
        }
    }

    func exportSelectedThreadCSV() async {
        guard let thread = selectedThread else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = csvExporter.suggestedFilename(for: thread)
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let resolution = await jsonNameResolution(for: thread)
            let content = csvExporter.export(thread: thread, nameResolution: resolution)
            try Data(content.utf8).write(to: destinationURL, options: .atomic)
            statusMessage = "Saved a CSV transcript as \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            present(error: error, title: "Export Failed")
        }
    }

    func exportSelectedThreadText() async {
        guard let thread = selectedThread else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = txtExporter.suggestedFilename(for: thread)
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let resolution = await jsonNameResolution(for: thread)
            let content = txtExporter.export(thread: thread, nameResolution: resolution)
            try Data(content.utf8).write(to: destinationURL, options: .atomic)
            statusMessage = "Saved a plain-text transcript as \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            present(error: error, title: "Export Failed")
        }
    }

    func exportSelectedThreadHTML() async {
        guard let thread = selectedThread else { return }

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = htmlExporter.suggestedFilename(for: thread)
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let resolution = await jsonNameResolution(for: thread)
            let content = htmlExporter.export(thread: thread, nameResolution: resolution)
            try Data(content.utf8).write(to: destinationURL, options: .atomic)
            statusMessage = "Saved an HTML transcript as \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            present(error: error, title: "Export Failed")
        }
    }

    func exportVisibleLibraryJSON() async {
        guard !threads.isEmpty else {
            presentMessage(
                title: "Nothing to Export",
                message: "Import conversations first, then export your library as JSON."
            )
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        guard let choice = jsonExportFolderChoice(prompt: "Export Library JSON") else { return }

        isBusy = true
        showActivityStatus("Exporting library JSON…", showsProgress: true)

        let parentURL = choice.destinationURL
            .appendingPathComponent("ThreadKeep-JSON-Export-\(jsonExportDateStamp())", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: parentURL, withIntermediateDirectories: true)

            var exportedCount = 0
            for threadSummary in threads {
                guard let detail = try await loadVisibleThreadDetail(
                    id: threadSummary.id,
                    title: threadSummary.title
                ) else {
                    continue
                }
                let resolution = await jsonNameResolution(for: detail)
                _ = try jsonExporter.export(
                    thread: detail,
                    to: parentURL,
                    includeAttachments: choice.includeAttachments,
                    nameResolution: resolution
                )
                exportedCount += 1
            }

            statusMessage = "Saved \(exportedCount.formatted(.number)) JSON conversation export(s) in \(parentURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            showActivityStatus(nil)
            present(error: error, title: "Library JSON Export Failed")
        }

        isBusy = false
    }

    private func pdfNameResolution(for thread: ThreadDetail) async -> PDFNameResolution {
        let useContactsNames = UserDefaults.standard.object(forKey: "threadkeep.import.useContactsNames") as? Bool ?? true
        await pdfContactsResolver.refresh(enabled: useContactsNames)

        let participantNames = thread.participants.map(\.displayName)
        var senderNames: [String: String] = [:]
        for name in participantNames {
            senderNames[name] = pdfContactsResolver.resolvedName(for: name)
        }
        for sender in Set(thread.messages.map(\.senderDisplayName)) where senderNames[sender] == nil {
            senderNames[sender] = pdfContactsResolver.resolvedName(for: sender)
        }

        return PDFNameResolution(
            threadTitle: pdfContactsResolver.title(rawTitle: thread.title, participantNames: participantNames),
            participantSummary: pdfContactsResolver.participantSummary(for: participantNames),
            senderNames: senderNames
        )
    }

    private func jsonNameResolution(for thread: ThreadDetail) async -> ThreadJSONNameResolution {
        let useContactsNames = UserDefaults.standard.object(forKey: "threadkeep.import.useContactsNames") as? Bool ?? true
        await pdfContactsResolver.refresh(enabled: useContactsNames)

        let participantNames = thread.participants.map(\.displayName)
        var participantNamesByID: [String: String] = [:]
        for participant in thread.participants {
            participantNamesByID[participant.id] = pdfContactsResolver.resolvedName(for: participant.displayName)
        }

        var senderNamesByID: [String: String] = [:]
        for message in thread.messages where senderNamesByID[message.senderID] == nil {
            senderNamesByID[message.senderID] = message.isOutgoing
                ? "Me"
                : pdfContactsResolver.resolvedName(for: message.senderDisplayName)
        }

        var participantContactIdentifiersByID: [String: String] = [:]
        for participant in thread.participants {
            var candidateHandles = [participant.displayName]
            for message in thread.messages where message.senderID == participant.id {
                if let handle = jsonSenderHandle(fromMetadataJSON: message.metadataJSON) {
                    candidateHandles.append(handle)
                }
            }
            for handle in candidateHandles {
                if let identifier = pdfContactsResolver.contactIdentifiers(for: handle).first {
                    participantContactIdentifiersByID[participant.id] = identifier
                    break
                }
            }
        }

        return ThreadJSONNameResolution(
            threadTitle: pdfContactsResolver.title(rawTitle: thread.title, participantNames: participantNames),
            participantNamesByID: participantNamesByID,
            senderNamesByID: senderNamesByID,
            participantContactIdentifiersByID: participantContactIdentifiersByID
        )
    }

    private func jsonSenderHandle(fromMetadataJSON metadataJSON: String?) -> String? {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handle = object["sender_handle"] as? String
        else {
            return nil
        }
        return handle.trimmed.nilIfBlank
    }

    private func jsonExportFolderChoice(prompt: String) -> (destinationURL: URL, includeAttachments: Bool)? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = prompt
        panel.message = "Choose where ThreadKeep should create the JSON export folder."
        panel.directoryURL = defaultSaveDirectoryURL

        let checkbox = NSButton(checkboxWithTitle: "Include attachments", target: nil, action: nil)
        checkbox.state = .on
        checkbox.toolTip = "Copy only the attachments referenced by the exported conversation JSON."
        panel.accessoryView = checkbox

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return nil
        }

        return (destinationURL, checkbox.state == .on)
    }

    func syncSelectedThreadToIPhone() async {
        guard let selectedThreadID, let thread = selectedThread else { return }

        isBusy = true
        showActivityStatus("Preparing archive…", showsProgress: true)

        let archiveExporter = ThreadKeepMobileArchiveExporter()
        let suggestedFilename = archiveExporter.suggestedFilename(for: thread.title)

        do {
            let data = try await store.exportThreadKeepArchiveData(for: selectedThreadID)
            let stagedArchive = try await Task.detached(priority: .utility) {
                try ThreadKeepIPhoneSyncStager().stageArchive(data: data, suggestedFilename: suggestedFilename)
            }.value

            guard let session = ThreadKeepAirDropSyncSession(
                stagedItem: stagedArchive,
                onDidShare: { [weak self] in
                    guard let self else {
                        return
                    }

                    isBusy = false
                    activeThreadKeepSyncSession = nil
                    statusMessage = "Sent “\(thread.title)” to your iPhone."
                    showActivityStatus("Sent to iPhone", autoDismissAfter: 2.8)
                },
                onDidFail: { [weak self] error in
                    guard let self else {
                        return
                    }

                    isBusy = false
                    activeThreadKeepSyncSession = nil

                    if isUserCancellationError(error) {
                        showActivityStatus("Sync canceled.", autoDismissAfter: 2.4)
                        return
                    }

                    showActivityStatus(nil)
                    present(error: error, title: "Sync to iPhone Failed")
                }
            ) else {
                isBusy = false
                showActivityStatus(nil)
                await saveSelectedThreadKeepArchiveFile(precomputedData: data, suggestedFilename: suggestedFilename)
                return
            }

            activeThreadKeepSyncSession = session
            statusMessage = "Ready to send “\(thread.title)” to your iPhone."
            showActivityStatus("Ready to send to iPhone")
            NSApp.activate(ignoringOtherApps: true)
            do {
                try session.start()
            } catch {
                isBusy = false
                activeThreadKeepSyncSession = nil

                if let syncError = error as? ThreadKeepIPhoneSyncError,
                   syncError == .airDropUnavailable {
                    showActivityStatus(nil)
                    await saveSelectedThreadKeepArchiveFile(
                        precomputedData: data,
                        suggestedFilename: suggestedFilename
                    )
                    return
                }

                throw error
            }
        } catch {
            isBusy = false
            activeThreadKeepSyncSession = nil

            if let syncError = error as? ThreadKeepIPhoneSyncError,
               syncError == .airDropUnavailable {
                showActivityStatus(nil)
                await saveSelectedThreadKeepArchiveFile(suggestedFilename: suggestedFilename)
                return
            }

            showActivityStatus(nil)
            present(error: error, title: "Sync to iPhone Failed")
        }
    }

    func syncEntireLibraryToIPhone() async {
        isBusy = true
        showActivityStatus("Preparing your library for iPhone…", showsProgress: true)

        var preparedBundle: ThreadKeepLibraryBundleExportResult?

        do {
            let bundleExport = try await prepareEntireLibraryBundle { [weak self] progress in
                guard let self else { return }
                await MainActor.run {
                    self.showActivityStatus(
                        self.libraryBundleProgressMessage(for: progress),
                        showsProgress: true
                    )
                }
            }
            preparedBundle = bundleExport

            let stagedBundle = try await Task.detached(priority: .utility) {
                try ThreadKeepIPhoneSyncStager().stagePackage(
                    at: bundleExport.bundleURL,
                    suggestedFilename: bundleExport.suggestedFilename
                )
            }.value

            guard let session = ThreadKeepAirDropSyncSession(
                stagedItem: stagedBundle,
                onDidShare: { [weak self] in
                    guard let self else {
                        return
                    }

                    isBusy = false
                    activeThreadKeepSyncSession = nil
                    statusMessage = libraryBundleCompletionMessage(
                        for: bundleExport,
                        action: "Sent"
                    )
                    showActivityStatus("Sent entire library to iPhone", autoDismissAfter: 2.8)
                },
                onDidFail: { [weak self] error in
                    guard let self else {
                        return
                    }

                    isBusy = false
                    activeThreadKeepSyncSession = nil

                    if isUserCancellationError(error) {
                        showActivityStatus("Library sync canceled.", autoDismissAfter: 2.4)
                        return
                    }

                    showActivityStatus(nil)
                    present(error: error, title: "Library Sync Failed")
                }
            ) else {
                await saveEntireLibraryBundle(precomputedBundleExport: bundleExport)
                return
            }

            activeThreadKeepSyncSession = session
            statusMessage = libraryBundleReadyMessage(for: bundleExport)
            showActivityStatus("Ready to send entire library to iPhone")
            NSApp.activate(ignoringOtherApps: true)
            do {
                try session.start()
                bundleExport.cleanup()
                preparedBundle = nil
            } catch {
                activeThreadKeepSyncSession = nil

                if let syncError = error as? ThreadKeepIPhoneSyncError,
                   syncError == .airDropUnavailable {
                    await saveEntireLibraryBundle(precomputedBundleExport: bundleExport)
                    return
                }

                throw error
            }
        } catch {
            isBusy = false
            activeThreadKeepSyncSession = nil
            preparedBundle?.cleanup()
            showActivityStatus(nil)
            present(error: error, title: "Library Sync Failed")
        }
    }

    /// Starts the Wi-Fi sync server and exposes it for the sheet UI.
    ///
    /// The archives provider loads every thread in the library and exports it
    /// as a mobile archive; threads whose export fails are skipped rather than
    /// failing the whole transfer, so the count the phone sees is the count
    /// actually sent.
    func beginWiFiSyncToIPhone() {
        if let wifiSyncServer {
            // Already presenting; just make sure it's listening.
            wifiSyncServer.start()
            return
        }

        let store = self.store
        let server = ThreadKeepWiFiSyncServer(archivesProvider: {
            let summaries = try await store.loadThreadSummaries(filters: LibraryFilters())
            let exporter = ThreadKeepMobileArchiveExporter()
            var archives: [(name: String, data: Data)] = []
            archives.reserveCapacity(summaries.count)
            for summary in summaries {
                do {
                    let data = try await store.exportThreadKeepArchiveData(for: summary.id)
                    archives.append((name: exporter.suggestedFilename(for: summary.title), data: data))
                } catch {
                    // Skip conversations that fail to export; send the rest.
                    continue
                }
            }
            return archives
        })

        wifiSyncServer = server
        server.start()
    }

    /// Stops the Wi-Fi sync server and dismisses its sheet.
    func endWiFiSyncToIPhone() {
        wifiSyncServer?.stop()
        wifiSyncServer = nil
    }

    func saveSelectedThreadKeepArchiveFile(
        precomputedData: Data? = nil,
        suggestedFilename: String? = nil
    ) async {
        guard let selectedThreadID, let thread = selectedThread else { return }

        let archiveExporter = ThreadKeepMobileArchiveExporter()
        let resolvedFilename = suggestedFilename ?? archiveExporter.suggestedFilename(for: thread.title)

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.threadkeepArchive]
        panel.nameFieldStringValue = resolvedFilename
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            let data = try await archiveDataForSync(
                threadID: selectedThreadID,
                precomputedData: precomputedData
            )
            try data.write(to: destinationURL, options: .atomic)
            statusMessage = "Saved a copy of this conversation as \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
        } catch {
            present(error: error, title: "Archive Export Failed")
        }
    }

    func saveEntireLibraryBundle(
        precomputedBundleExport: ThreadKeepLibraryBundleExportResult? = nil
    ) async {
        let exporter = ThreadKeepLibraryBundleExporter()

        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.threadkeepLibrary]
        panel.nameFieldStringValue = precomputedBundleExport?.suggestedFilename ?? exporter.suggestedFilename()
        panel.directoryURL = defaultSaveDirectoryURL

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            precomputedBundleExport?.cleanup()
            isBusy = false
            showActivityStatus(nil)
            return
        }

        isBusy = true

        var bundleExport = precomputedBundleExport

        do {
            if bundleExport == nil {
                showActivityStatus("Preparing your library bundle…", showsProgress: true)
                bundleExport = try await prepareEntireLibraryBundle { [weak self] progress in
                    guard let self else { return }
                    await MainActor.run {
                        self.showActivityStatus(
                            self.libraryBundleProgressMessage(for: progress),
                            showsProgress: true
                        )
                    }
                }
            }

            guard let bundleExport else {
                return
            }

            try replaceExportedBundle(at: destinationURL, with: bundleExport.bundleURL)
            statusMessage = libraryBundleCompletionMessage(
                for: bundleExport,
                action: "Saved"
            ) + " File: \(destinationURL.lastPathComponent)."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
            showActivityStatus("Saved entire library bundle", autoDismissAfter: 2.8)
            bundleExport.cleanup()
        } catch {
            bundleExport?.cleanup()
            showActivityStatus(nil)
            present(error: error, title: "Library Export Failed")
        }

        isBusy = false
    }

    func deleteSelectedThread() async {
        guard let selectedThreadID, let title = selectedThread?.title else { return }

        isBusy = true
        defer { isBusy = false }

        do {
            try await store.deleteThread(threadID: selectedThreadID)
            statusMessage = "Removed “\(title)” from your Messages library."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
            self.selectedThreadID = nil
            await refreshLibrary()
        } catch {
            present(error: error, title: "Delete Failed")
        }
    }

    func deleteAllArchives() async {
        isBusy = true
        defer { isBusy = false }

        do {
            try await store.deleteAllData()
            selectedThreadID = nil
            selectedThread = nil
            threadSearchResults = []
            statusMessage = "Removed all imported conversations from this Mac."
            showActivityStatus(statusMessage, autoDismissAfter: 4)
            await refreshLibrary()
        } catch {
            present(error: error, title: "Delete Failed")
        }
    }

    func openDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([store.libraryDirectoryURL])
    }

    func resetParticipantFilter() {
        libraryFilters.participantID = nil
    }

    func announceStatus(_ message: String, autoDismissAfter seconds: Double = 4) {
        statusMessage = message
        showActivityStatus(message, autoDismissAfter: seconds)
    }

    func presentMessage(title: String, message: String) {
        alertInfo = AppAlertInfo(title: title, message: message)
    }

    func dismissActivityStatusBanner() {
        showActivityStatus(nil)
    }

    private func updateFocusedMessage(_ messageID: String?, animated: Bool = true) {
        focusedMessageID = messageID
        if let messageID {
            scrollRequest = MessageScrollRequest(target: .message(messageID), animated: animated)
        } else {
            scrollRequest = nil
        }
    }

    private func clearSelectedThreadState() {
        selectedThread = nil
        threadSearchResults = []
        updateFocusedMessage(nil)
    }

    private func mergedThreadSummaries(from rawThreads: [ThreadSummary]) async -> [ThreadSummary] {
        let useContactsNames = UserDefaults.standard.object(forKey: "threadkeep.import.useContactsNames") as? Bool ?? true
        await libraryContactsResolver.refresh(enabled: useContactsNames)

        var groupedDirectThreads: [String: [ThreadSummary]] = [:]
        var passthroughThreads: [ThreadSummary] = []

        for thread in rawThreads {
            let participants = libraryContactsResolver.uniqueParticipants(from: thread.participantNames, excludingYou: true)
            guard let mergeKey = ThreadMergeGrouping.mergeKey(for: participants) else {
                passthroughThreads.append(thread)
                continue
            }
            groupedDirectThreads[mergeKey, default: []].append(thread)
        }

        var mergedThreadComponents: [String: [String]] = [:]
        var rawToVisible: [String: String] = [:]
        var titleByID: [String: String] = [:]
        var visibleThreads = passthroughThreads

        for thread in passthroughThreads {
            rawToVisible[thread.id] = thread.id
            titleByID[thread.id] = thread.title
        }

        for (contactKey, threads) in groupedDirectThreads {
            if threads.count == 1, let thread = threads.first {
                rawToVisible[thread.id] = thread.id
                titleByID[thread.id] = thread.title
                visibleThreads.append(thread)
                continue
            }

            let mergedID = "merged-\(StableHash.fnv1a64Hex(contactKey))"
            let merged = mergedSummary(id: mergedID, contactKey: contactKey, threads: threads)
            mergedThreadComponents[mergedID] = threads.map(\.id)
            titleByID[mergedID] = merged.title
            for rawID in threads.map(\.id) {
                rawToVisible[rawID] = mergedID
            }
            visibleThreads.append(merged)
        }

        mergedThreadComponentsByVisibleID = mergedThreadComponents
        visibleThreadIDByRawThreadID = rawToVisible
        visibleThreadTitleByID = titleByID

        return visibleThreads.sorted {
            let lhsDate = $0.latestMessageTimestamp ?? $0.endDate ?? $0.importedAt
            let rhsDate = $1.latestMessageTimestamp ?? $1.endDate ?? $1.importedAt
            if lhsDate != rhsDate {
                return lhsDate > rhsDate
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func mergedSummary(id: String, contactKey: String, threads: [ThreadSummary]) -> ThreadSummary {
        let allParticipantNames = threads.flatMap(\.participantNames)
        let resolvedParticipants = libraryContactsResolver.uniqueParticipants(from: allParticipantNames, excludingYou: true)
        let primaryParticipant = resolvedParticipants.first
        let title = primaryParticipant?.displayName
            ?? threads.first?.title
            ?? "Merged Conversation"

        let latestThread = threads.max {
            ($0.latestMessageTimestamp ?? $0.endDate ?? $0.importedAt) < ($1.latestMessageTimestamp ?? $1.endDate ?? $1.importedAt)
        }

        let importedAt = threads.map(\.importedAt).min() ?? Date()
        let startDate = threads.compactMap(\.startDate).min()
        let endDate = threads.compactMap(\.endDate).max()
        let matchCount = threads.compactMap(\.matchCount).reduce(0, +)

        return ThreadSummary(
            id: id,
            title: title,
            startDate: startDate,
            endDate: endDate,
            participantNames: allParticipantNames,
            participantCount: max(2, resolvedParticipants.count + 1),
            messageCount: threads.reduce(0) { $0 + $1.messageCount },
            attachmentCount: threads.reduce(0) { $0 + $1.attachmentCount },
            hasAttachments: threads.contains(where: \.hasAttachments),
            importedAt: importedAt,
            rawArchivePath: nil,
            importSourceKind: latestThread?.importSourceKind ?? .messagesMacBeta,
            matchCount: matchCount > 0 ? matchCount : nil,
            latestMessageText: latestThread?.latestMessageText,
            latestMessageTimestamp: latestThread?.latestMessageTimestamp,
            latestSenderDisplayName: latestThread?.latestSenderDisplayName,
            latestMessageIsOutgoing: latestThread?.latestMessageIsOutgoing ?? false
        )
    }

    private func loadVisibleThreadDetail(id threadID: String, title: String) async throws -> ThreadDetail? {
        if let componentThreadIDs = mergedThreadComponentsByVisibleID[threadID] {
            return try await store.loadMergedThreadDetail(
                id: threadID,
                title: visibleThreadTitleByID[threadID] ?? title,
                threadIDs: componentThreadIDs
            )
        }

        return try await store.loadThreadDetail(id: threadID)
    }

    private func searchMessagesInMemory(_ messages: [MessageRecord], query: String) -> [ThreadSearchResult] {
        messages
            .filter {
                $0.bodyText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil ||
                    $0.senderDisplayName.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
            .prefix(250)
            .map {
                ThreadSearchResult(
                    id: "merged-\($0.id)",
                    messageID: $0.id,
                    senderDisplayName: $0.senderDisplayName,
                    timestamp: $0.timestamp,
                    snippet: snippet(for: $0.bodyText.isEmpty ? $0.senderDisplayName : $0.bodyText, query: query)
                )
            }
    }

    private func snippet(for text: String, query: String) -> String {
        let nsText = text as NSString
        let match = nsText.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
        guard match.location != NSNotFound else {
            return text
        }

        let start = max(0, match.location - 40)
        let end = min(nsText.length, match.location + match.length + 40)
        let range = NSRange(location: start, length: end - start)
        let prefix = start > 0 ? "…" : ""
        let suffix = end < nsText.length ? "…" : ""
        return prefix + nsText.substring(with: range) + suffix
    }

    private func jsonExportDateStamp(from date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private var defaultSaveDirectoryURL: URL? {
        let fileManager = FileManager.default
        let candidates =
            [
                fileManager.urls(for: .desktopDirectory, in: .userDomainMask).first,
                fileManager.urls(for: .documentDirectory, in: .userDomainMask).first,
                fileManager.homeDirectoryForCurrentUser
            ]
            .compactMap { $0 }

        return candidates.first(where: { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
    }

    private func present(error: Error, title: String) {
        alertInfo = AppAlertInfo(title: title, message: error.localizedDescription)
    }

    private func showActivityStatus(
        _ message: String?,
        showsProgress: Bool = false,
        autoDismissAfter seconds: Double? = nil
    ) {
        activityStatusDismissTask?.cancel()

        guard let message else {
            activityStatusBanner = nil
            return
        }

        let banner = ActivityStatusBanner(message: message, showsProgress: showsProgress)
        activityStatusBanner = banner

        guard let seconds else {
            return
        }

        activityStatusDismissTask = Task { @MainActor in
            let nanoseconds = UInt64(seconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)

            if !Task.isCancelled, self.activityStatusBanner == banner {
                self.activityStatusBanner = nil
            }
        }
    }

    private func archiveDataForSync(
        threadID: String,
        precomputedData: Data? = nil
    ) async throws -> Data {
        if let precomputedData {
            return precomputedData
        }

        return try await store.exportThreadKeepArchiveData(for: threadID)
    }

    private func prepareEntireLibraryBundle(
        progressHandler: (@Sendable (ThreadKeepLibraryBundleExportProgress) async -> Void)? = nil
    ) async throws -> ThreadKeepLibraryBundleExportResult {
        let threadSummaries = try await store.loadThreadSummaries(filters: LibraryFilters())
        let store = self.store
        return try await Task.detached(priority: .userInitiated) {
            let exporter = ThreadKeepLibraryBundleExporter()
            return try await exporter.export(
                threads: threadSummaries,
                progress: progressHandler,
                archiveDataProvider: { threadID in
                    try await store.exportThreadKeepArchiveData(for: threadID)
                }
            )
        }.value
    }

    private func replaceExportedBundle(at destinationURL: URL, with bundleURL: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.copyItem(at: bundleURL, to: destinationURL)
    }

    private func libraryBundleProgressMessage(for progress: ThreadKeepLibraryBundleExportProgress) -> String {
        switch progress.phase {
        case .preparing:
            return "Preparing \(progress.totalCount) conversations for iPhone…"
        case .exportingArchives:
            let currentCount = min(progress.completedCount + 1, progress.totalCount)
            if let currentThreadTitle = progress.currentThreadTitle?.trimmed.nilIfBlank {
                return "Preparing \(currentCount) of \(progress.totalCount): \(currentThreadTitle)…"
            }
            return "Preparing \(currentCount) of \(progress.totalCount) conversations…"
        case .packaging:
            return "Packaging your library bundle…"
        }
    }

    private func libraryBundleReadyMessage(for bundleExport: ThreadKeepLibraryBundleExportResult) -> String {
        let skippedSuffix = bundleExport.skippedCount > 0
            ? " \(bundleExport.skippedCount) conversation(s) were skipped."
            : ""
        return "Prepared \(bundleExport.includedArchiveCount) conversations for iPhone.\(skippedSuffix)"
    }

    private func libraryBundleCompletionMessage(
        for bundleExport: ThreadKeepLibraryBundleExportResult,
        action: String
    ) -> String {
        if bundleExport.skippedCount == 0 {
            return "\(action) \(bundleExport.includedArchiveCount) conversations for iPhone."
        }

        return "\(action) \(bundleExport.includedArchiveCount) of \(bundleExport.requestedThreadCount) conversations for iPhone. \(bundleExport.skippedCount) were skipped."
    }

    private func isUserCancellationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.Code.userCancelled.rawValue
    }
}
