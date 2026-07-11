import AppKit
import SwiftUI

final class ThreadKeepApplicationDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var makeMainContentView: (() -> AnyView)?

    private var mainWindowController: NSWindowController?

    func applicationWillFinishLaunching(_ notification: Notification) {
        clearSessionArtifacts()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            self.openMainWindowIfNeededWithRetries()
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            DispatchQueue.main.async {
                self.openMainWindowIfNeededWithRetries()
            }
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        clearSessionArtifacts()
    }

    private func clearSessionArtifacts() {
        clearSavedApplicationState()
        clearCacheDirectories()
    }

    private func clearSavedApplicationState() {
        let fileManager = FileManager.default
        guard let libraryURL = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first else {
            return
        }

        let savedStateRoot = libraryURL.appendingPathComponent("Saved Application State", isDirectory: true)
        let bundleIDs = [
            Bundle.main.bundleIdentifier,
            "com.threadkeep.app"
        ]
        .compactMap { $0 }

        for bundleID in Set(bundleIDs) {
            let savedStateURL = savedStateRoot.appendingPathComponent("\(bundleID).savedState", isDirectory: true)
            try? fileManager.removeItem(at: savedStateURL)
        }
    }

    private func clearCacheDirectories() {
        let fileManager = FileManager.default
        guard let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }

        let bundleIDs = [
            Bundle.main.bundleIdentifier,
            "com.threadkeep.app"
        ]
        .compactMap { $0 }

        for bundleID in Set(bundleIDs) {
            let cacheURL = cachesURL.appendingPathComponent(bundleID, isDirectory: true)
            try? fileManager.removeItem(at: cacheURL)
        }
    }

    @MainActor
    private func openMainWindowIfNeededWithRetries() {
        openMainWindowIfNeeded()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.openMainWindowIfNeeded()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            self.openMainWindowIfNeeded()
        }
    }

    @MainActor
    private func openMainWindowIfNeeded() {
        let visibleAppWindow = NSApp.windows.contains { window in
            window.isVisible && !window.isMiniaturized
        }

        if !visibleAppWindow {
            openFallbackMainWindow()
            return
        }

        NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func openFallbackMainWindow() {
        if let window = mainWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard let makeMainContentView = Self.makeMainContentView else {
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
            NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "ThreadKeep"
        window.minSize = NSSize(width: 1180, height: 760)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: makeMainContentView())
        window.center()

        mainWindowController = NSWindowController(window: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ThreadKeepApp: App {
    @NSApplicationDelegateAdaptor(ThreadKeepApplicationDelegate.self) private var appDelegate
    @StateObject private var viewModel: AppViewModel
    @StateObject private var updater = AppUpdater()

    init() {
        if CommandLine.arguments.contains("--audit-suffix10") || CommandLine.arguments.contains("--audit-suffix10-reveal") {
            let reveal = CommandLine.arguments.contains("--audit-suffix10-reveal")
            // Block launch until the read-only audit finishes, then exit
            // without ever building UI. The audit runs off the main actor,
            // so waiting here cannot deadlock it.
            let auditDone = DispatchSemaphore(value: 0)
            Task.detached {
                await Suffix10Audit.runOnLibraryAndPrint(reveal: reveal)
                auditDone.signal()
            }
            auditDone.wait()
            exit(EXIT_SUCCESS)
        }

        let viewModel = AppViewModel.live()
        _viewModel = StateObject(wrappedValue: viewModel)
        ThreadKeepApplicationDelegate.makeMainContentView = {
            AnyView(
                RootView()
                    .environmentObject(viewModel)
                    .task {
                        await viewModel.bootstrap()
                    }
            )
        }
    }

    var body: some Scene {
        WindowGroup("ThreadKeep") {
            RootView()
                .environmentObject(viewModel)
                .task {
                    await viewModel.bootstrap()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            UpdaterCommands(updater: updater)
            ThreadKeepCommands(viewModel: viewModel)
            ContactSupportCommands()
        }

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .frame(width: 560, height: 420)
        }
    }
}

/// Help → Contact Support… — the primary entry point to the contact form.
/// Posts a notification that RootView turns into a sheet, mirroring how the
/// import flow is triggered (.threadKeepRequestImport). This keeps a single
/// always-present host and avoids singleton-window reopen fragility.
struct ContactSupportCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Contact Support…") {
                NotificationCenter.default.post(name: .threadKeepRequestContactSupport, object: nil)
            }
        }
    }
}

/// Menu bar commands that also register keyboard shortcuts.
///
/// SwiftUI's `.commands` modifier is the canonical place for this — it gives us menu items
/// *and* global shortcuts for free, with proper enable/disable based on the view-model state.
private struct ThreadKeepCommands: Commands {
    @ObservedObject var viewModel: AppViewModel

    var body: some Commands {
        // File → Import Messages…  (⌘O is already taken in the defaults; use ⇧⌘I instead.)
        CommandGroup(after: .newItem) {
            Divider()
            Button("Import Messages…") {
                NotificationCenter.default.post(name: .threadKeepRequestImport, object: nil)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }

        // File → Export PDF… / Export JSON…
        CommandGroup(after: .saveItem) {
            Button("Export PDF…") {
                Task { await viewModel.exportSelectedThreadPDF() }
            }
            .keyboardShortcut("e", modifiers: [.command])
            .disabled(viewModel.selectedThread == nil || viewModel.isBusy)

            Button("Export JSON…") {
                Task { await viewModel.exportSelectedThreadJSON() }
            }
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(viewModel.selectedThread == nil || viewModel.isBusy)

            Button("Export Library as JSON…") {
                Task { await viewModel.exportVisibleLibraryJSON() }
            }
            .disabled(viewModel.threads.isEmpty || viewModel.isBusy)
        }

        // Edit → Find in Conversation (⌘F) / Find Next (⌘G) / Find Previous (⇧⌘G)
        CommandGroup(after: .textEditing) {
            Button("Find in Conversation") {
                // Route focus to the search field by clearing & re-setting the query;
                // SwiftUI @FocusState wiring in ThreadDetailView picks it up.
                NotificationCenter.default.post(name: .threadKeepFocusSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command])
            .disabled(viewModel.selectedThread == nil)

            Button("Find Next") {
                viewModel.navigateSearchResult(delta: 1)
            }
            .keyboardShortcut("g", modifiers: [.command])
            .disabled(viewModel.threadSearchResults.isEmpty)

            Button("Find Previous") {
                viewModel.navigateSearchResult(delta: -1)
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(viewModel.threadSearchResults.isEmpty)
        }
    }
}

extension Notification.Name {
    /// Posted when any import entry point should route through RootView's privacy gate.
    static let threadKeepRequestImport = Notification.Name("com.threadkeep.app.requestImport")

    /// Posted when the user picks "Find in Conversation" from the Edit menu or hits ⌘F.
    static let threadKeepFocusSearch = Notification.Name("com.threadkeep.app.focusSearch")

    /// Posted after Contacts permission changes so visible resolvers can re-read names and photos.
    static let threadKeepContactsAccessDidChange = Notification.Name("com.threadkeep.app.contactsAccessDidChange")

    /// Posted when the user picks Help → Contact Support… (or the Settings link).
    static let threadKeepRequestContactSupport = Notification.Name("com.threadkeep.app.requestContactSupport")
}
