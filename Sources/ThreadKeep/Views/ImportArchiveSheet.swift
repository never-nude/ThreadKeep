import AppKit
import SwiftUI

enum MessagesImportMode: String, CaseIterable {
    case all
    case single

    var title: String {
        switch self {
        case .all:
            return "Import All"
        case .single:
            return "Choose Conversations"
        }
    }

    var subtitle: String {
        switch self {
        case .all:
            return "Import all conversations from Messages on this Mac."
        case .single:
            return "Select the conversations to add to your library."
        }
    }
}

struct ImportArchiveSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var viewModel: AppViewModel
    // Default to true so the chat picker shows contact names instead of raw phone numbers,
    // matching what users see in Messages.app on the same Mac.
    @AppStorage("threadkeep.import.useContactsNames") private var useContactsNames = true

    private let preferredMode: MessagesImportMode
    private let onClose: (() -> Void)?
    @State private var validationMessage: String?
    @State private var messagesFolderURL: URL?
    @State private var messagesChats: [MessagesChatCandidate] = []
    @State private var selectedMessagesChatIDs: Set<Int> = []
    @State private var messagesSearchText = ""
    @State private var importMode: MessagesImportMode
    @State private var isLoadingMessagesChats = false
    @State private var isPreparingMessagesImport = false
    @State private var showsManualMessagesFallback = false
    @State private var contactsAccessState: MessagesContactAccessState = .disabledByChoice
    @State private var contactsMessage: String?
    @State private var importProgressMessage: String?
    @State private var hasStartedAutomaticLookup = false
    @State private var fullDiskAccessStatus: FullDiskAccessStatus = .granted
    @State private var pendingAutoImport = false

    private let onImportCompleted: ((MessagesImportMode, [String]) -> Void)?
    private let authorizeImport: @MainActor () async -> Bool
    private let messagesStoreImporter = MessagesStoreImporter()
    private let messagesStoreLocationResolver = MessagesStoreLocationResolver()
    @StateObject private var contactsResolver = ContactDisplayResolver()

    init(
        preferredMode: MessagesImportMode = .all,
        authorizeImport: @escaping @MainActor () async -> Bool = { true },
        onImportCompleted: ((MessagesImportMode, [String]) -> Void)? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.preferredMode = preferredMode
        self.authorizeImport = authorizeImport
        self.onImportCompleted = onImportCompleted
        self.onClose = onClose
        _importMode = State(initialValue: preferredMode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            statusRow

            if fullDiskAccessStatus == .denied && messagesChats.isEmpty {
                fullDiskAccessCard
            } else if messagesChats.isEmpty && !isLoadingMessagesChats && !isPreparingMessagesImport {
                // One-click "grab everything" entrypoint so the user doesn't have to parse the
                // form below before their first successful import.
                fetchMessagesCard
            } else if let validationMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(validationMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)

                    if showsManualMessagesFallback {
                        Text("If needed, you can choose the Messages folder on this Mac manually and keep going.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            if let contactsMessage {
                Text(contactsMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if let importProgressMessage {
                Text(importProgressMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            messagesStoreCard

            Spacer()

            HStack {
                Button("Cancel") {
                    closeImportFlow()
                }
                Spacer()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 620)
        .task(id: useContactsNames) {
            refreshContactAccessState()
            await contactsResolver.refresh(enabled: canResolveContactsForImportList)
            if !hasStartedAutomaticLookup {
                hasStartedAutomaticLookup = true
            }
            if let demoMessagesFolderURL {
                loadMessagesChats(from: demoMessagesFolderURL, autoDetected: true)
            } else if let messagesFolderURL {
                loadMessagesChats(from: messagesFolderURL, autoDetected: false)
            } else {
                connectMessagesStore()
            }
        }
        .onChange(of: importMode) { _, _ in
            selectedMessagesChatIDs = defaultSelectedChatIDs(for: messagesChats)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard hasStartedAutomaticLookup else { return }
            // If the user stepped out to grant Full Disk Access, silently retry the lookup
            // the moment they're back in ThreadKeep so everything just works.
            let fdaStatus = FullDiskAccessProbe.currentStatus()
            if fullDiskAccessStatus == .denied && fdaStatus != .denied {
                fullDiskAccessStatus = fdaStatus
                connectMessagesStore()
            } else {
                fullDiskAccessStatus = fdaStatus
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepContactsAccessDidChange)) { _ in
            Task { @MainActor in
                refreshContactAccessState()
                await contactsResolver.refresh(enabled: canResolveContactsForImportList)
                if let messagesFolderURL {
                    loadMessagesChats(from: messagesFolderURL, autoDetected: false)
                }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text("Add Conversations")
                    .font(.title2.bold())
                Text("ThreadKeep reads Messages on this Mac and creates a local library.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusRow: some View {
        HStack(spacing: 12) {
            if let messagesFolderURL {
                Label(messagesFolderURL.path, systemImage: "externaldrive.badge.person.crop")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if isLoadingMessagesChats {
                Label("Connecting to Messages on this Mac…", systemImage: "message.badge.waveform")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("Use contact names", isOn: contactsOptInBinding)
                .toggleStyle(.switch)
                .font(.system(size: 11))
                .disabled(isPreparingMessagesImport || isLoadingMessagesChats)

            if useContactsNames, contactsAccessState != .authorized {
                Button {
                    requestContactsAccess()
                } label: {
                    Label(contactsAccessButtonTitle, systemImage: contactsAccessButtonSystemImage)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingMessagesChats || isPreparingMessagesImport || contactsAccessState == .unavailable)
                .help("Allow ThreadKeep to use local Contacts for friendlier conversation labels")
            }

            if hasStartedAutomaticLookup && !isLoadingMessagesChats {
                Button {
                    connectMessagesStore()
                } label: {
                    Label(messagesChats.isEmpty ? "Scan Again" : "Refresh List", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(isPreparingMessagesImport)
                .help("Scan Messages on this Mac again")
            }

            if showsManualMessagesFallback {
                Button {
                    chooseMessagesStoreManually()
                } label: {
                    Label("Choose Manually", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingMessagesChats || isPreparingMessagesImport)
                .help("Choose the Messages folder manually if automatic connection needs help")
            }
        }
    }

    private var selectedChatCount: Int {
        selectedMessagesChatIDs.count
    }

    private var canRenderResolvedChatList: Bool {
        !canUseContactsForImport || contactsResolver.isReady
    }

    private var canUseContactsForImport: Bool {
        useContactsNames
    }

    private var canResolveContactsForImportList: Bool {
        !isDemoImport && canUseContactsForImport
    }

    private var isDemoImport: Bool {
        demoMessagesFolderURL != nil
    }

    private var demoMessagesFolderURL: URL? {
        viewModel.demoMessagesFolderURL
    }

    private var contactsOptInBinding: Binding<Bool> {
        Binding(
            get: { useContactsNames },
            set: { newValue in
                useContactsNames = newValue
                refreshContactAccessState()
            }
        )
    }

    private var primaryButtonTitle: String {
        if isPreparingMessagesImport {
            return "Importing…"
        }

        if importMode == .single && selectedChatCount == 1 {
            return "Open Selected Conversation"
        }

        let count = selectedChatCount
        if count == 0 {
            return "Import Selected Conversations"
        }
        if count == 1 {
            return "Import 1 Conversation"
        }
        if count == messagesChats.count {
            return "Import All \(count.formatted(.number)) Conversations"
        }
        return "Import \(count.formatted(.number)) Conversations"
    }

    private var primaryActionDisabled: Bool {
        isPreparingMessagesImport || isLoadingMessagesChats || messagesFolderURL == nil || selectedMessagesChatIDs.isEmpty
    }

    private var filteredMessagesChats: [MessagesChatCandidate] {
        let query = messagesSearchText.trimmed.lowercased()
        guard !query.isEmpty else { return messagesChats }
        return messagesChats.filter { candidate in
            candidate.title.lowercased().contains(query) ||
            candidate.participantNames.joined(separator: " ").lowercased().contains(query) ||
            chatDisplaySubtitle(for: candidate).lowercased().contains(query) ||
            (candidate.serviceName?.lowercased().contains(query) ?? false)
        }
    }

    private var selectionPrompt: String {
        if isDemoImport {
            return "This demo build contains four bundled conversations. Import keeps the demo library limited to those conversations."
        }

        switch importMode {
        case .all:
            let baseCopy = "Conversations remain separate after import."
            if messagesChats.count >= 200 {
                return "\(baseCopy) Large libraries may take longer on the first pass."
            }
            return baseCopy
        case .single:
            return "Select one conversation or a smaller set."
        }
    }

    private var selectionSummary: String {
        if messagesChats.isEmpty {
            return "No conversations found yet."
        }

        let shownText = "\(filteredMessagesChats.count.formatted(.number)) shown"
        let totalText = "\(messagesChats.count.formatted(.number)) available"
        let selectedText = "\(selectedChatCount.formatted(.number)) selected"
        return [shownText, totalText, selectedText].joined(separator: " • ")
    }

    private var messagesStoreCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Messages on This Mac")
                        .font(.headline)
                    Text("Imported conversations appear in the library.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isLoadingMessagesChats || isPreparingMessagesImport {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if fullDiskAccessStatus == .denied && messagesChats.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Grant Full Disk Access above, then retry.")
                        .font(.system(size: 12, weight: .semibold))

                    Text("ThreadKeep needs permission before it can read the Messages database on this Mac. If you keep Messages in another folder, you can choose that folder manually.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        chooseMessagesStoreManually()
                    } label: {
                        Label("Choose Folder Manually", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isLoadingMessagesChats || isPreparingMessagesImport)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What would you like to import?")
                        .font(.system(size: 12, weight: .semibold))

                    Picker("Import Scope", selection: $importMode) {
                        ForEach(MessagesImportMode.allCases, id: \.self) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(importMode.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(importMode.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text(selectionPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField("Search by name, number, email, or date", text: $messagesSearchText)
                    .textFieldStyle(.roundedBorder)

                if !messagesChats.isEmpty, !canRenderResolvedChatList {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading contact names…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                } else if !messagesChats.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text(selectionSummary)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)

                            Spacer()

                            Button("Select All Shown") {
                                selectFilteredChats()
                            }
                            .buttonStyle(.bordered)
                            .disabled(filteredMessagesChats.isEmpty || isPreparingMessagesImport)

                            Button("Select All") {
                                selectAllChats()
                            }
                            .buttonStyle(.bordered)
                            .disabled(messagesChats.isEmpty || isPreparingMessagesImport)

                            Button("Clear") {
                                selectedMessagesChatIDs.removeAll()
                            }
                            .buttonStyle(.bordered)
                            .disabled(selectedMessagesChatIDs.isEmpty || isPreparingMessagesImport)
                        }

                        List {
                            ForEach(filteredMessagesChats) { chat in
                                chatRow(chat)
                            }
                        }
                        .frame(minHeight: 280, maxHeight: 380)

                        if filteredMessagesChats.isEmpty {
                            Text("No conversations found. Try a different name, number, or date.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }

                        HStack {
                            Text("Select one conversation, a few, or the full list.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                importSelectedMessagesChats()
                            } label: {
                                Label(primaryButtonTitle, systemImage: importMode == .single && selectedChatCount == 1 ? "arrow.right.circle.fill" : "tray.and.arrow.down.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(primaryActionDisabled)
                        }
                    }
                } else if isLoadingMessagesChats {
                    Text("Indexing conversations…")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if showsManualMessagesFallback {
                    Text("If ThreadKeep needs help finding Messages on this Mac, you can choose the folder manually.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else if messagesFolderURL != nil {
                    Text("Messages is available on this Mac, but there aren’t any conversations ready to bring in yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Choose Import Conversations above when you are ready.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func chatRow(_ chat: MessagesChatCandidate) -> some View {
        let isSelected = selectedMessagesChatIDs.contains(chat.id)

        return Button {
            toggleSelection(for: chat.id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                AvatarView(participants: chatAvatarParticipants(for: chat), size: 34, resolver: contactsResolver)

                VStack(alignment: .leading, spacing: 5) {
                    Text(chatDisplayTitle(for: chat))
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(chatDisplaySubtitle(for: chat))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help(isSelected ? "Remove this conversation from the import selection" : "Add this conversation to the import selection")
    }

    private func chatAvatarParticipants(for chat: MessagesChatCandidate) -> [AvatarView.Participant] {
        let participants = contactsResolver.uniqueParticipants(from: chat.participantNames, excludingYou: true)
        if !participants.isEmpty {
            return participants.map {
                AvatarView.Participant(displayName: $0.displayName, handle: $0.handle)
            }
        }

        let title = chatDisplayTitle(for: chat)
        return [
            AvatarView.Participant(
                displayName: title,
                handle: contactsResolver.primaryHandle(rawTitle: chat.title, participantNames: chat.participantNames)
            )
        ]
    }

    private func chatDisplayTitle(for chat: MessagesChatCandidate) -> String {
        guard useContactsNames else {
            return chat.title
        }

        let participantTitle = contactsResolver
            .uniqueParticipants(from: chat.participantNames, excludingYou: true)
            .map(\.displayName)
            .joined(separator: ", ")
            .trimmed
            .nilIfBlank
        if let participantTitle {
            return participantTitle
        }

        let resolvedConversationTitle = contactsResolver
            .title(rawTitle: chat.title, participantNames: chat.participantNames)
            .trimmed
        if let resolvedConversationTitle = resolvedConversationTitle.nilIfBlank,
           resolvedConversationTitle.localizedCaseInsensitiveCompare(chat.title) != .orderedSame {
            return resolvedConversationTitle
        }

        if let simplified = simplifiedContactTitle(from: chat.title) {
            return simplified
        }

        if let resolvedTitle = contactsResolver.resolvedName(for: chat.title).trimmed.nilIfBlank {
            return resolvedTitle
        }

        return chat.title
    }

    private func chatDisplaySubtitle(for chat: MessagesChatCandidate) -> String {
        let dateRange = AppFormatters.threadDateRange(start: chat.startDate, end: chat.endDate)
        return "\(dateRange) • \(chatMessageCountText(for: chat.messageCount))"
    }

    private func chatMessageCountText(for count: Int) -> String {
        count == 1 ? "1 message" : "\(count.formatted(.number)) messages"
    }

    private func simplifiedContactTitle(from title: String) -> String? {
        let trimmed = title.trimmed
        guard let open = trimmed.firstIndex(of: "("),
              let close = trimmed.lastIndex(of: ")"),
              open < close
        else {
            return nil
        }

        let leading = trimmed[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let innerStart = trimmed.index(after: open)
        let inner = trimmed[innerStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)

        guard !leading.isEmpty, !inner.isEmpty else { return nil }

        let innerLooksLikeHandle = inner.contains("@") || inner.filter(\.isNumber).count >= 7
        return innerLooksLikeHandle ? leading : nil
    }

    private func connectMessagesStore() {
        resetImportState()
        refreshContactAccessState()

        let fdaStatus = FullDiskAccessProbe.currentStatus()
        fullDiskAccessStatus = fdaStatus
        if fdaStatus == .denied {
            logAutoDetect("Skipping automatic Messages lookup — Full Disk Access is denied")
            validationMessage = nil
            showsManualMessagesFallback = false
            return
        }

        logAutoDetect("Starting automatic Messages lookup")
        switch messagesStoreLocationResolver.autoDetectionResult() {
        case .ready(let selectedURL):
            logAutoDetect("Resolved automatic Messages path to \(selectedURL.path)")
            loadMessagesChats(from: selectedURL, autoDetected: true)
        case .messagesFolderMissing(let folderURL):
            messagesFolderURL = folderURL
            logAutoDetect("Messages folder missing at \(folderURL.path)")
            validationMessage = "Messages doesn’t look ready on this Mac yet. Open Messages once and let it load, then try again. If needed, you can choose the Messages folder manually."
            showsManualMessagesFallback = true
        }
    }

    private var fetchMessagesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Messages on This Mac")
                .font(.system(size: 15, weight: .semibold))
            Text("ThreadKeep reads the conversations stored on this Mac. You can import all conversations or choose the Messages folder manually.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button {
                    fetchAllMessagesNow()
                } label: {
                    Label("Import Conversations", systemImage: "tray.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    chooseMessagesStoreManually()
                } label: {
                    Label("Choose Folder Manually", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }

            if let validationMessage {
                Text(validationMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    /// Kicks off a "just do it" import: probe Full Disk Access, auto-detect the Messages
    /// folder, load the chat list, and immediately import everything that loads.
    private func fetchAllMessagesNow() {
        importMode = .all
        pendingAutoImport = true
        connectMessagesStore()
    }

    private var fullDiskAccessCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("ThreadKeep needs Full Disk Access", systemImage: "lock.shield")
                .font(.system(size: 13, weight: .semibold))

            Text("macOS keeps Messages on this Mac inside a protected folder. Grant ThreadKeep Full Disk Access once and it'll automatically read your conversations every time you open the app.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    NSWorkspace.shared.open(FullDiskAccessProbe.systemSettingsURL)
                } label: {
                    Label("Open Full Disk Access Settings", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderedProminent)

                Button("I've Granted Access — Retry") {
                    connectMessagesStore()
                }
                .buttonStyle(.bordered)

                Button {
                    chooseMessagesStoreManually()
                } label: {
                    Label("Choose Folder Manually", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingMessagesChats || isPreparingMessagesImport)
            }

            Text("Drag ThreadKeep from Applications into the Full Disk Access list, switch it on, and come back here — ThreadKeep retries the moment the window is active again.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func chooseMessagesStoreManually() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the Messages folder on this Mac so ThreadKeep can read your conversations."
        panel.directoryURL = messagesStoreLocationResolver.defaultMessagesFolderURL

        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        logAutoDetect("Manual Messages selection picked \(selectedURL.path)")
        loadMessagesChats(from: selectedURL, autoDetected: false)
    }

    private func loadMessagesChats(from selectedURL: URL, autoDetected: Bool) {
        validationMessage = nil
        importProgressMessage = nil
        isLoadingMessagesChats = true
        messagesSearchText = ""
        selectedMessagesChatIDs.removeAll()
        messagesFolderURL = messagesStoreLocationResolver.displayFolderURL(for: selectedURL)
        logAutoDetect("\(autoDetected ? "Automatic" : "Manual") load starting from \(selectedURL.path)")

        Task {
            let contactAccessState = MessagesStoreImporter.currentContactAccessState(enabled: canUseContactsForImport)
            let shouldUseContacts = canResolveContactsForImportList && contactAccessState == .authorized
            do {
                let importer = messagesStoreImporter
                let chats = try await Task.detached(priority: .userInitiated) {
                    try importer.loadChatCandidates(from: selectedURL, useContacts: shouldUseContacts)
                }.value
                await MainActor.run {
                    contactsAccessState = contactAccessState
                    contactsMessage = contactsMessage(for: contactAccessState)
                    let folderURL = messagesStoreLocationResolver.displayFolderURL(for: selectedURL)
                    messagesFolderURL = folderURL
                    messagesChats = chats
                    selectedMessagesChatIDs = defaultSelectedChatIDs(for: chats)
                    validationMessage = chats.isEmpty ? emptyMessagesStateCopy(autoDetected: autoDetected) : nil
                    showsManualMessagesFallback = chats.isEmpty
                    isLoadingMessagesChats = false

                    if !autoDetected && !isDemoImport {
                        messagesStoreLocationResolver.rememberMessagesFolderAccess(for: folderURL)
                    }
                    logAutoDetect("\(autoDetected ? "Automatic" : "Manual") load succeeded from \(folderURL.path) with \(chats.count) conversations")

                    if pendingAutoImport && !chats.isEmpty {
                        pendingAutoImport = false
                        selectedMessagesChatIDs = Set(chats.map(\.id))
                        importSelectedMessagesChats()
                    } else if pendingAutoImport {
                        // Clear the flag so a later retry doesn't auto-import against a stale chat set.
                        pendingAutoImport = false
                    }
                }
            } catch {
                await MainActor.run {
                    contactsAccessState = contactAccessState
                    contactsMessage = contactsMessage(for: contactAccessState)
                    messagesFolderURL = messagesStoreLocationResolver.displayFolderURL(for: selectedURL)
                    messagesChats = []
                    logAutoDetect("\(autoDetected ? "Automatic" : "Manual") load failed from \(selectedURL.path): \(describeAutoDetectFailure(error))")
                    // Re-probe FDA in case chat.db became unreadable between the eager probe
                    // and the actual open. This catches the "Messages folder is visible but
                    // chat.db is still TCC-protected" case and surfaces the Grant FDA card.
                    let reprobed = FullDiskAccessProbe.currentStatus()
                    if reprobed == .denied {
                        fullDiskAccessStatus = reprobed
                        validationMessage = nil
                        showsManualMessagesFallback = false
                    } else {
                        validationMessage = autoDetected
                            ? humanReadableAutoDetectFailure(for: error)
                            : humanReadableManualSelectionFailure(for: error)
                        showsManualMessagesFallback = true
                    }
                    isLoadingMessagesChats = false
                }
            }
        }
    }

    private func importSelectedMessagesChats() {
        guard let folderURL = messagesFolderURL else { return }

        let chatIDs = selectedChatIDsInImportOrder()
        guard !chatIDs.isEmpty else { return }

        isPreparingMessagesImport = true
        validationMessage = nil
        importProgressMessage = nil

        Task {
            guard await authorizeImport() else {
                await MainActor.run {
                    isPreparingMessagesImport = false
                    importProgressMessage = nil
                }
                return
            }

            let importer = messagesStoreImporter
            let shouldUseDemoImport = self.isDemoImport
            let shouldUseContacts = self.canResolveContactsForImportList && self.contactsAccessState == .authorized

            if chatIDs.count == 1, let selectedChatID = chatIDs.first {
                do {
                    let payload = try await Task.detached(priority: .userInitiated) {
                        var payload = try importer.importChat(id: selectedChatID, from: folderURL, useContacts: shouldUseContacts)
                        if shouldUseDemoImport {
                            payload = try payload.preparingDemoArchive(resourceFolderURL: folderURL)
                        }
                        return payload
                    }.value

                    let importSucceeded = await viewModel.importParsedArchive(payload)

                    await MainActor.run {
                        isPreparingMessagesImport = false
                        if importSucceeded {
                            onImportCompleted?(completionMode(for: [payload.archive.id]), [payload.archive.id])
                            closeImportFlow()
                        }
                    }
                } catch {
                    await MainActor.run {
                        isPreparingMessagesImport = false
                        validationMessage = humanReadableImportFailure(for: error)
                    }
                }
                return
            }

            viewModel.isBusy = true
            let result: MessagesBulkImportResult
            do {
                result = try await importer.importChats(
                    ids: chatIDs,
                    from: folderURL,
                    useContacts: shouldUseContacts,
                    progress: { progress in
                        await MainActor.run {
                            importProgressMessage = bulkImportProgressMessage(for: progress)
                        }
                    },
                    onPayload: { payload in
                        let preparedPayload = shouldUseDemoImport
                            ? try payload.preparingDemoArchive(resourceFolderURL: folderURL)
                            : payload
                        try await viewModel.store.importArchive(preparedPayload)
                    }
                )
            } catch {
                await MainActor.run {
                    viewModel.isBusy = false
                    isPreparingMessagesImport = false
                    importProgressMessage = nil
                    validationMessage = humanReadableImportFailure(for: error)
                }
                return
            }

            await MainActor.run {
                viewModel.libraryFilters = LibraryFilters()
                viewModel.selectedThreadID = nil
            }
            await viewModel.refreshLibrary()

            await MainActor.run {
                viewModel.isBusy = false
                isPreparingMessagesImport = false
                if result.importedCount > 0 {
                    viewModel.announceStatus(bulkImportCompletionMessage(for: result))
                    onImportCompleted?(completionMode(for: result.importedThreadIDs), result.importedThreadIDs)
                    closeImportFlow()
                } else {
                    importProgressMessage = nil
                    validationMessage = "ThreadKeep couldn’t bring in those conversations yet. Open Messages on this Mac, let it finish loading, then try again."
                }
            }
        }
    }

    private func humanReadableAutoDetectFailure(for error: Error) -> String {
        switch error {
        case MessagesStoreImportError.databaseNotFound:
            return "ThreadKeep found Messages on this Mac, but there isn’t a local conversation archive ready yet. Open Messages and let it finish loading, then try again."
        case MessagesStoreImportError.databaseUnreadable:
            return "ThreadKeep found Messages on this Mac, but couldn’t read it yet. Open Messages once, then try again. If needed, you can choose the Messages folder manually."
        case MessagesStoreImportError.folderNotFound:
            return "Messages doesn’t look ready on this Mac yet. Open Messages once and let it load, then try again. If needed, you can choose the Messages folder manually."
        default:
            return "ThreadKeep couldn’t automatically read Messages on this Mac yet. You can choose the Messages folder manually if you’d like to try again."
        }
    }

    private func humanReadableManualSelectionFailure(for error: Error) -> String {
        switch error {
        case MessagesStoreImportError.folderNotFound:
            return "ThreadKeep couldn’t open that folder. Choose the Messages folder on this Mac and try again."
        case MessagesStoreImportError.databaseNotFound:
            return "ThreadKeep couldn’t find Messages in the folder you chose. Choose the Messages folder on this Mac and try again."
        case MessagesStoreImportError.databaseUnreadable:
            return "ThreadKeep found Messages in that folder, but couldn’t read it yet. Open Messages once, then try again."
        default:
            return "ThreadKeep couldn’t read from the folder you chose. Make sure it’s the Messages folder on this Mac, then try again."
        }
    }

    private func humanReadableImportFailure(for error: Error) -> String {
        switch error {
        case MessagesStoreImportError.threadNotFound:
            return "That conversation wasn’t available on this Mac anymore. Refresh the list and try again."
        case MessagesStoreImportError.databaseNotFound, MessagesStoreImportError.databaseUnreadable:
            return "ThreadKeep couldn’t bring in that conversation yet. Open Messages on this Mac, let it finish loading, then try again."
        default:
            return "ThreadKeep couldn’t bring in that conversation yet. Please try again in a moment."
        }
    }

    private func bulkImportProgressMessage(for progress: MessagesBulkImportProgress) -> String {
        switch progress.phase {
        case .preparing:
            return "Preparing conversations…"
        case .importing:
            let currentCount = min(progress.completedCount + 1, progress.totalCount)
            return "Adding conversations to your library… \(currentCount.formatted(.number)) of \(progress.totalCount.formatted(.number))"
        case .finishing:
            return "Saving conversation index…"
        }
    }

    private func bulkImportCompletionMessage(for result: MessagesBulkImportResult) -> String {
        if result.skippedCount == 0 {
            return "\(result.importedCount.formatted(.number)) conversations imported."
        }

        return "\(result.importedCount.formatted(.number)) of \(result.totalRequestedCount.formatted(.number)) conversations imported. \(result.skippedCount.formatted(.number)) were not available locally."
    }

    private func emptyMessagesStateCopy(autoDetected: Bool) -> String {
        if autoDetected {
            return "Messages is available on this Mac, but there aren’t any conversations ready to bring in yet. Open Messages and let it finish loading, then scan again."
        }
        return "ThreadKeep opened that Messages folder, but there aren’t any conversations ready to bring in from it yet."
    }

    private func describeAutoDetectFailure(_ error: Error) -> String {
        switch error {
        case MessagesStoreImportError.folderNotFound:
            return "folder not found"
        case MessagesStoreImportError.databaseNotFound:
            return "chat.db missing"
        case MessagesStoreImportError.databaseUnreadable:
            return "chat.db unreadable"
        default:
            return error.localizedDescription
        }
    }

    private func logAutoDetect(_ message: String) {
        print("[ThreadKeep][MessagesAutoDetect] \(message)")
    }

    private func resetImportState() {
        validationMessage = nil
        messagesFolderURL = nil
        contactsMessage = nil
        importProgressMessage = nil
        messagesChats = []
        messagesSearchText = ""
        selectedMessagesChatIDs.removeAll()
        showsManualMessagesFallback = false
    }

    private func defaultSelectedChatIDs(for chats: [MessagesChatCandidate]) -> Set<Int> {
        switch importMode {
        case .all:
            return Set(chats.map(\.id))
        case .single:
            return []
        }
    }

    private func selectedChatIDsInImportOrder() -> [Int] {
        messagesChats
            .filter { selectedMessagesChatIDs.contains($0.id) }
            .map(\.id)
    }

    private func completionMode(for importedThreadIDs: [String]) -> MessagesImportMode {
        if importMode == .single || importedThreadIDs.count == 1 {
            return .single
        }

        if !messagesChats.isEmpty, selectedMessagesChatIDs.count < messagesChats.count {
            return .single
        }

        return .all
    }

    private func selectFilteredChats() {
        selectedMessagesChatIDs.formUnion(filteredMessagesChats.map(\.id))
    }

    private func selectAllChats() {
        selectedMessagesChatIDs = Set(messagesChats.map(\.id))
    }

    private func toggleSelection(for chatID: Int) {
        if selectedMessagesChatIDs.contains(chatID) {
            selectedMessagesChatIDs.remove(chatID)
        } else {
            selectedMessagesChatIDs.insert(chatID)
        }
    }

    private func contactsMessage(for state: MessagesContactAccessState) -> String? {
        if isDemoImport {
            return "This demo build uses only the bundled Mark conversations."
        }

        switch state {
        case .authorized:
            return "Using contact names available on this Mac."
        case .notDetermined:
            return "Turn this on if you would like saved contact names to appear."
        case .denied:
            return "Contacts access is off. ThreadKeep will show phone numbers or email addresses."
        case .disabledByChoice:
            return "Showing phone numbers and email addresses."
        case .unavailable:
            return "Showing phone numbers and email addresses in this build."
        }
    }

    private var contactsAccessButtonTitle: String {
        switch contactsAccessState {
        case .notDetermined:
            return "Allow Contacts Access"
        case .denied:
            return "Open Privacy Settings"
        case .disabledByChoice:
            return "Use Numbers Only"
        case .unavailable:
            return "Contacts Unavailable"
        case .authorized:
            return "Contacts Enabled"
        }
    }

    private var contactsAccessButtonSystemImage: String {
        switch contactsAccessState {
        case .notDetermined:
            return "person.crop.circle.badge.plus"
        case .denied:
            return "gearshape"
        case .disabledByChoice:
            return "number.circle"
        case .unavailable:
            return "exclamationmark.triangle"
        case .authorized:
            return "checkmark.circle"
        }
    }

    private func refreshContactAccessState() {
        contactsAccessState = MessagesStoreImporter.currentContactAccessState(enabled: canUseContactsForImport)
        contactsMessage = contactsMessage(for: contactsAccessState)
    }

    private func requestContactsAccess() {
        switch contactsAccessState {
        case .notDetermined:
            Task {
                let newState = await MessagesStoreImporter.requestContactAccessIfNeeded(enabled: true)
                await contactsResolver.refresh(enabled: canResolveContactsForImportList)
                await MainActor.run {
                    contactsAccessState = newState
                    contactsMessage = contactsMessage(for: newState)
                    NotificationCenter.default.post(name: .threadKeepContactsAccessDidChange, object: newState)
                    if let messagesFolderURL {
                        loadMessagesChats(from: messagesFolderURL, autoDetected: false)
                    }
                }
            }
        case .denied:
            openContactsPrivacySettings()
        case .disabledByChoice:
            useContactsNames = false
        case .unavailable, .authorized:
            break
        }
    }

    private func openContactsPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func closeImportFlow() {
        if let onClose {
            onClose()
        } else {
            dismiss()
        }
    }
}
