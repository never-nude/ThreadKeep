import Combine
import Sparkle
import SwiftUI

/// Thin wrapper around Sparkle's standard updater controller.
///
/// Update posture (see ThreadKeepInfo.plist): `SUEnableAutomaticChecks` is left
/// unset, so Sparkle performs no scheduled checks — and therefore no network
/// activity — until the user explicitly opts in via Sparkle's one-time consent
/// prompt or invokes App menu → "Check for Updates…".
@MainActor
final class AppUpdater: ObservableObject {
    private let controller: SPUStandardUpdaterController

    /// Mirrors the updater's own gate (false mid-session while a check runs).
    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

/// App menu → "Check for Updates…", placed directly under "About ThreadKeep".
struct UpdaterCommands: Commands {
    @ObservedObject var updater: AppUpdater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
        }
    }
}
