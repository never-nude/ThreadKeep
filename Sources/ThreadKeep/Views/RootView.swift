import AppKit
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("threadkeep.import.useContactsNames") private var useContactsNames = true

    @State private var isConfirmingThreadDeletion = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var importSheetMode: MessagesImportMode = .all
    @State private var isShowingWelcomeScreen = false
    @State private var isImportFlowActive = false
    @State private var shouldReturnToWelcomeOnImportDismiss = false
    @State private var isSingleConversationFocusMode = false
    @State private var isShowingPrivacyTransition = false
    @State private var pendingSingleConversationThreadID: String?
    @State private var hasAppliedInitialAppFlow = false
    @State private var isSessionUnlocked = false
    @State private var isAuthenticatingLibraryAccess = false
    @State private var isShowingContactSupport = false

    var body: some View {
        Group {
            if !hasAppliedInitialAppFlow {
                launchContent
            } else if isShowingWelcomeScreen {
                onboardingContent
            } else if isShowingPrivacyTransition {
                privacyTransitionContent
            } else {
                mainContent
            }
        }
        .frame(minWidth: 1180, minHeight: 760)
        .alert(item: $viewModel.alertInfo) { info in
            Alert(title: Text(info.title), message: Text(info.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Remove this conversation from your Messages library?",
            isPresented: $isConfirmingThreadDeletion,
            titleVisibility: .visible
        ) {
            Button("Remove Conversation", role: .destructive) {
                Task { await viewModel.deleteSelectedThread() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the selected conversation from ThreadKeep on this Mac.")
        }
        .overlay {
            importPanelOverlay
        }
        .overlay(alignment: .bottom) {
            if let banner = viewModel.activityStatusBanner {
                ActivityStatusBannerView(
                    banner: banner,
                    onDismiss: {
                        viewModel.dismissActivityStatusBanner()
                    }
                )
                    .padding()
            } else if viewModel.isBusy {
                ProgressView()
                    .progressViewStyle(.circular)
                    .padding(12)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding()
            }
        }
        .onChange(of: viewModel.selectedThread?.id) { _, newValue in
            completePrivacyTransitionIfReady(with: newValue)
        }
        .onChange(of: viewModel.initialAppFlow) { _, newValue in
            applyInitialAppFlowIfNeeded(with: newValue)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            lockThreadKeepSession()
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepRequestImport)) { _ in
            beginAuthenticatedImport()
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepRequestContactSupport)) { _ in
            isShowingContactSupport = true
        }
        .sheet(isPresented: $isShowingContactSupport) {
            ContactSupportView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepRequestWiFiSync)) { _ in
            viewModel.beginWiFiSyncToIPhone()
        }
        .sheet(
            isPresented: Binding(
                get: { viewModel.wifiSyncServer != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.endWiFiSyncToIPhone()
                    }
                }
            )
        ) {
            if let server = viewModel.wifiSyncServer {
                IPhoneWiFiSyncView(server: server) {
                    viewModel.endWiFiSyncToIPhone()
                }
            }
        }
        .task {
            resetPrivacyLaunchStateForLaunch()
            applyInitialAppFlowIfNeeded(with: viewModel.initialAppFlow)
            await enforceLockedLaunchPrivacyStateAfterRestoration()
        }
    }

    @ViewBuilder
    private var importPanelOverlay: some View {
        if isImportFlowActive && viewModel.isShowingImportSheet {
            ZStack {
                Color.black.opacity(0.52)
                    .ignoresSafeArea()

                ImportArchiveSheet(
                    preferredMode: importSheetMode,
                    authorizeImport: {
                        await unlockThreadKeepSession(reason: "ThreadKeep needs your Mac password before it can import or show Messages conversations.")
                    },
                    onImportCompleted: { completedMode, importedThreadIDs in
                        handleCompletedImport(mode: completedMode, importedThreadIDs: importedThreadIDs)
                    },
                    onClose: {
                        closeImportFlow()
                    }
                )
                .frame(minWidth: 720, idealWidth: 860, maxWidth: 860, minHeight: 560, idealHeight: 640, maxHeight: 640)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.28), radius: 32, y: 18)
                .padding(32)
            }
            .transition(.opacity)
        }
    }

    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            LibrarySidebarView()
        } detail: {
            Group {
                if let selectedThread = viewModel.selectedThread {
                    ThreadDetailView(thread: selectedThread)
                } else if viewModel.threads.isEmpty {
                    EmptyLibraryDetailView {
                        isSingleConversationFocusMode = false
                        viewModel.focusedThreadIDs = nil
                        columnVisibility = .all
                        openImportFlow(mode: .all, returnToWelcomeAfterDismiss: false)
                    }
                } else {
                    VStack(spacing: 24) {
                        Spacer()

                        Image(systemName: "tray")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)

                        VStack(spacing: 6) {
                            Text("Your Messages Library")
                                .font(.title2.weight(.semibold))

                            Text("Choose a conversation on the left, or use search to find one.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        VStack(spacing: 10) {
                            Button {
                                viewModel.beginWiFiSyncToIPhone()
                            } label: {
                                Label("Send Library to iPhone", systemImage: "iphone")
                                    .font(.headline)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(viewModel.threads.isEmpty || viewModel.isBusy)

                            Text("Every conversation goes straight to ThreadKeep on your iPhone over Wi-Fi.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    returnToWelcomeScreen()
                } label: {
                    Label("Home", systemImage: "house")
                }
                .labelStyle(.iconOnly)
                .help("Show the welcome screen")
                .accessibilityLabel("Home")

                Menu {
                    Button("Send Entire Library…") {
                        viewModel.beginWiFiSyncToIPhone()
                    }
                    .disabled(viewModel.threads.isEmpty)

                    Button("Send This Conversation…") {
                        viewModel.beginWiFiSyncToIPhoneForSelection()
                    }
                    .disabled(viewModel.selectedThread == nil)
                } label: {
                    Label("Send to iPhone", systemImage: "iphone")
                }
                .labelStyle(.iconOnly)
                .disabled(viewModel.isBusy)
                .help("Send conversations to ThreadKeep on your iPhone over Wi-Fi")
                .accessibilityLabel("Send to iPhone")

                Menu {
                    Button("Export PDF") {
                        Task { await viewModel.exportSelectedThreadPDF() }
                    }
                    .disabled(viewModel.selectedThread == nil)

                    Button("Export JSON") {
                        Task { await viewModel.exportSelectedThreadJSON() }
                    }
                    .disabled(viewModel.selectedThread == nil)

                    Button("Export CSV") {
                        Task { await viewModel.exportSelectedThreadCSV() }
                    }
                    .disabled(viewModel.selectedThread == nil)

                    Button("Export Text") {
                        Task { await viewModel.exportSelectedThreadText() }
                    }
                    .disabled(viewModel.selectedThread == nil)

                    Button("Export HTML") {
                        Task { await viewModel.exportSelectedThreadHTML() }
                    }
                    .disabled(viewModel.selectedThread == nil)

                    Divider()

                    Button("Export Library as JSON") {
                        Task { await viewModel.exportVisibleLibraryJSON() }
                    }
                    .disabled(viewModel.threads.isEmpty)

                    Divider()

                    Button("Send to iPhone over Wi-Fi…") {
                        viewModel.beginWiFiSyncToIPhone()
                    }
                    .disabled(viewModel.threads.isEmpty)
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .labelStyle(.iconOnly)
                .disabled(viewModel.isBusy)
                .help("Export conversations")
                .accessibilityLabel("Export")

                if viewModel.selectedThread != nil {
                    Button(role: .destructive) {
                        isConfirmingThreadDeletion = true
                    } label: {
                        Label("Delete Conversation", systemImage: "trash")
                    }
                    .labelStyle(.iconOnly)
                    .help("Delete this imported conversation from ThreadKeep")
                    .accessibilityLabel("Delete Conversation")
                }

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help("Open ThreadKeep settings")
                .accessibilityLabel("Settings")
            }
        }
    }

    private var onboardingContent: some View {
        IntroOnboardingView(
            useContactsNames: contactsOptInBinding,
            beginImport: {
                beginAuthenticatedImport()
            },
            continueWithoutImporting: {
                Task { @MainActor in
                    guard await unlockThreadKeepSession(reason: "ThreadKeep needs your Mac password before it can show saved conversations.") else {
                        return
                    }
                    isSingleConversationFocusMode = false
                    viewModel.focusedThreadIDs = nil
                    columnVisibility = .all
                    isShowingWelcomeScreen = false
                }
            }
        )
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var launchContent: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text("Opening ThreadKeep…")
                    .font(.system(size: 17, weight: .semibold))

                Text("Getting your conversations and library ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var privacyTransitionContent: some View {
        ZStack {
            Color.black.opacity(0.98)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)

                Text("Opening your selected conversation…")
                    .font(.system(size: 17, weight: .semibold))

                Text("You’ll see this conversation first, and the rest of your library will still be there when you want it.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private func returnToWelcomeScreen() {
        lockThreadKeepSession()
        columnVisibility = .all
        isShowingWelcomeScreen = true
    }

    private func beginAuthenticatedImport() {
        Task { @MainActor in
            let startedFromWelcome = isShowingWelcomeScreen
            isSingleConversationFocusMode = false
            viewModel.focusedThreadIDs = nil
            openImportFlow(mode: .all, returnToWelcomeAfterDismiss: startedFromWelcome)
        }
    }

    private func lockThreadKeepSession() {
        isSessionUnlocked = false
        isAuthenticatingLibraryAccess = false
        isSingleConversationFocusMode = false
        isShowingPrivacyTransition = false
        pendingSingleConversationThreadID = nil
        shouldReturnToWelcomeOnImportDismiss = false
        isImportFlowActive = false
        viewModel.resetSessionForPrivacy()
    }

    private func unlockThreadKeepSession(reason: String) async -> Bool {
        if isSessionUnlocked {
            await viewModel.prepareLibraryForAuthenticatedViewing()
            return true
        }

        guard !isAuthenticatingLibraryAccess else {
            return false
        }

        isAuthenticatingLibraryAccess = true
        defer { isAuthenticatingLibraryAccess = false }

        let result = await LocalDeviceAuthenticator.authenticate(reason: reason)
        switch result {
        case .authenticated:
            isSessionUnlocked = true
            await viewModel.prepareLibraryForAuthenticatedViewing()
            return true
        case .cancelled:
            return false
        case .unavailable(let message), .failed(let message):
            viewModel.presentMessage(title: "ThreadKeep Is Locked", message: message)
            return false
        }
    }

    private var contactsOptInBinding: Binding<Bool> {
        Binding(
            get: { useContactsNames },
            set: { newValue in
                useContactsNames = newValue
            }
        )
    }

    private func resetPrivacyLaunchStateForLaunch() {
        lockThreadKeepSession()
        isImportFlowActive = false
        hasAppliedInitialAppFlow = true
        isShowingWelcomeScreen = true
    }

    private func enforceLockedLaunchPrivacyStateAfterRestoration() async {
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(100))
            guard !isSessionUnlocked else { return }
            isImportFlowActive = false
            viewModel.isShowingImportSheet = false
            shouldReturnToWelcomeOnImportDismiss = false
            isShowingPrivacyTransition = false
            pendingSingleConversationThreadID = nil
            isShowingWelcomeScreen = true
        }
    }

    private func handleCompletedImport(mode: MessagesImportMode, importedThreadIDs: [String]) {
        shouldReturnToWelcomeOnImportDismiss = false
        isShowingWelcomeScreen = false

        let shouldFocusImportedOnly = mode == .single || importedThreadIDs.count == 1
        isSingleConversationFocusMode = shouldFocusImportedOnly
        viewModel.focusedThreadIDs = shouldFocusImportedOnly && !importedThreadIDs.isEmpty ? Set(importedThreadIDs) : nil

        if shouldFocusImportedOnly, importedThreadIDs.count <= 1 {
            columnVisibility = .detailOnly
            pendingSingleConversationThreadID = importedThreadIDs.first ?? viewModel.selectedThreadID
            isShowingPrivacyTransition = true
        } else {
            columnVisibility = .all
            pendingSingleConversationThreadID = nil
            isShowingPrivacyTransition = false
        }

        if let firstImportedThreadID = importedThreadIDs.first {
            viewModel.selectThread(firstImportedThreadID)
        }

        Task {
            await viewModel.revealImportedLibrary(
                selecting: importedThreadIDs,
                focusedOnly: shouldFocusImportedOnly
            )
        }
    }

    private func closeImportFlow() {
        viewModel.isShowingImportSheet = false
        isImportFlowActive = false
        if shouldReturnToWelcomeOnImportDismiss {
            isShowingWelcomeScreen = true
        }
        shouldReturnToWelcomeOnImportDismiss = false
        Task { @MainActor in
            await waitForPrivacyTransitionIfNeeded()
        }
    }

    private func openImportFlow(mode: MessagesImportMode, returnToWelcomeAfterDismiss: Bool) {
        importSheetMode = mode
        shouldReturnToWelcomeOnImportDismiss = returnToWelcomeAfterDismiss
        pendingSingleConversationThreadID = nil
        isShowingPrivacyTransition = false
        isImportFlowActive = true
        viewModel.isShowingImportSheet = true
        isShowingWelcomeScreen = returnToWelcomeAfterDismiss
    }

    private func waitForPrivacyTransitionIfNeeded() async {
        guard isShowingPrivacyTransition, let expectedThreadID = pendingSingleConversationThreadID else { return }

        if viewModel.selectedThread?.id == expectedThreadID {
            completePrivacyTransitionIfReady(with: expectedThreadID)
            return
        }

        for _ in 0..<40 {
            if viewModel.selectedThread?.id == expectedThreadID {
                completePrivacyTransitionIfReady(with: expectedThreadID)
                return
            }
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private func completePrivacyTransitionIfReady(with loadedThreadID: String?) {
        guard isShowingPrivacyTransition, let pendingSingleConversationThreadID else { return }
        guard loadedThreadID == pendingSingleConversationThreadID else { return }
        self.pendingSingleConversationThreadID = nil
        isShowingPrivacyTransition = false
    }

    private func applyInitialAppFlowIfNeeded(with flow: InitialAppFlow) {
        guard !hasAppliedInitialAppFlow else { return }
        guard flow != .determining else { return }
        isShowingWelcomeScreen = flow == .welcome
        hasAppliedInitialAppFlow = true
    }

}

private struct EmptyLibraryDetailView: View {
    let importMessages: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "text.bubble")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)

            Text("Your Messages Library")
                .font(.system(size: 24, weight: .bold))

            Text("Import Messages from this Mac to see your conversations here.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)

            Button {
                importMessages()
            } label: {
                Label("Import Messages", systemImage: "tray.and.arrow.down.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct IntroOnboardingView: View {
    @Binding var useContactsNames: Bool
    let beginImport: () -> Void
    let continueWithoutImporting: () -> Void

    var body: some View {
        VStack {
            VStack(alignment: .leading, spacing: 18) {
                Text("Messages Library")
                    .font(.title.bold())

                Text("Create a local library from Messages on this Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Browse saved conversations in one place.", systemImage: "text.bubble")
                    Label("Search names, dates, links, and details.", systemImage: "magnifyingglass")
                    Label("Add all conversations or a smaller set.", systemImage: "tray.and.arrow.down")
                }
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy")
                        .font(.system(size: 15, weight: .semibold))

                    Text("Your library is kept on this Mac.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Exports happen only when you choose them.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Using contact names is optional, and you can change that later.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Toggle("Use contact names and photos when available", isOn: $useContactsNames)
                    .font(.system(size: 13, weight: .medium))

                Text("Turn this off to keep labels as phone numbers or email addresses.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Button {
                    beginImport()
                } label: {
                    Label("Import Messages", systemImage: "tray.and.arrow.down.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Open Without Importing Yet") {
                    continueWithoutImporting()
                }
                .font(.system(size: 12))
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct ActivityStatusBannerView: View {
    let banner: ActivityStatusBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if banner.showsProgress {
                ProgressView()
                    .controlSize(.small)
            }

            Text(banner.message)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)

            if !banner.showsProgress {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss Status")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }
}
