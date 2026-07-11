import Foundation
import Testing
@testable import ThreadKeep

/// Search navigation state: the math behind the "N of M" position label,
/// active-result selection, and query-change resets. These pin the state the
/// highlight styling reads (currentSearchResultIndex + focusedMessageID) so
/// the stage-3 visual work can't drift out from under the label.
struct SearchNavigationTests {
    @MainActor
    private func makeSearchFixture() async throws -> (AppViewModel, ArchiveStore, URL) {
        let tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThreadKeepSearchNav-\(UUID().uuidString)", isDirectory: true)

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let messages = (0..<5).map { index in
            ImportedMessage(
                id: "m\(index)",
                senderID: index.isMultiple(of: 2) ? "other" : "you",
                senderDisplayName: index.isMultiple(of: 2) ? "Pat" : "You",
                isOutgoing: !index.isMultiple(of: 2),
                bodyText: index == 3 ? "nothing to see here" : "wombat sighting number \(index)",
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(index) * 60),
                service: .iMessage,
                attachmentIDs: [],
                replyToMessageID: nil,
                reactions: [],
                metadataJSON: nil
            )
        }
        try await store.importArchive(ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: "thread-search",
                title: "Search Fixture",
                participants: [
                    ImportedParticipant(id: "you", displayName: "You"),
                    ImportedParticipant(id: "other", displayName: "Pat"),
                ],
                messages: messages,
                attachments: [],
                warnings: [],
                sourceFilename: "search.json"
            ),
            sourceKind: .jsonArchive
        ))

        let viewModel = AppViewModel(store: store)
        viewModel.selectThread("thread-search")
        await viewModel.loadSelectedThread()
        return (viewModel, store, tempFolder)
    }

    @Test
    @MainActor
    func searchPopulatesResultsAndFocusesFirstMatch() async throws {
        let (viewModel, _, tempFolder) = try await makeSearchFixture()
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        viewModel.threadSearchQuery = "wombat"
        await viewModel.refreshThreadSearch()

        #expect(viewModel.threadSearchResults.count == 4)
        #expect(viewModel.currentSearchResultIndex == 0)
        #expect(viewModel.focusedMessageID == viewModel.threadSearchResults[0].messageID)
    }

    @Test
    @MainActor
    func navigationWrapsBothDirectionsAndTracksFocus() async throws {
        let (viewModel, _, tempFolder) = try await makeSearchFixture()
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        viewModel.threadSearchQuery = "wombat"
        await viewModel.refreshThreadSearch()
        let count = viewModel.threadSearchResults.count
        #expect(count == 4)

        // Forward through every result and wrap back to the first.
        for expected in [1, 2, 3, 0, 1] {
            viewModel.navigateSearchResult(delta: 1)
            #expect(viewModel.currentSearchResultIndex == expected)
            #expect(viewModel.focusedMessageID == viewModel.threadSearchResults[expected].messageID)
        }

        // Backward wraps too (1 → 0 → 3).
        viewModel.navigateSearchResult(delta: -1)
        viewModel.navigateSearchResult(delta: -1)
        #expect(viewModel.currentSearchResultIndex == 3)

        // The position label's math: index+1 of count, clamped.
        let position = min(viewModel.currentSearchResultIndex + 1, count)
        #expect(position == 4)
    }

    @Test
    @MainActor
    func queryChangeAndClearResetPositionState() async throws {
        let (viewModel, _, tempFolder) = try await makeSearchFixture()
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        viewModel.threadSearchQuery = "wombat"
        await viewModel.refreshThreadSearch()
        viewModel.navigateSearchResult(delta: 1)
        viewModel.navigateSearchResult(delta: 1)
        #expect(viewModel.currentSearchResultIndex == 2)

        // New query: results replaced, position back to the first match.
        viewModel.threadSearchQuery = "nothing"
        await viewModel.refreshThreadSearch()
        #expect(viewModel.threadSearchResults.count == 1)
        #expect(viewModel.currentSearchResultIndex == 0)
        #expect(viewModel.focusedMessageID == viewModel.threadSearchResults[0].messageID)

        // Cleared query: no results, no index, no focused (active) message.
        viewModel.threadSearchQuery = ""
        await viewModel.refreshThreadSearch()
        #expect(viewModel.threadSearchResults.isEmpty)
        #expect(viewModel.currentSearchResultIndex == 0)
        #expect(viewModel.focusedMessageID == nil)
    }

    @Test
    @MainActor
    func singleResultNavigationStaysPut() async throws {
        let (viewModel, _, tempFolder) = try await makeSearchFixture()
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        viewModel.threadSearchQuery = "nothing"
        await viewModel.refreshThreadSearch()
        #expect(viewModel.threadSearchResults.count == 1)

        viewModel.navigateSearchResult(delta: 1)
        #expect(viewModel.currentSearchResultIndex == 0)
        viewModel.navigateSearchResult(delta: -1)
        #expect(viewModel.currentSearchResultIndex == 0)
    }
}
