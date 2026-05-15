# ThreadKeep v2 — Changes

This tree is a standalone copy of the macOS source drop `ThreadKeep-macOS-source-2026-04-03.zip`, with targeted cleanup. The original source folder was left untouched; every change lives in this `ThreadKeep-v2/` tree.

## Why v2

Audit of the original source uncovered a handful of issues that were either user-visible paper cuts or quiet maintenance debt. The most impactful ones have been applied here:

- **Name consistency.** The app ships as "ThreadKeep" but internally was called "Threadkeeper" — module name, bundle id, UTI, file extension, UserDefaults keys, data folder, sqlite filename, log prefixes. That mismatch leaks out as wrong-looking Application Support folders, ugly console output, and export files with a capital-K in their extension. v2 standardizes on `ThreadKeep` for user-facing identifiers and `threadkeep` (lowercase) for reverse-DNS and filename tokens.
- **Legacy data preserved.** Renaming the data folder would otherwise look like data loss for existing users. v2 ships a one-shot migration that moves `~/Library/Application Support/Threadkeeper/` to `ThreadKeep/`, renames `threadkeeper.sqlite` (with `-shm` / `-wal` companions) to `threadkeep.sqlite`, and rewrites every `threadkeeper.*` UserDefaults key to `threadkeep.*`. The migration is idempotent and logs its work to the unified log.
- **Safer startup.** The original hit `fatalError` if `ArchiveStore` couldn't open on launch, which from the user's point of view looks like the app bouncing in the Dock. v2 shows an NSAlert describing the failure and offers a "Reveal Library Folder" button so the user can investigate before quitting.
- **Logger instead of print.** `MessagesStoreLocationResolver.log` was writing to stdout with a homegrown prefix. v2 routes it through `ThreadKeepLog.messagesAutoDetect` so it is filterable in Console.app by `subsystem:com.threadkeep.app`.
- **Keyboard shortcuts via the menu bar.** v2 adds a `Commands` builder on the main scene that puts Import Messages (⇧⌘I), Export PDF (⌘E), Export Memorial PDF (⌥⌘E), Save Archive (⇧⌘E), Find in Conversation (⌘F), Find Next (⌘G) and Find Previous (⇧⌘G) in the menu bar. They respect `viewModel.selectedThread` and busy state, and enable/disable automatically.
- **Native `.sheet()` for import.** The import flow used to paint a near-black `ZStack` overlay behind the custom view, which fought with window focus and looked out of place on Sonoma/Sequoia. v2 presents `ImportArchiveSheet` as a native SwiftUI sheet with appropriate minimum sizing.
- **Memorial PDF exposed.** The original had a `.memorial` export mode that no UI surfaced — dead code unless users invoked it programmatically. v2 exposes it as a submenu under "Export PDF" and as a dedicated keyboard shortcut.

## New / renamed files

```
Sources/ThreadKeep/                          (was Sources/Threadkeeper/)
├── App/
│   ├── AppFlow.swift                        (new — top-level UI state enum)
│   └── LegacyDataMigration.swift            (new — one-shot Threadkeeper → ThreadKeep migration)
├── Utilities/
│   ├── FullDiskAccessProbe.swift            (new — chat.db reachability check via POSIX open/errno)
│   └── ThreadKeepLogger.swift               (new — centralized os.Logger categories)
├── ThreadKeepApp.swift                      (was ThreadkeeperApp.swift)
├── Models/ThreadKeepModels.swift            (was ThreadkeeperModels.swift)
├── Export/ThreadKeepIPhoneSyncService.swift (was ThreadkeepIPhoneSyncService.swift)
├── Export/ThreadKeepLibraryBundleExporter.swift
├── Export/ThreadKeepMobileArchiveExporter.swift
└── Support/
    ├── ThreadKeep.icns                      (was Threadkeeper.icns)
    └── ThreadKeepInfo.plist                 (was ThreadkeeperInfo.plist)

Tests/ThreadKeepTests/                       (was Tests/ThreadkeeperTests/)
```

Identifiers that changed:
- Bundle id: `com.threadkeeper.app` → `com.threadkeep.app`
- Export UTI / extension: `.threadkeeperarchive` → `.threadkeeparchive`
- Library bundle UTI: `com.threadkeeper.library` → `com.threadkeep.library`
- AppStorage key namespace: `threadkeeper.*` → `threadkeep.*`
- SQLite database filename: `threadkeeper.sqlite` → `threadkeep.sqlite`
- Application Support folder: `Threadkeeper/` → `ThreadKeep/`
- Logger subsystem: `com.threadkeep.app` (new; original used ad-hoc `print()`)

## Not included in this v2 pass

These showed up in the audit but were left for a later pass because they need design input or user decisions:

- **Full Disk Access onboarding UI.** The detection primitive (`FullDiskAccessProbe`) is in place, but nothing shows it yet. A first-run card that says "ThreadKeep needs Full Disk Access to read your Messages" with a single button that deep-links to `x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles` is the intended next step.
- **AppFlow consolidation in `RootView`.** `AppFlow` is defined and ready to use, but `RootView` still drives its five `@State` booleans. Swapping them out is a mechanical change that would benefit from a round of manual QA.
- **"Try a sample archive" button** on the welcome screen — the store method (`ensureSeedArchiveImportedIfNeeded`) exists and a bundled sample is shipped; it just needs a button.
- **Notarization / code-signing** — untouched; needs the user's Developer ID credentials.
- **Replacing the custom `ToolbarControlLabel`** with standard `Label` + `.labelStyle(.iconOnly)` toolbar items.

## Building

This is still a pure Swift Package (no Xcode project). From the `ThreadKeep-v2/` directory:

```sh
swift build -c release
```

The info plist is still injected via linker flags in `Package.swift`, so the resulting binary at `.build/release/ThreadKeep` is a valid macOS application bundle candidate. To produce a `.app`:

```sh
mkdir -p ThreadKeep.app/Contents/MacOS
mkdir -p ThreadKeep.app/Contents/Resources
cp .build/release/ThreadKeep ThreadKeep.app/Contents/MacOS/ThreadKeep
cp Sources/ThreadKeep/Support/ThreadKeep.icns ThreadKeep.app/Contents/Resources/
cp Sources/ThreadKeep/Support/ThreadKeepInfo.plist ThreadKeep.app/Contents/Info.plist
```

## Migration behavior (what users will see)

On first launch of v2 with an existing Threadkeeper library present:

1. `LegacyDataMigration.runIfNeeded()` runs from `AppViewModel.live()` before `ArchiveStore` is constructed.
2. If `~/Library/Application Support/Threadkeeper/` exists and `ThreadKeep/` does not, the folder is moved. If both exist (rare — user manually restored something), the legacy folder is left alone and a warning is logged.
3. Inside the new `ThreadKeep/` folder, `threadkeeper.sqlite{,-shm,-wal}` are renamed to `threadkeep.sqlite*`.
4. Every `threadkeeper.*` key in `UserDefaults.standard` is copied to its `threadkeep.*` twin (only if the twin doesn't already exist), and the old key is removed.
5. A flag is set in UserDefaults (`threadkeep.migration.threadkeeperToThreadKeepCompleted`) so subsequent launches skip the work.

No data is deleted. If the migration can't complete (e.g. disk permissions), the error is logged and the app continues — the user will see an empty library and can re-import, which is the same fallback the old code offered anyway.
