import Foundation
import CoreGraphics
import PDFKit
import SQLite3
import Testing
@testable import ThreadKeep

struct ArchiveValidationTests {
    @Test
    @MainActor
    func appViewModelBootstrapShowsWelcomeWhenLibraryIsEmpty() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelEmpty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let viewModel = AppViewModel(store: store)

        await viewModel.bootstrap()

        #expect(viewModel.initialAppFlow == .welcome)
        #expect(viewModel.threads.isEmpty)
    }

    @Test
    @MainActor
    func appViewModelBootstrapStartsAtWelcomeAndKeepsImportedConversationsWhenArchiveExists() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelLibrary-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample.json")
        try await store.importArchive(payload)

        let viewModel = AppViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.initialAppFlow == .welcome)
        #expect(viewModel.threads.isEmpty)
        #expect(viewModel.selectedThreadID == nil)
        #expect(viewModel.selectedThread == nil)

        let storedThreads = try await store.loadThreadSummaries(filters: LibraryFilters())
        #expect(storedThreads.count == 1)

        await viewModel.prepareLibraryForAuthenticatedViewing()
        #expect(viewModel.threads.count == 1)
        #expect(viewModel.selectedThreadID == nil)
        #expect(viewModel.selectedThread == nil)
    }

    @Test
    @MainActor
    func appViewModelLaunchKeepsLibraryHomeUntilSelection() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelLaunchGuard-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample.json")
        try await store.importArchive(payload)

        let viewModel = AppViewModel(store: store)
        await viewModel.bootstrap()
        await viewModel.prepareLibraryForAuthenticatedViewing()

        #expect(viewModel.initialAppFlow == .welcome)
        #expect(viewModel.threads.count == 1)
        #expect(viewModel.selectedThreadID == nil)
        #expect(viewModel.selectedThread == nil)

        viewModel.selectThread(payload.archive.id)
        await viewModel.refreshLibrary()
        #expect(viewModel.selectedThreadID == payload.archive.id)
        #expect(viewModel.selectedThread?.id == payload.archive.id)
    }

    @Test
    @MainActor
    func appViewModelPrivacyResetClearsSessionStateButPreservesStoredLibrary() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelPrivacyReset-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample.json")
        try await store.importArchive(payload)

        let viewModel = AppViewModel(store: store)
        await viewModel.bootstrap()
        await viewModel.prepareLibraryForAuthenticatedViewing()
        viewModel.selectThread(payload.archive.id)
        await viewModel.refreshLibrary()

        #expect(viewModel.threads.count == 1)
        #expect(viewModel.selectedThread?.id == payload.archive.id)

        viewModel.resetSessionForPrivacy()

        #expect(viewModel.threads.isEmpty)
        #expect(viewModel.selectedThreadID == nil)
        #expect(viewModel.selectedThread == nil)
        #expect(viewModel.threadSearchQuery.isEmpty)
        #expect(viewModel.isShowingImportSheet == false)

        let storedThreads = try await store.loadThreadSummaries(filters: LibraryFilters())
        #expect(storedThreads.count == 1)

        await viewModel.prepareLibraryForAuthenticatedViewing()
        #expect(viewModel.threads.count == 1)
    }

    @Test
    @MainActor
    func appViewModelRevealImportedLibrarySelectsImportedThreadAfterPrivacyGate() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelRevealImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample.json")
        try await store.importArchive(payload)

        let viewModel = AppViewModel(store: store)
        await viewModel.bootstrap()

        #expect(viewModel.initialAppFlow == .welcome)
        #expect(viewModel.threads.isEmpty)
        #expect(viewModel.selectedThread == nil)

        await viewModel.revealImportedLibrary(selecting: [payload.archive.id])

        #expect(viewModel.threads.count == 1)
        #expect(viewModel.selectedThreadID == payload.archive.id)
        #expect(viewModel.selectedThread?.id == payload.archive.id)
    }

    @Test
    @MainActor
    func appViewModelRevealFocusedImportHidesPreviouslyImportedThreads() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAppViewModelFocusedImport-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let firstPayload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample-1.json")
        let secondJSON = validArchiveJSON
            .replacingOccurrences(of: "\"thread_id\": \"thread-1\"", with: "\"thread_id\": \"thread-2\"")
            .replacingOccurrences(of: "\"thread_title\": \"Sample Thread\"", with: "\"thread_title\": \"Second Thread\"")
            .replacingOccurrences(of: "\"id\": \"msg-1\"", with: "\"id\": \"msg-3\"")
            .replacingOccurrences(of: "\"id\": \"msg-2\"", with: "\"id\": \"msg-4\"")
            .replacingOccurrences(of: "\"id\": \"att-1\"", with: "\"id\": \"att-2\"")
            .replacingOccurrences(of: "\"attachment_ids\": [\"att-1\"]", with: "\"attachment_ids\": [\"att-2\"]")
        let secondPayload = try ArchiveParser.parse(data: Data(secondJSON.utf8), sourceFilename: "sample-2.json")

        try await store.importArchive(firstPayload)
        try await store.importArchive(secondPayload)

        let viewModel = AppViewModel(store: store)
        await viewModel.bootstrap()

        await viewModel.revealImportedLibrary(selecting: [secondPayload.archive.id], focusedOnly: true)

        #expect(viewModel.threads.map(\.id) == [secondPayload.archive.id])
        #expect(viewModel.selectedThreadID == secondPayload.archive.id)
        #expect(viewModel.selectedThread?.id == secondPayload.archive.id)

        let storedThreads = try await store.loadThreadSummaries(filters: LibraryFilters())
        #expect(Set(storedThreads.map(\.id)) == Set([firstPayload.archive.id, secondPayload.archive.id]))
    }

    @Test
    func mergedThreadDetailHidesMessagesWithSameMessagesRowID() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMergedMessageDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let firstPayload = try makeDedupPayload(
            id: "thread-david-sms",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "sms-1", body: "Yo can you FaceTime? My glove box fell off", timestamp: "2019-06-13T18:18:57Z", isOutgoing: true, messagesRowID: 100),
                (id: "sms-2", body: "What's your favorite Subaru SUV?", timestamp: "2019-06-13T20:23:21Z", isOutgoing: true, messagesRowID: 101)
            ]
        )
        let secondPayload = try makeDedupPayload(
            id: "thread-david-imessage",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "imessage-1", body: "Yo can you FaceTime? My glove box fell off", timestamp: "2019-06-13T18:18:57Z", isOutgoing: true, messagesRowID: 100),
                (id: "imessage-2", body: "What's your favorite Subaru SUV?", timestamp: "2019-06-13T20:23:21Z", isOutgoing: true, messagesRowID: 101),
                (id: "imessage-3", body: "I prefer their sedans over the suvs", timestamp: "2019-06-13T20:24:45Z", isOutgoing: false, messagesRowID: 102)
            ]
        )

        try await store.importArchive(firstPayload)
        try await store.importArchive(secondPayload)

        let storedSummaries = try await store.loadThreadSummaries(filters: LibraryFilters())
        #expect(storedSummaries.map(\.messageCount).reduce(0, +) == 3)

        let detail = try await #require(store.loadMergedThreadDetail(
            id: "merged-david",
            title: "David Demarco",
            threadIDs: [firstPayload.archive.id, secondPayload.archive.id]
        ))

        #expect(detail.messages.map(\.bodyText) == [
            "Yo can you FaceTime? My glove box fell off",
            "What's your favorite Subaru SUV?",
            "I prefer their sedans over the suvs"
        ])
        #expect(detail.statistics.totalMessages == 3)
    }

    @Test
    func threadDetailHidesExactTimestampFallbackDuplicates() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepTimestampDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-exact-duplicates",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "m1", body: "Who makes a reliable suv?", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: nil),
                (id: "m2", body: "Who makes a reliable suv?", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: nil),
                (id: "m3", body: "Who makes a reliable suv?", timestamp: "2019-06-13T20:25:27Z", isOutgoing: false, messagesRowID: nil)
            ]
        )

        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))

        #expect(detail.messages.map(\.bodyText) == [
            "Who makes a reliable suv?",
            "Who makes a reliable suv?"
        ])
        #expect(detail.messages.map(\.isOutgoing) == [true, false])
        #expect(detail.statistics.totalMessages == 2)
    }

    @Test
    func threadDetailHidesMixedGuidAndRowIDSourceDuplicates() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMixedSourceDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeMetadataDedupPayload(
            id: "thread-mixed-source-duplicates",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (
                    id: "m-rowid",
                    body: "Lunch is at noon",
                    timestamp: "2019-06-13T20:25:27Z",
                    isOutgoing: false,
                    metadataJSON: "{\"import_source\":\"messages_mac_beta\",\"messages_rowid\":777}"
                ),
                (
                    id: "m-guid-rowid",
                    body: "Lunch is at noon.",
                    timestamp: "2019-06-13T20:25:27Z",
                    isOutgoing: false,
                    metadataJSON: "{\"import_source\":\"messages_mac_beta\",\"messages_guid\":\"ABC-777\",\"messages_rowid\":777}"
                ),
                (
                    id: "m-next",
                    body: "See you there",
                    timestamp: "2019-06-13T20:26:27Z",
                    isOutgoing: false,
                    metadataJSON: "{\"import_source\":\"messages_mac_beta\",\"messages_guid\":\"ABC-778\",\"messages_rowid\":778}"
                )
            ]
        )

        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == [
            "Lunch is at noon",
            "See you there"
        ])
        #expect(detail.statistics.totalMessages == 2)
    }

    @Test
    func distinctSourceMessagesWithExactSameTextAndTimestampAreCollapsed() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepExactSourceDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-exact-source-repeat",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "m1", body: "Ok", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: 200),
                (id: "m2", body: "Ok", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: 201)
            ]
        )

        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == ["Ok"])
        #expect(detail.statistics.totalMessages == 1)
    }

    @Test
    func distinctSourceMessagesWithinSameDisplayedSecondAreCollapsed() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepSecondSourceDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-visible-second-repeat",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "m1", body: "Ok", timestamp: Date(timeIntervalSince1970: 1_560_459_927.100), isOutgoing: true, messagesRowID: 210),
                (id: "m2", body: "Ok", timestamp: Date(timeIntervalSince1970: 1_560_459_927.900), isOutgoing: true, messagesRowID: 211)
            ]
        )

        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == ["Ok"])
        #expect(detail.statistics.totalMessages == 1)
    }

    @Test
    func distinctSourceMessagesWithSameTextAtDifferentTimesArePreserved() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepDistinctTimeDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-legitimate-repeat",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "m1", body: "Ok", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: 200),
                (id: "m2", body: "Ok", timestamp: "2019-06-13T20:25:28Z", isOutgoing: true, messagesRowID: 201)
            ]
        )

        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == ["Ok", "Ok"])
        #expect(detail.statistics.totalMessages == 2)
    }

    @Test
    func reimportingSameSourceConversationDoesNotDoubleOrDropMessages() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepReimportSourceDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-reimport",
            title: "David Demarco",
            participantName: "David Demarco",
            messages: [
                (id: "m1", body: "First source message", timestamp: "2019-06-13T20:25:27Z", isOutgoing: true, messagesRowID: 300),
                (id: "m2", body: "Second source message", timestamp: "2019-06-13T20:26:27Z", isOutgoing: false, messagesRowID: 301)
            ]
        )

        try await store.importArchive(payload)
        try await store.importArchive(payload)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == ["First source message", "Second source message"])
        #expect(detail.statistics.totalMessages == 2)
    }

    @Test
    func reimportingSameMessagesChatWithNewTitleReplacesOldInternalThreadID() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepReimportMessagesChatTitleChange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let oldPayload = try makeDedupPayload(
            id: "messages-mac-24-oldhash",
            title: "5163612295",
            participantName: "5163612295",
            messages: [
                (id: "old-1", body: "Older source message", timestamp: "2022-11-28T17:15:56Z", isOutgoing: true, messagesRowID: 400),
                (id: "old-2", body: "Middle source message", timestamp: "2023-01-01T17:15:56Z", isOutgoing: false, messagesRowID: 401)
            ]
        )
        let renamedPayload = try makeDedupPayload(
            id: "messages-mac-24-newhash",
            title: "Chris Buonincontri",
            participantName: "Chris Buonincontri",
            messages: [
                (id: "new-1", body: "Older source message", timestamp: "2022-11-28T17:15:56Z", isOutgoing: true, messagesRowID: 400),
                (id: "new-2", body: "Middle source message", timestamp: "2023-01-01T17:15:56Z", isOutgoing: false, messagesRowID: 401),
                (id: "new-3", body: "Latest source message", timestamp: "2026-05-18T17:15:56Z", isOutgoing: false, messagesRowID: 402)
            ]
        )

        try await store.importArchive(oldPayload)
        try await store.importArchive(renamedPayload)

        let summaries = try await store.loadThreadSummaries(filters: LibraryFilters())
        #expect(summaries.map(\.id) == [renamedPayload.archive.id])
        #expect(summaries.first?.startDate == testDate("2022-11-28T17:15:56Z"))
        #expect(summaries.first?.messageCount == 3)

        let detail = try await #require(store.loadThreadDetail(id: renamedPayload.archive.id))
        #expect(detail.messages.map(\.bodyText) == [
            "Older source message",
            "Middle source message",
            "Latest source message"
        ])
    }

    @Test
    func validArchiveParsesSuccessfully() throws {
        let payload = try ArchiveParser.parse(data: Data(validArchiveJSON.utf8), sourceFilename: "sample.json")

        #expect(payload.archive.id == "thread-1")
        #expect(payload.archive.title == "Sample Thread")
        #expect(payload.archive.participants.count == 2)
        #expect(payload.archive.messages.count == 2)
        #expect(payload.archive.attachments.count == 1)
    }

    @Test
    func missingAttachmentReferenceThrowsReadableError() throws {
        let json = validArchiveJSON.replacingOccurrences(of: "\"attachment_ids\": [\"att-1\"]", with: "\"attachment_ids\": [\"missing-att\"]")

        #expect(throws: ArchiveValidationError.self) {
            try ArchiveParser.parse(data: Data(json.utf8), sourceFilename: "broken.json")
        }
    }

    @Test
    func messagesPDFLineParsingBuildsConversation() throws {
        let lines: [PDFTranscriptLine] = [
            PDFTranscriptLine(
                text: "Sam Rivera",
                pageIndex: 0,
                bounds: CGRect(x: 220, y: 744, width: 160, height: 18),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "Friday, March 1, 2026",
                pageIndex: 0,
                bounds: CGRect(x: 210, y: 692, width: 190, height: 16),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "Are you still at the studio?",
                pageIndex: 0,
                bounds: CGRect(x: 342, y: 640, width: 200, height: 16),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "9:12 AM",
                pageIndex: 0,
                bounds: CGRect(x: 470, y: 620, width: 72, height: 12),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "Sam",
                pageIndex: 0,
                bounds: CGRect(x: 72, y: 584, width: 44, height: 14),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "Yes, finishing the kiln notes now.",
                pageIndex: 0,
                bounds: CGRect(x: 72, y: 556, width: 218, height: 16),
                pageSize: CGSize(width: 612, height: 792)
            ),
            PDFTranscriptLine(
                text: "9:14 AM",
                pageIndex: 0,
                bounds: CGRect(x: 120, y: 538, width: 72, height: 12),
                pageSize: CGSize(width: 612, height: 792)
            )
        ]

        let archive = try MessagesPDFImporter().parseExtractedLines(
            lines,
            sourceFilename: "sam-rivera.pdf",
            documentTitle: nil,
            fallbackDate: nil
        )

        #expect(archive.title == "Sam Rivera")
        #expect(archive.messages.count == 2)
        #expect(archive.participants.contains(where: { $0.displayName == "You" }))
        #expect(archive.participants.contains(where: { $0.displayName == "Sam" }))
        #expect(archive.messages[0].isOutgoing)
        #expect(archive.messages[0].bodyText == "Are you still at the studio?")
        #expect(archive.messages[1].senderDisplayName == "Sam")
        #expect(archive.messages[1].bodyText == "Yes, finishing the kiln notes now.")
    }

    @Test
    func messagesStoreImportBuildsArchiveSnapshot() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT, uti TEXT);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO chat VALUES (1, 'sam@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'sam@example.com', 'Sam');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-100', 'Hello from me', NULL, 60, 1, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (101, 'guid-101', 'Reply from Sam', NULL, 120, 0, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO chat_message_join VALUES (1, 101);
            INSERT INTO attachment VALUES (1, '/tmp/photo.jpg', 'image/jpeg', 'photo.jpg', 'public.jpeg');
            INSERT INTO message_attachment_join VALUES (101, 1);
            """
        )

        let importer = MessagesStoreImporter()
        let chats = try importer.loadChatCandidates(from: tempFolder)
        #expect(chats.count == 1)
        #expect(chats[0].title == "Sam")
        #expect(chats[0].messageCount == 2)

        let payload = try importer.importChat(id: 1, from: tempFolder)
        #expect(payload.sourceKind == .messagesMacBeta)
        #expect(payload.archive.title == "Sam")
        #expect(payload.archive.messages.count == 2)
        #expect(payload.archive.attachments.count == 1)
        #expect(payload.archive.messages[0].isOutgoing)
        #expect(payload.archive.messages[1].senderDisplayName == "Sam")

        let payloadFromDatabaseFile = try importer.importChat(id: 1, from: dbURL)
        #expect(payloadFromDatabaseFile.archive.messages.count == 2)
        #expect(payloadFromDatabaseFile.archive.attachments.first?.localPath == "/tmp/photo.jpg")
    }

    @Test
    func messagesStoreImportSkipsUndecodableAttributedBodyWithoutCrashing() throws {
        // Mirrors the `01_diagnostics/01_attributedbody` fixture: 4 messages, 2 of which carry a
        // legacy `streamtyped` attributedBody archive that NSUnarchiver cannot decode (it raises
        // an Obj-C NSException). Before the TKTryUnarchive fix this aborted the whole import; now
        // the two undecodable rows must be skipped and the two plain-text rows imported.
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepAttributedBodyCrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        // A valid `streamtyped` signature followed by a truncated, non-UTF-8 body: NSUnarchiver
        // recognizes the typedstream header and then throws while decoding the corrupt remainder.
        let malformedBlobHex = "040b73747265616d747970656481e803"
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, 'pat@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'pat@example.com', 'Pat');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-100', 'First good message', NULL, 60, 1, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (101, 'guid-101', NULL, X'\(malformedBlobHex)', 120, 0, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (102, 'guid-102', 'Second good message', NULL, 180, 0, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (103, 'guid-103', NULL, X'\(malformedBlobHex)', 240, 0, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO chat_message_join VALUES (1, 101);
            INSERT INTO chat_message_join VALUES (1, 102);
            INSERT INTO chat_message_join VALUES (1, 103);
            """
        )

        let importer = MessagesStoreImporter()
        // Must not throw or abort even though two rows carry undecodable attributedBody blobs.
        let payload = try importer.importChat(id: 1, from: tempFolder)

        #expect(payload.archive.messages.count == 2)
        #expect(payload.archive.messages.map(\.bodyText) == ["First good message", "Second good message"])
    }

    @Test
    func messagesStoreChatCandidatesUseRenderableMessageDateRange() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesStoreRenderableRange-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, 'chris@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'chris@example.com', 'Chris');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-empty', NULL, NULL, 60, 0, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (101, 'guid-whitespace', '   ', NULL, 90, 0, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (102, 'guid-visible', 'Visible message', NULL, 120, 0, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO chat_message_join VALUES (1, 101);
            INSERT INTO chat_message_join VALUES (1, 102);
            """
        )

        let importer = MessagesStoreImporter()
        let chats = try importer.loadChatCandidates(from: tempFolder)
        let chat = try #require(chats.first)

        #expect(chat.startDate == Date(timeIntervalSinceReferenceDate: 120))
        #expect(chat.endDate == Date(timeIntervalSinceReferenceDate: 120))
        #expect(chat.messageCount == 1)

        let payload = try importer.importChat(id: 1, from: tempFolder)
        #expect(payload.archive.dateRange?.lowerBound == Date(timeIntervalSinceReferenceDate: 120))
        #expect(payload.archive.dateRange?.upperBound == Date(timeIntervalSinceReferenceDate: 120))
        #expect(payload.archive.messages.map(\.bodyText) == ["Visible message"])
    }

    @Test
    func messagesStoreBulkImportKeepsConversationsSeparate() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesStoreBulkImport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, 'sam@example.com', NULL, 'iMessage');
            INSERT INTO chat VALUES (2, 'taylor@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'sam@example.com', 'Sam');
            INSERT INTO handle VALUES (2, 'taylor@example.com', 'Taylor');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO chat_handle_join VALUES (2, 2);
            INSERT INTO message VALUES (100, 'guid-100', 'Hello Sam', NULL, 60, 1, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (101, 'guid-101', 'Hi there', NULL, 120, 0, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (200, 'guid-200', 'Taylor thread', NULL, 180, 0, 'iMessage', 2, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO chat_message_join VALUES (1, 101);
            INSERT INTO chat_message_join VALUES (2, 200);
            """
        )

        let progressRecorder = TestRecorder<MessagesBulkImportProgress>()
        let payloadRecorder = TestRecorder<ParsedArchivePayload>()

        let result = try await MessagesStoreImporter().importChats(
            ids: [1, 2],
            from: tempFolder,
            progress: { progress in
                await progressRecorder.append(progress)
            },
            onPayload: { payload in
                await payloadRecorder.append(payload)
            }
        )

        let progressUpdates = await progressRecorder.snapshot()
        let importedPayloads = await payloadRecorder.snapshot()

        #expect(result.importedCount == 2)
        #expect(result.skippedCount == 0)
        #expect(importedPayloads.count == 2)
        #expect(Set(importedPayloads.map(\.archive.title)) == Set(["Sam", "Taylor"]))
        #expect(importedPayloads.first(where: { $0.archive.title == "Sam" })?.archive.messages.count == 2)
        #expect(importedPayloads.first(where: { $0.archive.title == "Taylor" })?.archive.messages.count == 1)
        let sawSamProgress = progressUpdates.contains { progress in
            progress.phase == .importing && progress.currentChatTitle == "Sam"
        }
        let sawTaylorProgress = progressUpdates.contains { progress in
            progress.phase == .importing && progress.currentChatTitle == "Taylor"
        }
        #expect(progressUpdates.first?.phase == .preparing)
        #expect(sawSamProgress)
        #expect(sawTaylorProgress)
        #expect(progressUpdates.last?.phase == .finishing)
    }

    @Test
    func messagesStoreBulkImportSkipsMissingConversationAndContinues() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesStoreBulkImportSkip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, 'sam@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'sam@example.com', 'Sam');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-100', 'Hello Sam', NULL, 60, 1, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            """
        )

        let payloadRecorder = TestRecorder<ParsedArchivePayload>()

        let result = try await MessagesStoreImporter().importChats(
            ids: [1, 999],
            from: tempFolder,
            onPayload: { payload in
                await payloadRecorder.append(payload)
            }
        )

        let importedPayloads = await payloadRecorder.snapshot()

        #expect(result.importedCount == 1)
        #expect(result.skippedCount == 1)
        #expect(result.failures.first?.chatID == 999)
        #expect(importedPayloads.count == 1)
        #expect(importedPayloads[0].archive.title == "Sam")
    }

    @Test
    func messagesStoreImportDeduplicatesRepeatedAttachmentRows() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesStoreDuplicateAttachments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT, uti TEXT);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO chat VALUES (1, '+13038867882', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, '+13038867882', '+13038867882');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-100', 'Here is the file again', NULL, 60, 0, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO attachment VALUES (1, '/tmp/photo.jpg', 'image/jpeg', 'photo.jpg', 'public.jpeg');
            INSERT INTO message_attachment_join VALUES (100, 1);
            INSERT INTO message_attachment_join VALUES (100, 1);
            """
        )

        let payload = try MessagesStoreImporter().importChat(id: 1, from: tempFolder)
        #expect(payload.archive.messages.count == 1)
        #expect(payload.archive.attachments.count == 1)
        #expect(payload.archive.messages[0].attachmentIDs == [payload.archive.attachments[0].id])
    }

    @Test
    func messagesStoreImportDecodesLegacyAttributedBodies() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepLegacyMessagesStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        let attributedBody = try #require(
            legacyTypedstreamData(from: NSAttributedString(string: "Legacy typedstream body"))
        )

        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, '+12016029782', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, '+12016029782', '+12016029782');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO chat_message_join VALUES (1, 100);
            """
        )

        let insert = try database.prepare(
            """
            INSERT INTO message (
                ROWID, guid, text, attributedBody, date, is_from_me, service, handle_id, associated_message_guid
            ) VALUES (?1, ?2, NULL, ?3, ?4, ?5, ?6, ?7, NULL);
            """
        )
        defer { database.finalize(insert) }
        database.bind(100, at: 1, in: insert)
        database.bind("guid-100", at: 2, in: insert)
        sqlite3_bind_blob(insert, 3, (attributedBody as NSData).bytes, Int32(attributedBody.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        database.bind(60, at: 4, in: insert)
        database.bind(false, at: 5, in: insert)
        database.bind("iMessage", at: 6, in: insert)
        database.bind(1, at: 7, in: insert)
        try database.step(insert)

        let payload = try MessagesStoreImporter().importChat(id: 1, from: tempFolder)
        #expect(payload.archive.messages.count == 1)
        #expect(payload.archive.messages[0].bodyText == "Legacy typedstream body")
    }

    @Test
    func messagesStoreLocationResolverFindsMessagesFolderAutomatically() throws {
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesHome-\(UUID().uuidString)", isDirectory: true)
        let resolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome)
        let messagesFolder = resolver.defaultMessagesFolderURL
        try FileManager.default.createDirectory(at: messagesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        let databaseURL = messagesFolder.appendingPathComponent("chat.db")
        _ = FileManager.default.createFile(atPath: databaseURL.path, contents: Data(), attributes: nil)

        #expect(resolver.autoDetectionResult() == .ready(messagesFolder))
        #expect(resolver.autoDetectedMessagesStoreURL() == messagesFolder)
    }

    @Test
    func messagesStoreLocationResolverReportsMissingMessagesFolder() {
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesMissingHome-\(UUID().uuidString)", isDirectory: true)
        let resolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome)

        #expect(resolver.autoDetectionResult() == .messagesFolderMissing(resolver.defaultMessagesFolderURL))
        #expect(resolver.autoDetectedMessagesStoreURL() == nil)
    }

    @Test
    func messagesStoreLocationResolverTreatsMessagesFolderAsReadyWhenDatabaseIsMissing() throws {
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesArchiveUnavailable-\(UUID().uuidString)", isDirectory: true)
        let resolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome)
        let messagesFolder = resolver.defaultMessagesFolderURL
        try FileManager.default.createDirectory(at: messagesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        #expect(resolver.autoDetectionResult() == .ready(messagesFolder))
        #expect(resolver.autoDetectedMessagesStoreURL() == messagesFolder)
    }

    @Test
    func messagesStoreLocationResolverNormalizesChatDBSelectionsToTheirFolder() {
        let fakeHome = URL(fileURLWithPath: "/tmp/ThreadKeepMessagesHome", isDirectory: true)
        let resolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome)
        let databaseURL = resolver.defaultMessagesFolderURL.appendingPathComponent("chat.db")

        #expect(resolver.displayFolderURL(for: databaseURL) == resolver.defaultMessagesFolderURL)
        #expect(resolver.displayFolderURL(for: resolver.defaultMessagesFolderURL) == resolver.defaultMessagesFolderURL)
    }

    @Test
    func messagesStoreLocationResolverRestoresSavedMessagesFolderAccess() throws {
        let fakeHome = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMessagesSavedAccess-\(UUID().uuidString)", isDirectory: true)
        let defaultsSuiteName = "ThreadKeepMessagesSavedAccess-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsSuiteName))
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defer { defaults.removePersistentDomain(forName: defaultsSuiteName) }

        let resolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome, userDefaults: defaults)
        let messagesFolder = resolver.defaultMessagesFolderURL
        try FileManager.default.createDirectory(at: messagesFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fakeHome) }

        resolver.rememberMessagesFolderAccess(for: messagesFolder)

        let restoredResolver = MessagesStoreLocationResolver(homeDirectoryURL: fakeHome, userDefaults: defaults)
        let expectedFolder = messagesFolder.resolvingSymlinksInPath()
        let restoredFolder = try #require(restoredResolver.autoDetectedMessagesStoreURL()).resolvingSymlinksInPath()

        #expect(restoredResolver.autoDetectionResult() == .ready(restoredResolver.autoDetectedMessagesStoreURL()!))
        #expect(restoredFolder == expectedFolder)
    }

    @Test
    func threadDateJumpUsesFirstMessageOnOrAfterSelectedDay() throws {
        let messages = [
            makeMessage(id: "m1", text: "June opener", timestamp: "2024-06-13T09:00:00Z"),
            makeMessage(id: "m2", text: "July opener", timestamp: "2024-07-01T08:00:00Z"),
            makeMessage(id: "m3", text: "July follow-up", timestamp: "2024-07-01T12:00:00Z")
        ]

        let detail = ThreadDetail(
            id: "thread-1",
            title: "Sample",
            participants: [ParticipantRecord(id: "me", displayName: "You")],
            messages: messages,
            statistics: ConversationStatistics(
                totalMessages: 3,
                outgoingMessages: 3,
                incomingMessages: 0,
                attachmentMessages: 0,
                monthlyBuckets: [
                    TimelineBucket(
                        id: "2024-07",
                        label: "Jul 2024",
                        count: 2,
                        startDate: ISO8601DateFormatter().date(from: "2024-07-01T00:00:00Z")!
                    )
                ]
            ),
            rawArchivePath: nil,
            importedAt: Date(),
            importSourceKind: .jsonArchive
        )

        let jumpIndex = detail.dateJumpIndex
        #expect(jumpIndex.dayBuckets.map(\.id) == ["2024-06-13", "2024-07-01"])
        #expect(jumpIndex.monthBuckets.map(\.id) == ["2024-06", "2024-07"])
        #expect(jumpIndex.monthBuckets.map(\.messageCount) == [1, 2])
        #expect(jumpIndex.target(forMonthID: "2024-07")?.messageID == "m2")

        let requestedDate = ISO8601DateFormatter().date(from: "2024-06-20T17:00:00Z")!
        let target = try #require(detail.dateJumpTarget(onOrAfter: requestedDate))
        #expect(target.messageID == "m2")
        #expect(!target.isExactDayMatch())
        #expect(detail.firstMessageID(onOrAfter: requestedDate) == "m2")
        let expectedMonthDay = Calendar.current.startOfDay(for: ISO8601DateFormatter().date(from: "2024-07-01T08:00:00Z")!)
        #expect(detail.firstDay(in: detail.statistics.monthlyBuckets[0]) == expectedMonthDay)
        #expect(detail.firstMessageID(in: detail.statistics.monthlyBuckets[0]) == "m2")
        #expect(detail.day(containingMessageID: "m2") == expectedMonthDay)

        let exactDate = ISO8601DateFormatter().date(from: "2024-07-01T22:00:00Z")!
        #expect(detail.dateJumpTarget(onOrAfter: exactDate)?.isExactDayMatch() == true)

        let afterLastMessage = ISO8601DateFormatter().date(from: "2024-08-01T00:00:00Z")!
        #expect(detail.firstMessageID(onOrAfter: afterLastMessage) == "m3")
    }

    @Test
    func threadSearchFallsBackToSubstringMatchingWhenFTSMisses() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepStoreTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: "thread-search",
                title: "Search Thread",
                participants: [
                    ImportedParticipant(id: "me", displayName: "You")
                ],
                messages: [
                    ImportedMessage(
                        id: "msg-1",
                        senderID: "me",
                        senderDisplayName: "You",
                        isOutgoing: true,
                        bodyText: "Do you want to FaceTime tonight?",
                        timestamp: ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z")!,
                        service: .iMessage,
                        attachmentIDs: [],
                        replyToMessageID: nil,
                        reactions: [],
                        metadataJSON: nil
                    )
                ],
                attachments: [],
                warnings: [],
                sourceFilename: "search.json"
            ),
            sourceKind: .jsonArchive
        )

        try await store.importArchive(payload)

        let results = try await store.searchInThread(threadID: "thread-search", query: "aceTim")
        #expect(results.count == 1)
        #expect(results[0].messageID.contains("msg-1"))

        var filters = LibraryFilters()
        filters.keyword = "aceTim"
        let summaries = try await store.loadThreadSummaries(filters: filters)
        #expect(summaries.count == 1)
        #expect(summaries[0].matchCount == 1)
    }

    @Test
    func librarySearchReturnsResultsAcrossConversations() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepLibrarySearch-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-thanks-one",
            title: "Thanks One",
            messageTimestamps: ["2026-01-10T12:00:00Z"],
            includesAttachment: false
        ))
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-thanks-two",
            title: "Thanks Two",
            messageTimestamps: ["2026-01-11T12:00:00Z"],
            includesAttachment: false
        ))
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-other",
            title: "Other",
            messageTimestamps: ["2026-01-12T12:00:00Z"],
            includesAttachment: false
        ))

        let results = try await store.searchLibrary(query: "thanks")
        #expect(Set(results.map(\.threadID)) == Set(["thread-thanks-one", "thread-thanks-two"]))
        #expect(results.allSatisfy { $0.messageID.contains("message") })
    }

    @Test
    func librarySearchDoesNotReturnExactDuplicateMessageRows() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepLibrarySearchDedup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try makeDedupPayload(
            id: "thread-search-duplicates",
            title: "Search Duplicates",
            participantName: "Chris",
            messages: [
                (id: "m1", body: "juice box on campus", timestamp: "2024-02-02T12:15:56Z", isOutgoing: true, messagesRowID: 400),
                (id: "m2", body: "juice box on campus", timestamp: "2024-02-02T12:15:56Z", isOutgoing: true, messagesRowID: 401),
                (id: "m3", body: "second juice box mention", timestamp: "2024-02-02T12:16:56Z", isOutgoing: true, messagesRowID: 402)
            ]
        )

        try await store.importArchive(payload)

        let results = try await store.searchLibrary(query: "juice box")
        #expect(results.count == 2)

        let detail = try await #require(store.loadThreadDetail(id: payload.archive.id))
        #expect(detail.messages.map(\.bodyText) == [
            "juice box on campus",
            "second juice box mention"
        ])
    }

    @Test
    func threadSearchResultsStayInTranscriptOrder() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepSearchOrder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        let payload = try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: "thread-search-order",
                title: "Search Order",
                participants: [
                    ImportedParticipant(id: "me", displayName: "You")
                ],
                messages: [
                    ImportedMessage(
                        id: "msg-1",
                        senderID: "me",
                        senderDisplayName: "You",
                        isOutgoing: true,
                        bodyText: "needle once",
                        timestamp: ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z")!,
                        service: .iMessage,
                        attachmentIDs: [],
                        replyToMessageID: nil,
                        reactions: [],
                        metadataJSON: nil
                    ),
                    ImportedMessage(
                        id: "msg-2",
                        senderID: "me",
                        senderDisplayName: "You",
                        isOutgoing: true,
                        bodyText: "needle needle needle",
                        timestamp: ISO8601DateFormatter().date(from: "2026-03-01T11:00:00Z")!,
                        service: .iMessage,
                        attachmentIDs: [],
                        replyToMessageID: nil,
                        reactions: [],
                        metadataJSON: nil
                    ),
                    ImportedMessage(
                        id: "msg-3",
                        senderID: "me",
                        senderDisplayName: "You",
                        isOutgoing: true,
                        bodyText: "needle later",
                        timestamp: ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!,
                        service: .iMessage,
                        attachmentIDs: [],
                        replyToMessageID: nil,
                        reactions: [],
                        metadataJSON: nil
                    )
                ],
                attachments: [],
                warnings: [],
                sourceFilename: "search-order.json"
            ),
            sourceKind: .jsonArchive
        )

        try await store.importArchive(payload)

        let results = try await store.searchInThread(threadID: "thread-search-order", query: "needle")
        #expect(results.map(\.messageID) == [
            "thread-search-order::message::msg-1",
            "thread-search-order::message::msg-2",
            "thread-search-order::message::msg-3"
        ])
    }

    @Test
    func libraryFiltersApplyDatesAttachmentsAndClearBackToAllThreads() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepLibraryFilters-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-january",
            title: "January",
            messageTimestamps: ["2026-01-10T12:00:00Z"],
            includesAttachment: false
        ))
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-april-attachment",
            title: "April With Attachment",
            messageTimestamps: ["2026-04-10T12:00:00Z"],
            includesAttachment: true
        ))
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-sparse",
            title: "Sparse Year",
            messageTimestamps: ["2026-01-01T12:00:00Z", "2026-12-31T12:00:00Z"],
            includesAttachment: false
        ))

        let allThreadIDs = try await store.loadThreadSummaries(filters: LibraryFilters()).map(\.id)
        #expect(Set(allThreadIDs) == Set(["thread-january", "thread-april-attachment", "thread-sparse"]))

        var attachmentFilters = LibraryFilters()
        attachmentFilters.hasAttachmentsOnly = true
        let attachmentThreadIDs = try await store.loadThreadSummaries(filters: attachmentFilters).map(\.id)
        #expect(attachmentThreadIDs == ["thread-april-attachment"])

        var aprilFilters = LibraryFilters()
        aprilFilters.startDate = testDate("2026-04-01T00:00:00Z")
        aprilFilters.endDate = testDate("2026-04-30T23:59:59Z")
        let aprilThreadIDs = try await store.loadThreadSummaries(filters: aprilFilters).map(\.id)
        #expect(aprilThreadIDs == ["thread-april-attachment"])

        var juneFilters = LibraryFilters()
        juneFilters.startDate = testDate("2026-06-01T00:00:00Z")
        juneFilters.endDate = testDate("2026-06-30T23:59:59Z")
        let juneThreadIDs = try await store.loadThreadSummaries(filters: juneFilters).map(\.id)
        #expect(juneThreadIDs.isEmpty)

        let restoredThreadIDs = try await store.loadThreadSummaries(filters: LibraryFilters()).map(\.id)
        #expect(Set(restoredThreadIDs) == Set(allThreadIDs))
    }

    @Test
    @MainActor
    func libraryRefreshMovesSelectionWhenFilterHidesSelectedThread() async throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepFilterSelection-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let store = try ArchiveStore(libraryDirectoryURL: tempFolder)
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-january",
            title: "January",
            messageTimestamps: ["2026-01-10T12:00:00Z"],
            includesAttachment: false
        ))
        try await store.importArchive(makeLibraryFilterPayload(
            id: "thread-april-attachment",
            title: "April With Attachment",
            messageTimestamps: ["2026-04-10T12:00:00Z"],
            includesAttachment: true
        ))

        let viewModel = AppViewModel(store: store)
        viewModel.selectThread("thread-january")
        await viewModel.refreshLibrary()
        await viewModel.loadSelectedThread()
        #expect(viewModel.selectedThreadID == "thread-january")

        viewModel.libraryFilters.hasAttachmentsOnly = true
        await viewModel.refreshLibrary()

        #expect(viewModel.threads.map(\.id) == ["thread-april-attachment"])
        #expect(viewModel.selectedThreadID == "thread-april-attachment")
        #expect(viewModel.selectedThread?.id == "thread-april-attachment")
    }

    @Test
    func threadkeepMobileArchiveExportMatchesFrozenSchema() throws {
        let exportedAt = ISO8601DateFormatter().date(from: "2026-03-23T17:00:00Z")!
        let messageTimestamp = ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z")!.addingTimeInterval(0.812)

        let archive = ImportedConversationArchive(
            id: "thread-mobile-export",
            title: "Front Porch",
            participants: [
                ImportedParticipant(id: "me", displayName: "You"),
                ImportedParticipant(id: "sam", displayName: "Sam")
            ],
            messages: [
                ImportedMessage(
                    id: "msg-1",
                    senderID: "me",
                    senderDisplayName: "You",
                    isOutgoing: true,
                    bodyText: "\u{FFFC}Photo from the porch",
                    timestamp: messageTimestamp,
                    service: .iMessage,
                    attachmentIDs: ["att-1"],
                    replyToMessageID: nil,
                    reactions: [],
                    metadataJSON: nil
                )
            ],
            attachments: [
                ImportedAttachment(
                    id: "att-1",
                    type: .image,
                    filename: "porch.jpg",
                    localPath: "/tmp/porch.jpg",
                    mimeType: "image/jpeg",
                    thumbnail: nil,
                    url: nil
                )
            ],
            warnings: [],
            sourceFilename: "front-porch.json"
        )

        let exportedData = try ThreadKeepMobileArchiveExporter(appVersion: "1.0").export(
            archive: archive,
            exportedAt: exportedAt
        )

        let decoded = try decodeMobileArchive(from: exportedData)
        #expect(decoded.manifest.schemaVersion == 1)
        #expect(decoded.manifest.archiveID == "thread-mobile-export")
        #expect(decoded.manifest.archiveTitle == "Front Porch")
        #expect(decoded.manifest.source.kind == "threadkeep-desktop")
        #expect(decoded.manifest.source.appVersion == "1.0")
        #expect(decoded.thread.threadID == "thread-mobile-export")
        #expect(decoded.thread.threadTitle == "Front Porch")
        #expect(decoded.thread.participants.count == 2)
        #expect(decoded.messages.count == 1)
        #expect(decoded.messages[0].messageID == "msg-1")
        #expect(decoded.messages[0].bodyText == "Photo from the porch")
        #expect(decoded.messages[0].timestamp == ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z"))
        #expect(decoded.attachments.isEmpty)

        let object = try #require(JSONSerialization.jsonObject(with: exportedData) as? [String: Any])
        let manifest = try #require(object["manifest"] as? [String: Any])
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(manifest["exported_at"] as? String == "2026-03-23T17:00:00Z")
        #expect((messages.first?["timestamp"] as? String) == "2026-03-01T10:00:00Z")
    }

    @Test
    func messagesStoreArchiveCanExportToThreadKeepMobileV1() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepMobileBridgeTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let dbURL = tempFolder.appendingPathComponent("chat.db")
        let database = try SQLiteDatabase(url: dbURL)
        try database.execute(
            """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, chat_identifier TEXT, display_name TEXT, service_name TEXT);
            CREATE TABLE message (
                ROWID INTEGER PRIMARY KEY,
                guid TEXT,
                text TEXT,
                attributedBody BLOB,
                date INTEGER,
                is_from_me INTEGER,
                service TEXT,
                handle_id INTEGER,
                associated_message_guid TEXT
            );
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, uncanonicalized_id TEXT);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            INSERT INTO chat VALUES (1, 'sam@example.com', NULL, 'iMessage');
            INSERT INTO handle VALUES (1, 'sam@example.com', 'Sam');
            INSERT INTO chat_handle_join VALUES (1, 1);
            INSERT INTO message VALUES (100, 'guid-100', 'Hello from me', NULL, 60, 1, 'iMessage', 1, NULL);
            INSERT INTO message VALUES (101, 'guid-101', 'Reply from Sam', NULL, 120, 0, 'iMessage', 1, NULL);
            INSERT INTO chat_message_join VALUES (1, 100);
            INSERT INTO chat_message_join VALUES (1, 101);
            """
        )

        let payload = try MessagesStoreImporter().importChat(id: 1, from: tempFolder)
        let exportedData = try ThreadKeepMobileArchiveExporter(appVersion: "1.0").export(
            archive: payload.archive,
            exportedAt: ISO8601DateFormatter().date(from: "2026-03-23T17:30:00Z")!
        )

        let decoded = try decodeMobileArchive(from: exportedData)
        #expect(decoded.thread.threadTitle == "Sam")
        #expect(decoded.thread.participants.map(\.displayName).contains("You"))
        #expect(decoded.thread.participants.map(\.displayName).contains("Sam"))
        #expect(decoded.messages.count == 2)
        #expect(decoded.messages[0].isOutgoing)
        #expect(decoded.messages[0].bodyText == "Hello from me")
        #expect(decoded.messages[1].senderDisplayName == "Sam")
        #expect(decoded.messages[1].bodyText == "Reply from Sam")
    }

    @Test
    func threadkeepSyncStagerWritesTemporaryArchiveAndCleansUp() throws {
        let stager = ThreadKeepIPhoneSyncStager()
        let data = Data("bridge-payload".utf8)
        let stagedArchive = try stager.stageArchive(
            data: data,
            suggestedFilename: "Family/History"
        )

        #expect(FileManager.default.fileExists(atPath: stagedArchive.itemURL.path))
        #expect(stagedArchive.itemURL.lastPathComponent == "Family-History.threadkeeparchive")
        #expect(try Data(contentsOf: stagedArchive.itemURL) == data)

        stager.cleanup(stagedArchive)

        #expect(!FileManager.default.fileExists(atPath: stagedArchive.containerURL.path))
    }

    @Test
    func threadkeepSyncStagerCopiesLibraryPackageAndCleansUp() throws {
        let fileManager = FileManager.default
        let sourceContainer = fileManager.temporaryDirectory.appendingPathComponent("ThreadKeepLibraryPackageSource-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: sourceContainer, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: sourceContainer) }

        let packageURL = sourceContainer.appendingPathComponent("Sample.threadkeeplibrary", isDirectory: true)
        let archivesURL = packageURL.appendingPathComponent("archives", isDirectory: true)
        try fileManager.createDirectory(at: archivesURL, withIntermediateDirectories: true)
        try Data("{}".utf8).write(
            to: packageURL.appendingPathComponent("manifest.json"),
            options: [.atomic]
        )
        try Data("archive".utf8).write(
            to: archivesURL.appendingPathComponent("sample.threadkeeparchive"),
            options: [.atomic]
        )

        let stager = ThreadKeepIPhoneSyncStager()
        let stagedPackage = try stager.stagePackage(
            at: packageURL,
            suggestedFilename: "Family/Library"
        )

        #expect(FileManager.default.fileExists(atPath: stagedPackage.itemURL.path))
        #expect(stagedPackage.itemURL.lastPathComponent == "Family-Library.threadkeeplibrary")
        #expect(
            FileManager.default.fileExists(
                atPath: stagedPackage.itemURL
                    .appendingPathComponent("manifest.json", isDirectory: false)
                    .path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: stagedPackage.itemURL
                    .appendingPathComponent("archives/sample.threadkeeparchive", isDirectory: false)
                    .path
            )
        )

        stager.cleanup(stagedPackage)

        #expect(!FileManager.default.fileExists(atPath: stagedPackage.containerURL.path))
    }

    @Test
    func threadkeepLibraryBundleExporterWritesManifestAndArchives() async throws {
        let exporter = ThreadKeepLibraryBundleExporter(appVersion: "1.0")
        let exportedAt = ISO8601DateFormatter().date(from: "2026-03-26T20:00:00Z")!
        let progressRecorder = TestRecorder<ThreadKeepLibraryBundleExportProgress>()

        let result = try await exporter.export(
            threads: [
                makeThreadSummary(id: "thread-1", title: "Sam Rivera"),
                makeThreadSummary(id: "thread-2", title: "Broken Thread")
            ],
            exportedAt: exportedAt,
            progress: { progress in
                await progressRecorder.append(progress)
            },
            archiveDataProvider: { threadID in
                if threadID == "thread-2" {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return Data("{\"ok\":true}".utf8)
            }
        )
        defer { result.cleanup() }

        #expect(FileManager.default.fileExists(atPath: result.bundleURL.path))
        #expect(result.suggestedFilename == "ThreadKeep-Library-2026-03-26.threadkeeplibrary")
        #expect(result.includedArchiveCount == 1)
        #expect(result.skippedCount == 1)

        let manifestURL = result.bundleURL.appendingPathComponent("manifest.json", isDirectory: false)
        let archivesURL = result.bundleURL.appendingPathComponent("archives", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: manifestURL.path))
        #expect(FileManager.default.fileExists(atPath: archivesURL.path))

        let archiveFiles = try FileManager.default.contentsOfDirectory(atPath: archivesURL.path)
        #expect(archiveFiles.count == 1)
        #expect(archiveFiles.first?.hasSuffix(".threadkeeparchive") == true)

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try #require(JSONSerialization.jsonObject(with: manifestData) as? [String: Any])
        let source = try #require(manifest["source"] as? [String: Any])
        let archives = try #require(manifest["archives"] as? [[String: Any]])
        let skippedThreads = try #require(manifest["skipped_threads"] as? [[String: Any]])

        #expect(manifest["schema_version"] as? Int == 1)
        #expect(manifest["requested_thread_count"] as? Int == 2)
        #expect(manifest["included_archive_count"] as? Int == 1)
        #expect(manifest["skipped_archive_count"] as? Int == 1)
        #expect(source["kind"] as? String == "threadkeep-desktop-library")
        #expect(source["app_version"] as? String == "1.0")
        #expect(archives.count == 1)
        #expect(archives.first?["thread_id"] as? String == "thread-1")
        #expect(skippedThreads.count == 1)
        #expect(skippedThreads.first?["thread_id"] as? String == "thread-2")

        let progressUpdates = await progressRecorder.snapshot()
        let sawArchiveProgress = progressUpdates.contains { progress in
            progress.phase == .exportingArchives && progress.currentThreadTitle == "Sam Rivera"
        }
        #expect(progressUpdates.first?.phase == .preparing)
        #expect(sawArchiveProgress)
        #expect(progressUpdates.last?.phase == .packaging)
    }

    @Test
    func reviewPDFExportProducesSearchableDocument() throws {
        let thread = ThreadDetail(
            id: "thread-pdf",
            title: "PDF Sample",
            participants: [
                ParticipantRecord(id: "me", displayName: "You"),
                ParticipantRecord(id: "sam", displayName: "Sam")
            ],
            messages: [
                makeMessage(id: "m1", text: "Can you send the kiln notes?", timestamp: "2024-03-01T09:00:00Z"),
                MessageRecord(
                    id: "m2",
                    threadID: "thread-pdf",
                    senderID: "sam",
                    senderDisplayName: "Sam",
                    isOutgoing: false,
                    bodyText: "Uploading them now.",
                    timestamp: ISO8601DateFormatter().date(from: "2024-03-01T09:02:00Z")!,
                    service: .iMessage,
                    attachments: [],
                    replyToMessageID: nil,
                    reactions: [],
                    metadataJSON: nil
                )
            ],
            statistics: ConversationStatistics(
                totalMessages: 2,
                outgoingMessages: 1,
                incomingMessages: 1,
                attachmentMessages: 0,
                monthlyBuckets: [
                    TimelineBucket(
                        id: "2024-03",
                        label: "Mar 2024",
                        count: 2,
                        startDate: ISO8601DateFormatter().date(from: "2024-03-01T00:00:00Z")!
                    )
                ]
            ),
            rawArchivePath: nil,
            importedAt: Date(),
            importSourceKind: .jsonArchive
        )

        let data = try ThreadPDFExporter().export(thread: thread, mode: .review)
        let document = try #require(PDFDocument(data: data))
        #expect(document.pageCount >= 1)
        let pdfText = document.string ?? ""
        let normalizedPDFText = pdfText.replacingOccurrences(of: "\u{202F}", with: " ")
        #expect(normalizedPDFText.contains("Can you send the kiln notes?"))
        #expect(normalizedPDFText.contains("Uploading them now."))
        #expect(normalizedPDFText.contains(normalizedTimestampString(for: thread.messages[0].timestamp)))
        #expect(normalizedPDFText.contains(normalizedTimestampString(for: thread.messages[1].timestamp)))
    }

    @Test
    func jsonExportProducesParseableConversationFile() throws {
        let tempFolder = FileManager.default.temporaryDirectory.appendingPathComponent("ThreadKeepJSONExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempFolder) }

        let thread = ThreadDetail(
            id: "thread-json",
            title: "JSON Sample",
            participants: [
                ParticipantRecord(id: "you", displayName: "You"),
                ParticipantRecord(id: "sam", displayName: "Sam")
            ],
            messages: [
                makeMessage(id: "m1", text: "Please keep this", timestamp: "2024-03-01T09:00:00Z")
            ],
            statistics: ConversationStatistics(
                totalMessages: 1,
                outgoingMessages: 1,
                incomingMessages: 0,
                attachmentMessages: 0,
                monthlyBuckets: []
            ),
            rawArchivePath: nil,
            importedAt: Date(),
            importSourceKind: .jsonArchive
        )

        let result = try ThreadJSONExporter(appVersion: "1.0").export(
            thread: thread,
            to: tempFolder,
            includeAttachments: true,
            nameResolution: ThreadJSONNameResolution(
                threadTitle: "JSON Sample",
                participantNamesByID: ["you": "Me", "sam": "Sam"],
                senderNamesByID: ["you": "Me"]
            ),
            exportedAt: testDate("2026-05-05T17:30:00Z")
        )

        let stampFormatter = DateFormatter()
        stampFormatter.locale = Locale(identifier: "en_US_POSIX")
        stampFormatter.calendar = Calendar(identifier: .gregorian)
        stampFormatter.dateFormat = "yyyy-MM-dd"
        let expectedStamp = stampFormatter.string(from: testDate("2026-05-05T17:30:00Z"))
        #expect(result.jsonURL.lastPathComponent.hasSuffix("-\(expectedStamp).json"))
        #expect(result.folderURL.lastPathComponent.hasSuffix("-json"))

        let data = try Data(contentsOf: result.jsonURL)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["threadkeep_version"] as? String == "1.0")
        #expect(object["schema_version"] as? Int == 2)
        let messages = try #require(object["messages"] as? [[String: Any]])
        #expect(messages.count == 1)
        #expect(messages[0]["body"] as? String == "Please keep this")

        let threadObject = try #require(object["thread"] as? [String: Any])
        let participants = try #require(threadObject["participants"] as? [[String: Any]])
        #expect(participants.allSatisfy { $0["cn_contact_identifier"] == nil })
    }

    @Test
    func groupedMessagesTieBreaksSameSecondByID() throws {
        let thread = ThreadDetail(
            id: "thread-order",
            title: "Ordering Sample",
            participants: [
                ParticipantRecord(id: "you", displayName: "You"),
                ParticipantRecord(id: "sam", displayName: "Sam")
            ],
            messages: [
                makeMessage(id: "m2", text: "second by id", timestamp: "2024-03-01T09:00:00Z"),
                makeMessage(id: "m1", text: "first by id", timestamp: "2024-03-01T09:00:00Z"),
                makeMessage(id: "m3", text: "a second later", timestamp: "2024-03-01T09:00:01Z")
            ],
            statistics: ConversationStatistics(
                totalMessages: 3,
                outgoingMessages: 3,
                incomingMessages: 0,
                attachmentMessages: 0,
                monthlyBuckets: []
            ),
            rawArchivePath: nil,
            importedAt: Date(),
            importSourceKind: .jsonArchive
        )

        let groups = thread.groupedMessages
        #expect(groups.count == 1)
        let orderedIDs = try #require(groups.first).messages.map(\.id)
        #expect(orderedIDs == ["m1", "m2", "m3"])
    }

    @Test
    func csvExportPreservesCountOrderAndSenders() throws {
        let thread = makeExportSampleThread()
        let csv = ThreadCSVExporter().export(thread: thread, nameResolution: exportSampleResolution())

        let rows = parseCSV(csv)
        let header = try #require(rows.first)
        #expect(header == ["timestamp", "sender", "direction", "type", "text", "attachments"])

        let dataRows = Array(rows.dropFirst())
        #expect(dataRows.count == 3)
        #expect(dataRows.map { $0[1] } == ["Sam", "Me", "Sam"])
        #expect(dataRows.map { $0[2] } == ["them", "you", "them"])

        let timestamps = dataRows.map { $0[0] }
        #expect(timestamps == timestamps.sorted())
        #expect(timestamps == [
            "2024-03-01T09:00:00Z",
            "2024-03-01T09:00:30Z",
            "2024-03-01T09:01:00Z"
        ])

        // Quoting/escaping round-trips for comma + embedded newline + filename column.
        #expect(dataRows[0][4] == "Hey, did you, see this?")
        #expect(dataRows[2][4] == "line1\nline2")
        #expect(dataRows[1][5] == "photo.jpg")
    }

    @Test
    func textExportPreservesCountOrderAndSenders() throws {
        let thread = makeExportSampleThread()
        let txt = ThreadTextExporter().export(thread: thread, nameResolution: exportSampleResolution())

        let messageLines = txt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { $0.range(of: #"^\d{2}:\d{2}  "#, options: .regularExpression) != nil }

        #expect(messageLines.count == 3)

        let senders = messageLines.map { line -> String in
            let afterTime = String(line.dropFirst(7)) // "HH:mm" + two spaces
            return String(afterTime.prefix(while: { $0 != ":" }))
        }
        #expect(senders == ["Sam", "Me", "Sam"])
        #expect(txt.contains("[attachment: photo.jpg]"))
    }

    @Test
    func htmlExportPreservesCountOrderAndSenders() throws {
        let thread = makeExportSampleThread()
        let html = ThreadHTMLExporter().export(thread: thread, nameResolution: exportSampleResolution())

        #expect(html.hasPrefix("<!DOCTYPE html>"))

        let senders = matches(in: html, pattern: #"<span class="sender">([^<]+)</span>"#)
        #expect(senders.count == 3)
        #expect(senders == ["Sam", "Me", "Sam"])
        #expect(html.contains("<li>photo.jpg</li>"))
    }

    private func makeExportSampleThread() -> ThreadDetail {
        ThreadDetail(
            id: "thread-export",
            title: "Sam",
            participants: [
                ParticipantRecord(id: "you", displayName: "You"),
                ParticipantRecord(id: "sam", displayName: "Sam")
            ],
            messages: [
                makeExportMessage(id: "m1", text: "Hey, did you, see this?", timestamp: "2024-03-01T09:00:00Z", senderID: "sam", senderDisplayName: "Sam", isOutgoing: false),
                makeExportMessage(id: "m2", text: "Yes—\"wild\"", timestamp: "2024-03-01T09:00:30Z", senderID: "you", senderDisplayName: "You", isOutgoing: true, attachmentFilenames: ["photo.jpg"]),
                makeExportMessage(id: "m3", text: "line1\nline2", timestamp: "2024-03-01T09:01:00Z", senderID: "sam", senderDisplayName: "Sam", isOutgoing: false)
            ],
            statistics: ConversationStatistics(
                totalMessages: 3,
                outgoingMessages: 1,
                incomingMessages: 2,
                attachmentMessages: 1,
                monthlyBuckets: []
            ),
            rawArchivePath: nil,
            importedAt: Date(),
            importSourceKind: .jsonArchive
        )
    }

    private func exportSampleResolution() -> ThreadJSONNameResolution {
        ThreadJSONNameResolution(
            threadTitle: "Sam",
            participantNamesByID: ["you": "Me", "sam": "Sam"],
            senderNamesByID: ["you": "Me", "sam": "Sam"]
        )
    }

    private func makeExportMessage(
        id: String,
        text: String,
        timestamp: String,
        senderID: String,
        senderDisplayName: String,
        isOutgoing: Bool,
        attachmentFilenames: [String] = []
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            threadID: "thread-export",
            senderID: senderID,
            senderDisplayName: senderDisplayName,
            isOutgoing: isOutgoing,
            bodyText: text,
            timestamp: ISO8601DateFormatter().date(from: timestamp)!,
            service: .iMessage,
            attachments: attachmentFilenames.map { filename in
                AttachmentRecord(id: "att-\(filename)", type: .image, filename: filename, localPath: nil, mimeType: nil, thumbnail: nil, url: nil)
            },
            replyToMessageID: nil,
            reactions: [],
            metadataJSON: nil
        )
    }

    private func matches(in text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[range])
        }
    }

    /// Minimal RFC 4180 parser used to validate CSV quoting/escaping in tests.
    private func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var field = ""
        var record: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        field.append("\"")
                        i += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    record.append(field)
                    field = ""
                case "\n":
                    record.append(field)
                    field = ""
                    rows.append(record)
                    record = []
                case "\r":
                    break
                default:
                    field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            rows.append(record)
        }
        return rows
    }

    private func normalizedTimestampString(for date: Date) -> String {
        AppFormatters.preciseMessageTimestamp
            .string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }

    private func makeMessage(id: String, text: String, timestamp: String) -> MessageRecord {
        MessageRecord(
            id: id,
            threadID: "thread-1",
            senderID: "me",
            senderDisplayName: "You",
            isOutgoing: true,
            bodyText: text,
            timestamp: ISO8601DateFormatter().date(from: timestamp)!,
            service: .iMessage,
            attachments: [],
            replyToMessageID: nil,
            reactions: [],
            metadataJSON: nil
        )
    }

    private func makeLibraryFilterPayload(
        id: String,
        title: String,
        messageTimestamps: [String],
        includesAttachment: Bool
    ) throws -> ParsedArchivePayload {
        let attachmentID = "\(id)-attachment"
        let attachments = includesAttachment
            ? [
                ImportedAttachment(
                    id: attachmentID,
                    type: .image,
                    filename: "\(id).jpg",
                    localPath: nil,
                    mimeType: "image/jpeg",
                    thumbnail: nil,
                    url: nil
                )
            ]
            : []

        let messages = messageTimestamps.enumerated().map { index, timestamp in
            ImportedMessage(
                id: "\(id)-message-\(index)",
                senderID: "sam",
                senderDisplayName: "Sam",
                isOutgoing: false,
                bodyText: "\(title) message \(index)",
                timestamp: testDate(timestamp),
                service: .iMessage,
                attachmentIDs: includesAttachment && index == 0 ? [attachmentID] : [],
                replyToMessageID: nil,
                reactions: [],
                metadataJSON: nil
            )
        }

        return try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: id,
                title: title,
                participants: [
                    ImportedParticipant(id: "you", displayName: "You"),
                    ImportedParticipant(id: "sam", displayName: "Sam")
                ],
                messages: messages,
                attachments: attachments,
                warnings: [],
                sourceFilename: "\(id).json"
            ),
            sourceKind: .jsonArchive
        )
    }

    private func makeDedupPayload(
        id: String,
        title: String,
        participantName: String,
        messages messageSpecs: [(id: String, body: String, timestamp: String, isOutgoing: Bool, messagesRowID: Int?)]
    ) throws -> ParsedArchivePayload {
        let messages = messageSpecs.map { spec in
            ImportedMessage(
                id: spec.id,
                senderID: spec.isOutgoing ? "you" : "other",
                senderDisplayName: spec.isOutgoing ? "You" : participantName,
                isOutgoing: spec.isOutgoing,
                bodyText: spec.body,
                timestamp: testDate(spec.timestamp),
                service: .iMessage,
                attachmentIDs: [],
                replyToMessageID: nil,
                reactions: [],
                metadataJSON: spec.messagesRowID.map { "{\"import_source\":\"messages_mac_beta\",\"messages_rowid\":\($0)}" }
            )
        }

        return try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: id,
                title: title,
                participants: [
                    ImportedParticipant(id: "you", displayName: "You"),
                    ImportedParticipant(id: "other", displayName: participantName)
                ],
                messages: messages,
                attachments: [],
                warnings: [],
                sourceFilename: "\(id).json"
            ),
            sourceKind: .messagesMacBeta
        )
    }

    private func makeDedupPayload(
        id: String,
        title: String,
        participantName: String,
        messages messageSpecs: [(id: String, body: String, timestamp: Date, isOutgoing: Bool, messagesRowID: Int?)]
    ) throws -> ParsedArchivePayload {
        let messages = messageSpecs.map { spec in
            ImportedMessage(
                id: spec.id,
                senderID: spec.isOutgoing ? "you" : "other",
                senderDisplayName: spec.isOutgoing ? "You" : participantName,
                isOutgoing: spec.isOutgoing,
                bodyText: spec.body,
                timestamp: spec.timestamp,
                service: .iMessage,
                attachmentIDs: [],
                replyToMessageID: nil,
                reactions: [],
                metadataJSON: spec.messagesRowID.map { "{\"import_source\":\"messages_mac_beta\",\"messages_rowid\":\($0)}" }
            )
        }

        return try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: id,
                title: title,
                participants: [
                    ImportedParticipant(id: "you", displayName: "You"),
                    ImportedParticipant(id: "other", displayName: participantName)
                ],
                messages: messages,
                attachments: [],
                warnings: [],
                sourceFilename: "\(id).json"
            ),
            sourceKind: .messagesMacBeta
        )
    }

    private func makeMetadataDedupPayload(
        id: String,
        title: String,
        participantName: String,
        messages messageSpecs: [(id: String, body: String, timestamp: String, isOutgoing: Bool, metadataJSON: String?)]
    ) throws -> ParsedArchivePayload {
        let messages = messageSpecs.map { spec in
            ImportedMessage(
                id: spec.id,
                senderID: spec.isOutgoing ? "you" : "other",
                senderDisplayName: spec.isOutgoing ? "You" : participantName,
                isOutgoing: spec.isOutgoing,
                bodyText: spec.body,
                timestamp: testDate(spec.timestamp),
                service: .iMessage,
                attachmentIDs: [],
                replyToMessageID: nil,
                reactions: [],
                metadataJSON: spec.metadataJSON
            )
        }

        return try ParsedArchivePayload.snapshot(
            archive: ImportedConversationArchive(
                id: id,
                title: title,
                participants: [
                    ImportedParticipant(id: "you", displayName: "You"),
                    ImportedParticipant(id: "other", displayName: participantName)
                ],
                messages: messages,
                attachments: [],
                warnings: [],
                sourceFilename: "\(id).json"
            ),
            sourceKind: .messagesMacBeta
        )
    }

    private func testDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func makeThreadSummary(id: String, title: String) -> ThreadSummary {
        ThreadSummary(
            id: id,
            title: title,
            startDate: ISO8601DateFormatter().date(from: "2026-03-01T10:00:00Z"),
            endDate: ISO8601DateFormatter().date(from: "2026-03-02T10:00:00Z"),
            participantNames: ["Sam"],
            participantCount: 1,
            messageCount: 2,
            attachmentCount: 0,
            hasAttachments: false,
            importedAt: ISO8601DateFormatter().date(from: "2026-03-23T10:00:00Z")!,
            rawArchivePath: nil,
            importSourceKind: .messagesMacBeta,
            matchCount: nil,
            latestMessageText: "Latest",
            latestMessageTimestamp: ISO8601DateFormatter().date(from: "2026-03-02T10:00:00Z"),
            latestSenderDisplayName: "Sam",
            latestMessageIsOutgoing: false
        )
    }

    private func decodeMobileArchive(from data: Data) throws -> MobileArchiveContract {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MobileArchiveContract.self, from: data)
    }

    private var validArchiveJSON: String {
        """
        {
          "thread_id": "thread-1",
          "thread_title": "Sample Thread",
          "participants": [
            { "id": "me", "display_name": "Me" },
            { "id": "sam", "display_name": "Sam" }
          ],
          "messages": [
            {
              "id": "msg-1",
              "sender_id": "me",
              "sender_display_name": "Me",
              "is_outgoing": true,
              "body_text": "hello world",
              "timestamp": "2026-03-01T10:00:00-05:00",
              "service": "iMessage",
              "attachment_ids": []
            },
            {
              "id": "msg-2",
              "sender_id": "sam",
              "sender_display_name": "Sam",
              "is_outgoing": false,
              "body_text": "attached",
              "timestamp": "2026-03-01T10:01:00-05:00",
              "service": "SMS",
              "attachment_ids": ["att-1"]
            }
          ],
          "attachments": [
            {
              "id": "att-1",
              "type": "file",
              "filename": "notes.txt"
            }
          ]
        }
        """
    }
}

private actor TestRecorder<Value: Sendable> {
    private var values: [Value] = []

    func append(_ value: Value) {
        values.append(value)
    }

    func snapshot() -> [Value] {
        values
    }
}

private struct MobileArchiveContract: Decodable {
    let manifest: Manifest
    let thread: Thread
    let messages: [Message]
    let attachments: [Attachment]

    struct Manifest: Decodable {
        let schemaVersion: Int
        let archiveID: String
        let archiveTitle: String
        let exportedAt: Date
        let source: Source

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case archiveID = "archive_id"
            case archiveTitle = "archive_title"
            case exportedAt = "exported_at"
            case source
        }
    }

    struct Source: Decodable {
        let kind: String
        let appVersion: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case appVersion = "app_version"
        }
    }

    struct Thread: Decodable {
        let threadID: String
        let threadTitle: String
        let participants: [Participant]

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case threadTitle = "thread_title"
            case participants
        }
    }

    struct Participant: Decodable {
        let participantID: String
        let displayName: String

        enum CodingKeys: String, CodingKey {
            case participantID = "participant_id"
            case displayName = "display_name"
        }
    }

    struct Message: Decodable {
        let messageID: String
        let senderID: String
        let senderDisplayName: String
        let isOutgoing: Bool
        let bodyText: String
        let timestamp: Date

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case senderID = "sender_id"
            case senderDisplayName = "sender_display_name"
            case isOutgoing = "is_outgoing"
            case bodyText = "body_text"
            case timestamp
        }
    }

    struct Attachment: Decodable {}
}

private func legacyTypedstreamData(from object: AnyObject) -> Data? {
    guard let nsArchiverClass = NSClassFromString("NSArchiver") as? NSObject.Type else {
        return nil
    }

    let classObject = nsArchiverClass as AnyObject
    let selector = NSSelectorFromString("archivedDataWithRootObject:")
    return classObject.perform(selector, with: object)?.takeUnretainedValue() as? Data
}
