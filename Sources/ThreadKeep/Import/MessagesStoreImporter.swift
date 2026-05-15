@preconcurrency import Contacts
import Foundation
import SQLite3

enum MessagesStoreImportError: LocalizedError {
    case folderNotFound
    case databaseNotFound
    case databaseUnreadable
    case unsupportedSchema(String)
    case threadNotFound

    var errorDescription: String? {
        switch self {
        case .folderNotFound:
            return "ThreadKeep couldn’t open that Messages folder on this Mac."
        case .databaseNotFound:
            return "ThreadKeep couldn’t find a local Messages archive in the folder you chose."
        case .databaseUnreadable:
            return "ThreadKeep found Messages in that folder, but couldn’t read it yet. Open Messages once, then try again."
        case .unsupportedSchema(let message):
            return message
        case .threadNotFound:
            return "That conversation wasn’t available from Messages on this Mac."
        }
    }
}

enum MessagesContactAccessState: Sendable {
    case authorized
    case notDetermined
    case denied
    case disabledByChoice
    case unavailable
}

struct MessagesBulkImportProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case preparing
        case importing
        case finishing
    }

    let phase: Phase
    let completedCount: Int
    let totalCount: Int
    let currentChatTitle: String?
}

struct MessagesBulkImportFailure: Sendable, Equatable {
    let chatID: Int
    let chatTitle: String?
    let errorDescription: String
}

struct MessagesBulkImportResult: Sendable, Equatable {
    let importedThreadIDs: [String]
    let failures: [MessagesBulkImportFailure]
    let totalRequestedCount: Int

    var importedCount: Int {
        importedThreadIDs.count
    }

    var skippedCount: Int {
        failures.count
    }
}

private final class PreparedMessagesImportState {
    let database: SQLiteDatabase
    let schema: MessagesStoreSchema
    let messagesFolderURL: URL
    let contactResolver: MessagesContactResolver

    private let selectedURL: URL
    private let accessedSecurityScopedResource: Bool
    private let tempDirectoryURL: URL
    private let fileManager: FileManager

    var resolvedHandles: [String: ResolvedMessagesHandle] = [:]
    var cachedChatCandidates: [MessagesChatCandidate]?
    private var hasCleanedUp = false

    init(
        database: SQLiteDatabase,
        schema: MessagesStoreSchema,
        messagesFolderURL: URL,
        contactResolver: MessagesContactResolver,
        selectedURL: URL,
        accessedSecurityScopedResource: Bool,
        tempDirectoryURL: URL,
        fileManager: FileManager
    ) {
        self.database = database
        self.schema = schema
        self.messagesFolderURL = messagesFolderURL
        self.contactResolver = contactResolver
        self.selectedURL = selectedURL
        self.accessedSecurityScopedResource = accessedSecurityScopedResource
        self.tempDirectoryURL = tempDirectoryURL
        self.fileManager = fileManager
    }

    deinit {
        cleanup()
    }

    func cleanup() {
        guard !hasCleanedUp else { return }
        hasCleanedUp = true
        try? fileManager.removeItem(at: tempDirectoryURL)
        if accessedSecurityScopedResource {
            selectedURL.stopAccessingSecurityScopedResource()
        }
    }
}

struct MessagesStoreImporter: Sendable {
    static func currentContactAccessState(enabled: Bool = true) -> MessagesContactAccessState {
        guard enabled else {
            return .disabledByChoice
        }

        guard Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription") != nil else {
            return .unavailable
        }

        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .unavailable
        }
    }

    static func requestContactAccessIfNeeded(enabled: Bool = true) async -> MessagesContactAccessState {
        switch currentContactAccessState(enabled: enabled) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                CNContactStore().requestAccess(for: .contacts) { granted, _ in
                    continuation.resume(returning: granted ? .authorized : .denied)
                }
            }
        case .denied:
            return .denied
        case .disabledByChoice:
            return .disabledByChoice
        case .unavailable:
            return .unavailable
        }
    }

    func loadChatCandidates(from selectedURL: URL, useContacts: Bool = true) throws -> [MessagesChatCandidate] {
        let preparedState = try prepareImportState(from: selectedURL, useContacts: useContacts)
        defer { preparedState.cleanup() }
        return try loadChatCandidates(using: preparedState)
    }

    func importChat(id chatID: Int, from selectedURL: URL, useContacts: Bool = true) throws -> ParsedArchivePayload {
        let preparedState = try prepareImportState(from: selectedURL, useContacts: useContacts)
        defer { preparedState.cleanup() }
        return try importChat(id: chatID, using: preparedState)
    }

    func importChats(
        ids chatIDs: [Int],
        from selectedURL: URL,
        useContacts: Bool = true,
        progress: (@Sendable (MessagesBulkImportProgress) async -> Void)? = nil,
        onPayload: @Sendable (ParsedArchivePayload) async throws -> Void
    ) async throws -> MessagesBulkImportResult {
        var timer = ImportPerformanceTimer(label: "Messages bulk import", logger: ThreadKeepLog.importer)
        await progress?(
            MessagesBulkImportProgress(
                phase: .preparing,
                completedCount: 0,
                totalCount: chatIDs.count,
                currentChatTitle: nil
            )
        )

        let preparedState = try prepareImportState(from: selectedURL, useContacts: useContacts)
        defer { preparedState.cleanup() }
        timer.mark("source database copy + schema")

        let chats = try loadChatCandidates(using: preparedState)
        timer.mark("source conversation loading", items: chats.count)
        let chatsByID = Dictionary(uniqueKeysWithValues: chats.map { ($0.id, $0) })
        var importedThreadIDs: [String] = []
        var failures: [MessagesBulkImportFailure] = []

        for (index, chatID) in chatIDs.enumerated() {
            let candidate = chatsByID[chatID]
            await progress?(
                MessagesBulkImportProgress(
                    phase: .importing,
                    completedCount: index,
                    totalCount: chatIDs.count,
                    currentChatTitle: candidate?.title
                )
            )

            do {
                let payload = try importChat(id: chatID, using: preparedState, candidate: candidate)
                try await onPayload(payload)
                importedThreadIDs.append(payload.archive.id)
                timer.mark("archive parsed + stored", items: payload.archive.messages.count)
            } catch {
                failures.append(
                    MessagesBulkImportFailure(
                        chatID: chatID,
                        chatTitle: candidate?.title,
                        errorDescription: error.localizedDescription
                    )
                )
            }
        }

        await progress?(
            MessagesBulkImportProgress(
                phase: .finishing,
                completedCount: importedThreadIDs.count,
                totalCount: chatIDs.count,
                currentChatTitle: nil
            )
        )
        timer.mark("progress finalization", items: importedThreadIDs.count)

        return MessagesBulkImportResult(
            importedThreadIDs: importedThreadIDs,
            failures: failures,
            totalRequestedCount: chatIDs.count
        )
    }

    private func normalizedFolderURL(for selectedURL: URL) throws -> URL {
        if selectedURL.hasDirectoryPath {
            return selectedURL
        }
        if selectedURL.lastPathComponent == "chat.db" {
            return selectedURL.deletingLastPathComponent()
        }
        throw MessagesStoreImportError.folderNotFound
    }

    private func prepareImportState(from selectedURL: URL, useContacts: Bool) throws -> PreparedMessagesImportState {
        let accessed = selectedURL.startAccessingSecurityScopedResource()
        do {
            let folderURL = try normalizedFolderURL(for: selectedURL)

            let dbURL = folderURL.appendingPathComponent("chat.db")
            let fileManager = FileManager.default

            guard fileManager.fileExists(atPath: dbURL.path) else {
                throw MessagesStoreImportError.databaseNotFound
            }

            let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("ThreadKeepMessagesImport-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

            do {
                let tempDBURL = tempDirectory.appendingPathComponent("chat.db")
                try fileManager.copyItem(at: dbURL, to: tempDBURL)

                for suffix in ["-wal", "-shm"] {
                    let source = folderURL.appendingPathComponent("chat.db\(suffix)")
                    let destination = tempDirectory.appendingPathComponent("chat.db\(suffix)")
                    if fileManager.fileExists(atPath: source.path) {
                        try? fileManager.copyItem(at: source, to: destination)
                    }
                }

                let database = try SQLiteDatabase(
                    url: tempDBURL,
                    flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
                )
                try database.execute("PRAGMA query_only = ON;")

                let schema: MessagesStoreSchema
                do {
                    schema = try MessagesStoreSchema.load(from: database)
                } catch let error as SQLiteDatabaseError {
                    if case .prepareFailed = error {
                        throw MessagesStoreImportError.databaseUnreadable
                    }
                    throw error
                }

                return PreparedMessagesImportState(
                    database: database,
                    schema: schema,
                    messagesFolderURL: folderURL,
                    contactResolver: MessagesContactResolver(enabled: useContacts),
                    selectedURL: selectedURL,
                    accessedSecurityScopedResource: accessed,
                    tempDirectoryURL: tempDirectory,
                    fileManager: fileManager
                )
            } catch {
                try? fileManager.removeItem(at: tempDirectory)
                throw error
            }
        } catch {
            if accessed {
                selectedURL.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    private func loadChatCandidates(using preparedState: PreparedMessagesImportState) throws -> [MessagesChatCandidate] {
        if let cachedChatCandidates = preparedState.cachedChatCandidates {
            return cachedChatCandidates
        }

        let chats = try loadChatCandidates(
            database: preparedState.database,
            schema: preparedState.schema,
            contactResolver: preparedState.contactResolver,
            resolvedHandles: &preparedState.resolvedHandles
        )
        preparedState.cachedChatCandidates = chats
        return chats
    }

    private func loadChatCandidates(
        database: SQLiteDatabase,
        schema: MessagesStoreSchema,
        contactResolver: MessagesContactResolver,
        resolvedHandles: inout [String: ResolvedMessagesHandle]
    ) throws -> [MessagesChatCandidate] {
        guard schema.hasTable("chat"),
              schema.hasTable("message"),
              schema.hasTable("chat_message_join")
        else {
            throw MessagesStoreImportError.unsupportedSchema("This Messages database is missing the tables ThreadKeep expects for chat import.")
        }

        let handleJoin = schema.hasTable("chat_handle_join") && schema.hasTable("handle")
        let handleDisplayExpression = schema.handleDisplayExpression
        let displayNameExpression = schema.hasColumn("chat", "display_name") ? "chat.display_name" : "NULL"
        let serviceExpression = schema.hasColumn("chat", "service_name") ? "chat.service_name" : "NULL"
        let identifierExpression = schema.hasColumn("chat", "chat_identifier") ? "chat.chat_identifier" : "NULL"
        let dateExpression = schema.hasColumn("message", "date") ? "message.date" : "0"

        let sql = """
        SELECT
            chat.ROWID,
            \(displayNameExpression),
            \(identifierExpression),
            \(serviceExpression),
            MIN(\(dateExpression)),
            MAX(\(dateExpression)),
            COUNT(message.ROWID),
            \(handleJoin ? "GROUP_CONCAT(DISTINCT \(handleDisplayExpression))" : "NULL")
        FROM chat
        JOIN chat_message_join cmj ON cmj.chat_id = chat.ROWID
        JOIN message ON message.ROWID = cmj.message_id
        \(handleJoin ? "LEFT JOIN chat_handle_join chj ON chj.chat_id = chat.ROWID LEFT JOIN handle ON handle.ROWID = chj.handle_id" : "")
        GROUP BY chat.ROWID
        ORDER BY MAX(\(dateExpression)) DESC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        var chats: [MessagesChatCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = database.columnInt(statement, index: 0)
            let displayName = database.columnText(statement, index: 1)?.trimmed.nilIfBlank
            let identifier = database.columnText(statement, index: 2)?.trimmed.nilIfBlank
            let serviceName = database.columnText(statement, index: 3)?.trimmed.nilIfBlank
            let rawParticipantIdentifiers = (database.columnText(statement, index: 7) ?? "")
                .split(separator: ",")
                .map(String.init)
                .map(\.trimmed)
                .filter { !$0.isEmpty }
            let resolvedParticipants = rawParticipantIdentifiers.map {
                resolvedHandle(for: $0, contactResolver: contactResolver, cache: &resolvedHandles)
            }
            let participantNames = resolvedParticipants
                .map(\.label)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            let resolvedIdentifier = identifier.map {
                resolvedHandle(for: $0, contactResolver: contactResolver, cache: &resolvedHandles)
            }
            let titleFallbackNames = conversationTitleFallbackNames(
                resolvedParticipants: resolvedParticipants,
                resolvedIdentifier: resolvedIdentifier
            )
            let displayedParticipantNames = participantNames.isEmpty
                ? resolvedIdentifier.map { [$0.label] } ?? []
                : participantNames

            chats.append(
                MessagesChatCandidate(
                    id: rowID,
                    title: inferredChatTitle(
                        displayName: displayName,
                        identifier: resolvedIdentifier?.title ?? identifier,
                        participantNames: titleFallbackNames,
                        rowID: rowID
                    ),
                    participantNames: displayedParticipantNames,
                    serviceName: serviceName,
                    startDate: decodeMessagesDate(database.columnInt64(statement, index: 4)),
                    endDate: decodeMessagesDate(database.columnInt64(statement, index: 5)),
                    messageCount: database.columnInt(statement, index: 6)
                )
            )
        }

        return chats
    }

    private func importChat(
        id chatID: Int,
        using preparedState: PreparedMessagesImportState,
        candidate: MessagesChatCandidate? = nil
    ) throws -> ParsedArchivePayload {
        let resolvedCandidate: MessagesChatCandidate
        if let candidate {
            resolvedCandidate = candidate
        } else {
            guard let candidate = try loadChatCandidates(using: preparedState)
                .first(where: { $0.id == chatID })
            else {
                throw MessagesStoreImportError.threadNotFound
            }
            resolvedCandidate = candidate
        }

        let archive = try loadArchive(
            chatID: chatID,
            candidate: resolvedCandidate,
            database: preparedState.database,
            schema: preparedState.schema,
            messagesFolderURL: preparedState.messagesFolderURL,
            contactResolver: preparedState.contactResolver,
            resolvedHandles: &preparedState.resolvedHandles
        )
        return try ParsedArchivePayload.snapshot(archive: archive, sourceKind: .messagesMacBeta)
    }

    private func loadArchive(
        chatID: Int,
        candidate: MessagesChatCandidate,
        database: SQLiteDatabase,
        schema: MessagesStoreSchema,
        messagesFolderURL: URL,
        contactResolver: MessagesContactResolver,
        resolvedHandles: inout [String: ResolvedMessagesHandle]
    ) throws -> ImportedConversationArchive {
        var timer = ImportPerformanceTimer(label: "Messages chat \(chatID)", logger: ThreadKeepLog.importer)
        let participantLookup = try loadChatParticipants(
            chatID: chatID,
            database: database,
            schema: schema,
            contactResolver: contactResolver,
            resolvedHandles: &resolvedHandles
        )
        timer.mark("participant loading", items: participantLookup.count)
        let attachmentLookup = try loadAttachments(chatID: chatID, database: database, schema: schema, messagesFolderURL: messagesFolderURL)
        timer.mark("attachment loading", items: attachmentLookup.count)

        let textExpression = schema.hasColumn("message", "text") ? "message.text" : "NULL"
        let attributedBodyExpression = schema.hasColumn("message", "attributedBody") ? "message.attributedBody" : "NULL"
        let serviceExpression = schema.hasColumn("message", "service") ? "message.service" : "NULL"
        let guidExpression = schema.hasColumn("message", "guid") ? "message.guid" : "CAST(message.ROWID AS TEXT)"
        let handleExpression = schema.hasTable("handle") ? "\(schema.handleDisplayExpression)" : "NULL"
        let associatedGuidExpression = schema.hasColumn("message", "associated_message_guid") ? "message.associated_message_guid" : "NULL"

        let sql = """
        SELECT
            message.ROWID,
            \(guidExpression),
            \(textExpression),
            \(attributedBodyExpression),
            message.date,
            message.is_from_me,
            \(serviceExpression),
            \(schema.hasColumn("message", "handle_id") && schema.hasTable("handle") ? handleExpression : "NULL"),
            \(associatedGuidExpression)
        FROM chat_message_join cmj
        JOIN message ON message.ROWID = cmj.message_id
        \(schema.hasColumn("message", "handle_id") && schema.hasTable("handle") ? "LEFT JOIN handle ON handle.ROWID = message.handle_id" : "")
        WHERE cmj.chat_id = ?1
        ORDER BY message.date ASC, message.ROWID ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }
        database.bind(chatID, at: 1, in: statement)

        var participants: [String: ImportedParticipant] = [
            "you": ImportedParticipant(id: "you", displayName: "You")
        ]
        for (id, participant) in participantLookup {
            participants[id] = participant
        }

        var messages: [ImportedMessage] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let rowID = database.columnInt(statement, index: 0)
            let guid = database.columnText(statement, index: 1) ?? "message-\(rowID)"
            let rawText = database.columnText(statement, index: 2)
            let attributedBody = database.columnData(statement, index: 3)
            let bodyText = (rawText?.trimmed.nilIfBlank ?? decodeAttributedBody(attributedBody) ?? "").trimmed
            let timestamp = decodeMessagesDate(database.columnInt64(statement, index: 4)) ?? Date()
            let isOutgoing = database.columnInt(statement, index: 5) == 1
            let service = ServiceKind(rawArchiveValue: database.columnText(statement, index: 6) ?? candidate.serviceName ?? "Unknown")
            let handleName = database.columnText(statement, index: 7)?.trimmed.nilIfBlank
            let associatedGuid = database.columnText(statement, index: 8)?.trimmed.nilIfBlank

            let sender: ImportedParticipant
            let senderDisplayName: String
            if isOutgoing {
                sender = participants["you"]!
                senderDisplayName = "You"
            } else {
                if let handleName {
                    let resolved = resolvedHandle(for: handleName, contactResolver: contactResolver, cache: &resolvedHandles)
                    let participant = participants[resolved.participantID] ?? ImportedParticipant(id: resolved.participantID, displayName: resolved.label)
                    participants[resolved.participantID] = participant
                    sender = participant
                    senderDisplayName = resolved.title
                } else if let existingParticipant = participants.values.first(where: { $0.id != "you" }) {
                    sender = existingParticipant
                    senderDisplayName = existingParticipant.displayName
                } else {
                    let participant = ImportedParticipant(id: "participant-\(candidate.title.slugified)", displayName: candidate.title)
                    participants[participant.id] = participant
                    sender = participant
                    senderDisplayName = participant.displayName
                }
            }

            let attachments = attachmentLookup[rowID] ?? []
            if bodyText.isEmpty && attachments.isEmpty {
                continue
            }

            let attachmentIDs = orderedUniqueAttachmentIDs(from: attachments)

            messages.append(
                ImportedMessage(
                    id: guid.replacingOccurrences(of: ":", with: "-"),
                    senderID: sender.id,
                    senderDisplayName: senderDisplayName,
                    isOutgoing: isOutgoing,
                    bodyText: bodyText,
                    timestamp: timestamp,
                    service: service,
                    attachmentIDs: attachmentIDs,
                    replyToMessageID: associatedGuid?.replacingOccurrences(of: ":", with: "-"),
                    reactions: [],
                    metadataJSON: messageMetadataJSON(rowID: rowID, guid: guid, senderHandle: handleName)
                )
            )
        }
        timer.mark("message parsing", items: messages.count)

        let allAttachments = attachmentLookup.values.flatMap { $0 }
        let uniqueAttachments = orderedUniqueAttachments(from: allAttachments).sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
        timer.mark("archive assembly", items: uniqueAttachments.count)

        let warnings = [
            "Imported from the local Messages database on this Mac. Coverage depends on what message history is currently available locally.",
            "This importer uses the current Messages database schema on macOS and may need updates across OS changes."
        ]

        let stableKey = candidate.participantNames.joined(separator: "|").ifEmpty(candidate.title)
        let threadID = "messages-mac-\(candidate.id)-\(StableHash.fnv1a64Hex(stableKey).prefix(8))"

        return ImportedConversationArchive(
            id: threadID,
            title: candidate.title,
            participants: participants.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            messages: messages.sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.id < $1.id
                }
                return $0.timestamp < $1.timestamp
            },
            attachments: uniqueAttachments,
            warnings: warnings,
            sourceFilename: "messages-mac-\(candidate.title.slugified).json"
        )
    }

    private func messageMetadataJSON(rowID: Int, guid: String, senderHandle: String?) -> String {
        var metadata: [String: Any] = [
            "import_source": "messages_mac_beta",
            "messages_guid": guid,
            "messages_rowid": rowID
        ]
        if let senderHandle = senderHandle?.trimmed.nilIfBlank {
            metadata["sender_handle"] = senderHandle
        }

        guard JSONSerialization.isValidJSONObject(metadata),
              let data = try? JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8)
        else {
            return "{\"import_source\":\"messages_mac_beta\",\"messages_guid\":\"\(guid)\",\"messages_rowid\":\(rowID)}"
        }
        return json
    }

    private func loadChatParticipants(
        chatID: Int,
        database: SQLiteDatabase,
        schema: MessagesStoreSchema,
        contactResolver: MessagesContactResolver,
        resolvedHandles: inout [String: ResolvedMessagesHandle]
    ) throws -> [String: ImportedParticipant] {
        guard schema.hasTable("chat_handle_join"), schema.hasTable("handle") else {
            return [:]
        }

        let sql = """
        SELECT DISTINCT \(schema.handleDisplayExpression)
        FROM chat_handle_join
        JOIN handle ON handle.ROWID = chat_handle_join.handle_id
        WHERE chat_handle_join.chat_id = ?1;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }
        database.bind(chatID, at: 1, in: statement)

        var participants: [String: ImportedParticipant] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let identifier = database.columnText(statement, index: 0)?.trimmed.nilIfBlank else {
                continue
            }
            let resolved = resolvedHandle(for: identifier, contactResolver: contactResolver, cache: &resolvedHandles)
            participants[resolved.participantID] = ImportedParticipant(id: resolved.participantID, displayName: resolved.label)
        }
        return participants
    }

    private func resolvedHandle(
        for identifier: String,
        contactResolver: MessagesContactResolver,
        cache: inout [String: ResolvedMessagesHandle]
    ) -> ResolvedMessagesHandle {
        let trimmedIdentifier = identifier.trimmed
        let cacheKey = trimmedIdentifier.lowercased()
        if let cached = cache[cacheKey] {
            return cached
        }

        let resolved = ResolvedMessagesHandle(
            identifier: trimmedIdentifier,
            contactName: contactResolver.contactName(for: trimmedIdentifier),
            contactIdentifier: contactResolver.contactIdentifier(for: trimmedIdentifier)
        )
        cache[cacheKey] = resolved
        return resolved
    }

    private func loadAttachments(
        chatID: Int,
        database: SQLiteDatabase,
        schema: MessagesStoreSchema,
        messagesFolderURL: URL
    ) throws -> [Int: [ImportedAttachment]] {
        guard schema.hasTable("message_attachment_join"), schema.hasTable("attachment") else {
            return [:]
        }

        let filenameExpression = schema.hasColumn("attachment", "filename") ? "attachment.filename" : "NULL"
        let mimeExpression = schema.hasColumn("attachment", "mime_type") ? "attachment.mime_type" : "NULL"
        let transferNameExpression = schema.hasColumn("attachment", "transfer_name") ? "attachment.transfer_name" : "NULL"
        let utiExpression = schema.hasColumn("attachment", "uti") ? "attachment.uti" : "NULL"

        let sql = """
        SELECT
            maj.message_id,
            attachment.ROWID,
            \(filenameExpression),
            \(mimeExpression),
            \(transferNameExpression),
            \(utiExpression)
        FROM chat_message_join cmj
        JOIN message_attachment_join maj ON maj.message_id = cmj.message_id
        JOIN attachment ON attachment.ROWID = maj.attachment_id
        WHERE cmj.chat_id = ?1
        ORDER BY maj.message_id ASC, attachment.ROWID ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }
        database.bind(chatID, at: 1, in: statement)

        var attachmentsByMessage: [Int: [ImportedAttachment]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnInt(statement, index: 0)
            let attachmentRowID = database.columnInt(statement, index: 1)
            let filename = database.columnText(statement, index: 2)?.trimmed.nilIfBlank
            let mimeType = database.columnText(statement, index: 3)?.trimmed.nilIfBlank
            let transferName = database.columnText(statement, index: 4)?.trimmed.nilIfBlank
            let uti = database.columnText(statement, index: 5)?.trimmed.nilIfBlank
            let resolvedPath = resolveAttachmentPath(filename, messagesFolderURL: messagesFolderURL)
            let displayName = transferName ?? resolvedPath?.lastPathComponent ?? filename?.components(separatedBy: "/").last ?? "Attachment \(attachmentRowID)"

            attachmentsByMessage[messageID, default: []].append(
                ImportedAttachment(
                    id: "messages-attachment-\(attachmentRowID)",
                    type: inferAttachmentKind(path: resolvedPath?.path, filename: displayName, mimeType: mimeType, uti: uti),
                    filename: displayName,
                    localPath: resolvedPath?.path,
                    mimeType: mimeType,
                    thumbnail: nil,
                    url: filename?.hasPrefix("http") == true ? filename : nil
                )
            )
        }
        return attachmentsByMessage
    }

    private func inferredChatTitle(displayName: String?, identifier: String?, participantNames: [String], rowID: Int) -> String {
        if let displayName {
            return displayName
        }
        if participantNames.count == 1, let first = participantNames.first {
            return first
        }
        if !participantNames.isEmpty {
            return participantNames.joined(separator: ", ")
        }
        return identifier ?? "Messages Chat \(rowID)"
    }

    private func conversationTitleFallbackNames(
        resolvedParticipants: [ResolvedMessagesHandle],
        resolvedIdentifier: ResolvedMessagesHandle?
    ) -> [String] {
        if resolvedParticipants.count == 1, let participant = resolvedParticipants.first {
            return [participant.label]
        }

        let participantTitles = resolvedParticipants
            .map(\.title)
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !participantTitles.isEmpty {
            return participantTitles
        }

        if let resolvedIdentifier {
            return [resolvedIdentifier.label]
        }

        return []
    }

    private func decodeMessagesDate(_ rawValue: Int64) -> Date? {
        guard rawValue != 0 else { return nil }
        let absolute = abs(rawValue)
        let seconds: Double
        if absolute > 10_000_000_000_000_000 {
            seconds = Double(rawValue) / 1_000_000_000
        } else if absolute > 10_000_000_000 {
            seconds = Double(rawValue) / 1_000_000_000
        } else {
            seconds = Double(rawValue)
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    private func decodeAttributedBody(_ data: Data?) -> String? {
        guard let data, !data.isEmpty else { return nil }

        if let attributed = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            return attributed.string.trimmed.nilIfBlank
        }

        if let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = false
            let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
            unarchiver.finishDecoding()
            if let attributed = object as? NSAttributedString {
                return attributed.string.trimmed.nilIfBlank
            }
            if let string = object as? NSString {
                return String(string).trimmed.nilIfBlank
            }
        }

        if let object = legacyTypedstreamObject(from: data) {
            if let attributed = object as? NSAttributedString {
                return attributed.string.trimmed.nilIfBlank
            }
            if let string = object as? NSString {
                return String(string).trimmed.nilIfBlank
            }
        }

        if let string = String(data: data, encoding: .utf8)?.trimmed.nilIfBlank {
            return string
        }

        return nil
    }

    private func legacyTypedstreamObject(from data: Data) -> Any? {
        guard let nsUnarchiverClass = NSClassFromString("NSUnarchiver") as? NSObject.Type else {
            return nil
        }

        let classObject = nsUnarchiverClass as AnyObject
        let allocSelector = NSSelectorFromString("alloc")
        let initSelector = NSSelectorFromString("initForReadingWithData:")
        let decodeSelector = NSSelectorFromString("decodeObject")
        let finishSelector = NSSelectorFromString("finishDecoding")

        guard let allocated = classObject.perform(allocSelector)?.takeUnretainedValue() as? NSObject,
              let unarchiver = allocated.perform(initSelector, with: data)?.takeUnretainedValue() as? NSObject
        else {
            return nil
        }

        let decodedObject = unarchiver.perform(decodeSelector)?.takeUnretainedValue()
        if unarchiver.responds(to: finishSelector) {
            _ = unarchiver.perform(finishSelector)
        }
        return decodedObject
    }

    private func orderedUniqueAttachments(from attachments: [ImportedAttachment]) -> [ImportedAttachment] {
        var seen = Set<String>()
        var unique: [ImportedAttachment] = []

        for attachment in attachments where seen.insert(attachment.id).inserted {
            unique.append(attachment)
        }

        return unique
    }

    private func orderedUniqueAttachmentIDs(from attachments: [ImportedAttachment]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []

        for attachment in attachments where seen.insert(attachment.id).inserted {
            unique.append(attachment.id)
        }

        return unique
    }

    private func resolveAttachmentPath(_ rawFilename: String?, messagesFolderURL: URL) -> URL? {
        guard let rawFilename = rawFilename?.trimmed.nilIfBlank else { return nil }

        if rawFilename.hasPrefix("file://"), let url = URL(string: rawFilename) {
            return url
        }

        if rawFilename.hasPrefix("~/") {
            return URL(fileURLWithPath: NSString(string: rawFilename).expandingTildeInPath)
        }

        if rawFilename.hasPrefix("/") {
            return URL(fileURLWithPath: rawFilename)
        }

        return messagesFolderURL.appendingPathComponent(rawFilename)
    }

    private func inferAttachmentKind(path: String?, filename: String, mimeType: String?, uti: String?) -> AttachmentKind {
        if let mimeType {
            if mimeType.hasPrefix("image/") { return .image }
            if mimeType.hasPrefix("video/") { return .video }
            if mimeType.hasPrefix("audio/") { return .audio }
            if mimeType == "text/html" { return .link }
        }

        let lowerUTI = uti?.lowercased() ?? ""
        if lowerUTI.contains("image") { return .image }
        if lowerUTI.contains("movie") || lowerUTI.contains("video") { return .video }
        if lowerUTI.contains("audio") { return .audio }
        if lowerUTI.contains("url") || lowerUTI.contains("link") { return .link }

        let ext = URL(fileURLWithPath: path ?? filename).pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "heic", "webp"].contains(ext) { return .image }
        if ["mov", "mp4", "m4v", "avi"].contains(ext) { return .video }
        if ["m4a", "mp3", "wav", "aac"].contains(ext) { return .audio }
        if ["webloc", "url"].contains(ext) { return .link }
        return .file
    }
}

private struct ResolvedMessagesHandle {
    let identifier: String
    let contactName: String?
    let contactIdentifier: String?

    var title: String {
        contactName?.trimmed.nilIfBlank ?? identifier
    }

    var label: String {
        guard let contactName = contactName?.trimmed.nilIfBlank,
              contactName.localizedCaseInsensitiveCompare(identifier) != .orderedSame
        else {
            return identifier
        }
        return "\(contactName) (\(identifier))"
    }

    var participantID: String {
        if let contactIdentifier = contactIdentifier?.trimmed.nilIfBlank {
            return "contact-\(contactIdentifier.slugified)"
        }
        return "participant-\(identifier.slugified)"
    }
}

private final class MessagesContactResolver {
    private let phoneIndex: [String: String]
    private let emailIndex: [String: String]
    private let contactIdentifierIndex: [String: String]

    init(enabled: Bool = true) {
        guard enabled, CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            phoneIndex = [:]
            emailIndex = [:]
            contactIdentifierIndex = [:]
            return
        }

        let store = CNContactStore()
        var phoneIndex: [String: String] = [:]
        var emailIndex: [String: String] = [:]
        var contactIdentifierIndex: [String: String] = [:]
        let keysToFetch: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keysToFetch)

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                guard let displayName = Self.displayName(for: contact).trimmed.nilIfBlank else {
                    return
                }

                for phoneNumber in contact.phoneNumbers {
                    for key in Self.phoneLookupKeys(for: phoneNumber.value.stringValue) {
                        phoneIndex[key] = phoneIndex[key] ?? displayName
                        contactIdentifierIndex[key] = contactIdentifierIndex[key] ?? contact.identifier
                    }
                }

                for email in contact.emailAddresses {
                    let key = Self.normalizedEmail(String(email.value))
                    guard !key.isEmpty else { continue }
                    emailIndex[key] = emailIndex[key] ?? displayName
                    contactIdentifierIndex[key] = contactIdentifierIndex[key] ?? contact.identifier
                }
            }
        } catch {
            phoneIndex = [:]
            emailIndex = [:]
            contactIdentifierIndex = [:]
        }

        self.phoneIndex = phoneIndex
        self.emailIndex = emailIndex
        self.contactIdentifierIndex = contactIdentifierIndex
    }

    func contactName(for identifier: String) -> String? {
        let trimmedIdentifier = identifier.trimmed
        if trimmedIdentifier.contains("@") {
            return emailIndex[Self.normalizedEmail(trimmedIdentifier)]
        }

        for key in Self.phoneLookupKeys(for: trimmedIdentifier) {
            if let name = phoneIndex[key] {
                return name
            }
        }
        return nil
    }

    func contactIdentifier(for identifier: String) -> String? {
        let trimmedIdentifier = identifier.trimmed
        if trimmedIdentifier.contains("@") {
            return contactIdentifierIndex[Self.normalizedEmail(trimmedIdentifier)]
        }

        for key in Self.phoneLookupKeys(for: trimmedIdentifier) {
            if let identifier = contactIdentifierIndex[key] {
                return identifier
            }
        }
        return nil
    }

    private static func displayName(for contact: CNContact) -> String {
        let nickname = contact.nickname.trimmed.nilIfBlank
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)?.trimmed.nilIfBlank
        let company = contact.organizationName.trimmed.nilIfBlank

        var components: [String] = []

        if let nickname {
            components.append(nickname)
        }

        if let fullName,
           !components.contains(where: { $0.localizedCaseInsensitiveCompare(fullName) == .orderedSame }) {
            components.append(fullName)
        }

        if let company,
           !components.contains(where: { $0.localizedCaseInsensitiveCompare(company) == .orderedSame }) {
            components.append(company)
        }

        return components.joined(separator: " · ")
    }

    private static func normalizedEmail(_ email: String) -> String {
        email.trimmed.lowercased()
    }

    private static func phoneLookupKeys(for value: String) -> [String] {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else {
            return []
        }

        var keys: [String] = []

        func append(_ candidate: String) {
            guard !candidate.isEmpty, !keys.contains(candidate) else { return }
            keys.append(candidate)
        }

        append(digits)

        if digits.count == 11, digits.hasPrefix("1") {
            append(String(digits.dropFirst()))
        }

        if digits.count > 10 {
            append(String(digits.suffix(10)))
        }

        if digits.hasPrefix("001"), digits.count > 3 {
            append(String(digits.dropFirst(2)))
        }

        return keys
    }
}

private struct MessagesStoreSchema {
    let columnsByTable: [String: Set<String>]

    static func load(from database: SQLiteDatabase) throws -> MessagesStoreSchema {
        let tablesStatement = try database.prepare("SELECT name FROM sqlite_master WHERE type='table';")
        defer { database.finalize(tablesStatement) }

        var columnsByTable: [String: Set<String>] = [:]
        while sqlite3_step(tablesStatement) == SQLITE_ROW {
            let table = database.columnText(tablesStatement, index: 0) ?? ""
            let statement = try database.prepare("PRAGMA table_info(\(table));")
            defer { database.finalize(statement) }

            var columns: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let name = database.columnText(statement, index: 1) {
                    columns.insert(name)
                }
            }
            columnsByTable[table] = columns
        }

        return MessagesStoreSchema(columnsByTable: columnsByTable)
    }

    func hasTable(_ name: String) -> Bool {
        columnsByTable[name] != nil
    }

    func hasColumn(_ table: String, _ column: String) -> Bool {
        columnsByTable[table]?.contains(column) == true
    }

    var handleDisplayExpression: String {
        if hasColumn("handle", "uncanonicalized_id") {
            return "COALESCE(handle.uncanonicalized_id, handle.id)"
        }
        if hasColumn("handle", "id") {
            return "handle.id"
        }
        return "NULL"
    }
}

private extension String {
    func ifEmpty(_ fallback: @autoclosure () -> String) -> String {
        trimmed.isEmpty ? fallback() : self
    }
}
