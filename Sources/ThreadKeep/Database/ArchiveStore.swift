import Foundation
import SQLite3

actor ArchiveStore {
    private let maxThreadSearchResults = 250
    private let maxLibrarySearchResults = 250

    let databaseURL: URL
    let libraryDirectoryURL: URL
    let importsDirectoryURL: URL

    private let database: SQLiteDatabase
    private let fileManager: FileManager
    private var existingSourceMessageIDCache: Set<String>?

    init(fileManager: FileManager = .default, libraryDirectoryURL: URL? = nil) throws {
        self.fileManager = fileManager

        if let libraryDirectoryURL {
            self.libraryDirectoryURL = libraryDirectoryURL
        } else {
            let appSupport = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            self.libraryDirectoryURL = appSupport.appendingPathComponent("ThreadKeep", isDirectory: true)
        }
        importsDirectoryURL = self.libraryDirectoryURL.appendingPathComponent("ImportedArchives", isDirectory: true)
        databaseURL = self.libraryDirectoryURL.appendingPathComponent("threadkeep.sqlite")

        if !fileManager.fileExists(atPath: self.libraryDirectoryURL.path) {
            try fileManager.createDirectory(at: self.libraryDirectoryURL, withIntermediateDirectories: true)
        }

        if !fileManager.fileExists(atPath: importsDirectoryURL.path) {
            try fileManager.createDirectory(at: importsDirectoryURL, withIntermediateDirectories: true)
        }

        database = try SQLiteDatabase(url: databaseURL)
        try Self.initializeSchema(on: database)
        try Self.runDuplicateMessageCleanupMigrationIfNeeded(
            on: database,
            markerURL: self.libraryDirectoryURL.appendingPathComponent(".duplicate-message-cleanup-v1-complete")
        )
        try Self.runDuplicateMessageCleanupMigrationIfNeeded(
            on: database,
            markerURL: self.libraryDirectoryURL.appendingPathComponent(".duplicate-message-cleanup-v2-complete")
        )
        try Self.runDuplicateMessageCleanupMigrationIfNeeded(
            on: database,
            markerURL: self.libraryDirectoryURL.appendingPathComponent(".duplicate-message-cleanup-v3-complete")
        )
    }

    func ensureSeedArchiveImportedIfNeeded() throws -> Bool {
        guard try threadCount() == 0 else {
            return false
        }

        guard let url = Bundle.module.url(forResource: "sample-studio-archive", withExtension: "json") else {
            return false
        }

        let payload = try ArchiveParser.parseFile(at: url)
        try importArchive(payload)
        return true
    }

    func loadThreadSummaries(filters: LibraryFilters) throws -> [ThreadSummary] {
        let keyword = filters.keyword.trimmed
        let matchCounts = try matchingThreadCounts(for: keyword)
        let startTimestamp = filters.startDate.map { Calendar.current.startOfDay(for: $0).timeIntervalSince1970 }
        let endTimestamp = filters.endDate.flatMap { date in
            Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: date))?.timeIntervalSince1970
        }

        let sql = """
        SELECT
            t.id,
            t.title,
            t.start_date,
            t.end_date,
            t.participant_count,
            t.message_count,
            t.attachment_count,
            t.has_attachments,
            t.imported_at,
            t.raw_archive_path,
            t.import_source_kind,
            GROUP_CONCAT(p.display_name),
            latest.body_text,
            latest.timestamp,
            latest.sender_display_name,
            latest.is_outgoing
        FROM threads t
        LEFT JOIN thread_participants tp ON tp.thread_id = t.id
        LEFT JOIN participants p ON p.id = tp.participant_id
        LEFT JOIN messages latest ON latest.id = (
            SELECT m2.id
            FROM messages m2
            WHERE m2.thread_id = t.id
            ORDER BY m2.timestamp DESC, m2.id DESC
            LIMIT 1
        )
        WHERE
            (
                (?1 IS NULL AND ?2 IS NULL) OR
                EXISTS (
                    SELECT 1
                    FROM messages filtered_messages
                    WHERE filtered_messages.thread_id = t.id
                      AND (?1 IS NULL OR filtered_messages.timestamp >= ?1)
                      AND (?2 IS NULL OR filtered_messages.timestamp < ?2)
                )
            ) AND
            (?3 = 0 OR EXISTS (
                SELECT 1
                FROM attachments a
                WHERE a.thread_id = t.id
            )) AND
            (?4 IS NULL OR EXISTS (
                SELECT 1
                FROM thread_participants tp2
                WHERE tp2.thread_id = t.id AND tp2.participant_id = ?4
            ))
        GROUP BY t.id
        ORDER BY COALESCE(t.end_date, t.imported_at) DESC, t.title COLLATE NOCASE ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(startTimestamp, at: 1, in: statement)
        database.bind(endTimestamp, at: 2, in: statement)
        database.bind(filters.hasAttachmentsOnly, at: 3, in: statement)
        database.bind(filters.participantID, at: 4, in: statement)

        var summaries: [ThreadSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = database.columnText(statement, index: 0) ?? ""
            let matchCount = matchCounts[id]

            if !keyword.isEmpty && matchCount == nil {
                continue
            }

            let participantsCSV = database.columnText(statement, index: 11) ?? ""
            let participantNames = participantsCSV
                .split(separator: ",")
                .map(String.init)
                .map(\.trimmed)
                .filter { !$0.isEmpty }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }

            summaries.append(
                ThreadSummary(
                    id: id,
                    title: database.columnText(statement, index: 1) ?? "Untitled Thread",
                    startDate: database.columnDouble(statement, index: 2).map(Date.init(timeIntervalSince1970:)),
                    endDate: database.columnDouble(statement, index: 3).map(Date.init(timeIntervalSince1970:)),
                    participantNames: participantNames,
                    participantCount: database.columnInt(statement, index: 4),
                    messageCount: database.columnInt(statement, index: 5),
                    attachmentCount: database.columnInt(statement, index: 6),
                    hasAttachments: database.columnInt(statement, index: 7) == 1,
                    importedAt: Date(timeIntervalSince1970: database.columnDouble(statement, index: 8) ?? Date().timeIntervalSince1970),
                    rawArchivePath: database.columnText(statement, index: 9),
                    importSourceKind: ImportSourceKind(rawValue: database.columnText(statement, index: 10) ?? "") ?? .jsonArchive,
                    matchCount: matchCount,
                    latestMessageText: database.columnText(statement, index: 12),
                    latestMessageTimestamp: database.columnDouble(statement, index: 13).map(Date.init(timeIntervalSince1970:)),
                    latestSenderDisplayName: database.columnText(statement, index: 14),
                    latestMessageIsOutgoing: database.columnInt(statement, index: 15) == 1
                )
            )
        }

        return summaries
    }

    func loadParticipantOptions() throws -> [ParticipantRecord] {
        let sql = """
        SELECT DISTINCT p.id, p.display_name
        FROM participants p
        JOIN thread_participants tp ON tp.participant_id = p.id
        ORDER BY p.display_name COLLATE NOCASE ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        var participants: [ParticipantRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            participants.append(
                ParticipantRecord(
                    id: database.columnText(statement, index: 0) ?? "",
                    displayName: database.columnText(statement, index: 1) ?? "Unknown"
                )
            )
        }
        return participants
    }

    func loadThreadDetail(id threadID: String) throws -> ThreadDetail? {
        guard let summary = try loadThreadSummary(id: threadID) else {
            return nil
        }

        let participants = try loadParticipants(for: threadID)
        let attachmentsByMessage = try loadAttachmentsByMessage(for: threadID)
        let reactionsByMessage = try loadReactionsByMessage(for: threadID)

        let sql = """
        SELECT id, sender_id, sender_display_name, is_outgoing, body_text, timestamp, service, reply_to_message_id, metadata_json
        FROM messages
        WHERE thread_id = ?1
        ORDER BY timestamp ASC, id ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)

        var messages: [MessageRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            messages.append(
                MessageRecord(
                    id: messageID,
                    threadID: threadID,
                    senderID: database.columnText(statement, index: 1) ?? "",
                    senderDisplayName: database.columnText(statement, index: 2) ?? "Unknown",
                    isOutgoing: database.columnInt(statement, index: 3) == 1,
                    bodyText: database.columnText(statement, index: 4) ?? "",
                    timestamp: Date(timeIntervalSince1970: database.columnDouble(statement, index: 5) ?? 0),
                    service: ServiceKind(rawArchiveValue: database.columnText(statement, index: 6) ?? "Unknown"),
                    attachments: attachmentsByMessage[messageID] ?? [],
                    replyToMessageID: database.columnText(statement, index: 7),
                    reactions: reactionsByMessage[messageID] ?? [],
                    metadataJSON: database.columnText(statement, index: 8)
                )
            )
        }

        let visibleMessages = deduplicatedMessagesForDisplay(messages)
        let statistics = makeStatistics(messages: visibleMessages)

        return ThreadDetail(
            id: summary.id,
            title: summary.title,
            participants: participants,
            messages: visibleMessages,
            statistics: statistics,
            rawArchivePath: summary.rawArchivePath,
            importedAt: summary.importedAt,
            importSourceKind: summary.importSourceKind,
            isMergedThread: false
        )
    }

    func loadMergedThreadDetail(id mergedThreadID: String, title: String, threadIDs: [String]) throws -> ThreadDetail? {
        let details = try threadIDs.compactMap { try loadThreadDetail(id: $0) }
        guard !details.isEmpty else { return nil }

        var participants: [ParticipantRecord] = []
        var seenParticipantKeys = Set<String>()
        for participant in details.flatMap(\.participants) {
            let key = participant.displayName.lowercased()
            guard seenParticipantKeys.insert(key).inserted else { continue }
            participants.append(participant)
        }

        let messages = deduplicatedMessagesForDisplay(details
            .flatMap(\.messages)
            .sorted {
                if $0.timestamp == $1.timestamp {
                    return $0.id < $1.id
                }
                return $0.timestamp < $1.timestamp
            })

        let statistics = makeStatistics(messages: messages)
        let importedAt = details.map(\.importedAt).min() ?? Date()
        let sourceKind = details.first?.importSourceKind ?? .jsonArchive

        return ThreadDetail(
            id: mergedThreadID,
            title: title,
            participants: participants,
            messages: messages,
            statistics: statistics,
            rawArchivePath: nil,
            importedAt: importedAt,
            importSourceKind: sourceKind,
            isMergedThread: true
        )
    }

    func searchInThread(threadID: String, query: String) throws -> [ThreadSearchResult] {
        let trimmedQuery = query.trimmed
        guard !trimmedQuery.isEmpty else {
            return []
        }

        if let expression = ftsExpression(for: trimmedQuery) {
            do {
                let results = try searchInThreadUsingFTS(threadID: threadID, expression: expression)
                if !results.isEmpty {
                    return results
                }
            } catch {
                // Fall back to substring search for queries the tokenizer does not satisfy well.
            }
        }

        return try searchInThreadUsingLike(threadID: threadID, query: trimmedQuery)
    }

    func searchLibrary(query: String) throws -> [LibrarySearchResult] {
        let trimmedQuery = query.trimmed
        guard !trimmedQuery.isEmpty else {
            return []
        }

        if let expression = ftsExpression(for: trimmedQuery) {
            do {
                let results = try searchLibraryUsingFTS(expression: expression)
                if !results.isEmpty {
                    return results
                }
            } catch {
                // Fall back to substring search for queries the tokenizer does not satisfy well.
            }
        }

        return try searchLibraryUsingLike(query: trimmedQuery)
    }

    private func searchLibraryUsingFTS(expression: String) throws -> [LibrarySearchResult] {
        let sql = """
        SELECT
            m.thread_id,
            m.id,
            t.title,
            (
                SELECT GROUP_CONCAT(p.display_name)
                FROM thread_participants tp
                JOIN participants p ON p.id = tp.participant_id
                WHERE tp.thread_id = m.thread_id
            ),
            m.sender_display_name,
            m.timestamp,
            snippet(message_fts, 0, '…', '…', '[[', ']]', 18),
            m.is_outgoing,
            m.body_text,
            m.service,
            m.metadata_json
        FROM message_fts
        JOIN messages m ON m.id = message_fts.message_id
        JOIN threads t ON t.id = m.thread_id
        WHERE message_fts MATCH ?1
        ORDER BY m.timestamp DESC, m.id DESC
        LIMIT ?2;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(expression, at: 1, in: statement)
        database.bind(maxLibrarySearchResults, at: 2, in: statement)

        return try collectLibrarySearchResults(from: statement, idPrefix: "fts")
    }

    private func searchLibraryUsingLike(query: String) throws -> [LibrarySearchResult] {
        let sql = """
        SELECT
            m.thread_id,
            m.id,
            t.title,
            (
                SELECT GROUP_CONCAT(p.display_name)
                FROM thread_participants tp
                JOIN participants p ON p.id = tp.participant_id
                WHERE tp.thread_id = m.thread_id
            ),
            m.sender_display_name,
            m.timestamp,
            m.body_text,
            m.is_outgoing,
            m.body_text,
            m.service,
            m.metadata_json
        FROM messages m
        JOIN threads t ON t.id = m.thread_id
        WHERE m.body_text LIKE ?1 COLLATE NOCASE
           OR m.sender_display_name LIKE ?1 COLLATE NOCASE
        ORDER BY m.timestamp DESC, m.id DESC
        LIMIT ?2;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind("%\(query)%", at: 1, in: statement)
        database.bind(maxLibrarySearchResults, at: 2, in: statement)

        return try collectLibrarySearchResults(from: statement, idPrefix: "like", snippetQuery: query)
    }

    private func collectLibrarySearchResults(
        from statement: OpaquePointer?,
        idPrefix: String,
        snippetQuery: String? = nil
        ) throws -> [LibrarySearchResult] {
        var results: [LibrarySearchResult] = []
        var seenDuplicateKeys = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let threadID = database.columnText(statement, index: 0) ?? ""
            let messageID = database.columnText(statement, index: 1) ?? ""
            let duplicateKeys = SearchMessageDuplicateKey.keys(
                scope: nil,
                messageID: messageID,
                senderDisplayName: database.columnText(statement, index: 4) ?? "Unknown",
                isOutgoing: database.columnInt(statement, index: 7) == 1,
                timestamp: database.columnDouble(statement, index: 5) ?? 0,
                bodyText: database.columnText(statement, index: 8) ?? "",
                service: database.columnText(statement, index: 9) ?? "",
                metadataJSON: database.columnText(statement, index: 10)
            )
            guard duplicateKeys.allSatisfy({ !seenDuplicateKeys.contains($0) }) else { continue }
            seenDuplicateKeys.formUnion(duplicateKeys)

            let participantsCSV = database.columnText(statement, index: 3) ?? ""
            let participantNames = participantsCSV
                .split(separator: ",")
                .map(String.init)
                .map(\.trimmed)
                .filter { !$0.isEmpty }

            let rawSnippet = database.columnText(statement, index: 6) ?? ""
            let snippet = snippetQuery.map { query in self.snippet(for: rawSnippet, query: query) }
                ?? rawSnippet.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")

            results.append(
                LibrarySearchResult(
                    id: "\(idPrefix)-\(messageID)",
                    threadID: threadID,
                    messageID: messageID,
                    threadTitle: database.columnText(statement, index: 2) ?? "Untitled Thread",
                    participantNames: participantNames,
                    senderDisplayName: database.columnText(statement, index: 4) ?? "Unknown",
                    timestamp: Date(timeIntervalSince1970: database.columnDouble(statement, index: 5) ?? 0),
                    snippet: snippet
                )
            )
        }
        return results
    }

    private func searchInThreadUsingFTS(threadID: String, expression: String) throws -> [ThreadSearchResult] {
        let sql = """
        SELECT
            m.id,
            m.sender_display_name,
            m.timestamp,
            snippet(message_fts, 0, '…', '…', '[[', ']]', 16),
            m.is_outgoing,
            m.body_text,
            m.service,
            m.metadata_json
        FROM message_fts
        JOIN messages m ON m.id = message_fts.message_id
        WHERE message_fts MATCH ?1 AND message_fts.thread_id = ?2
        ORDER BY m.timestamp ASC, m.id ASC
        LIMIT ?3;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(expression, at: 1, in: statement)
        database.bind(threadID, at: 2, in: statement)
        database.bind(maxThreadSearchResults, at: 3, in: statement)

        var results: [ThreadSearchResult] = []
        var seenDuplicateKeys = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            let duplicateKeys = SearchMessageDuplicateKey.keys(
                scope: threadID,
                messageID: messageID,
                senderDisplayName: database.columnText(statement, index: 1) ?? "Unknown",
                isOutgoing: database.columnInt(statement, index: 4) == 1,
                timestamp: database.columnDouble(statement, index: 2) ?? 0,
                bodyText: database.columnText(statement, index: 5) ?? "",
                service: database.columnText(statement, index: 6) ?? "",
                metadataJSON: database.columnText(statement, index: 7)
            )
            guard duplicateKeys.allSatisfy({ !seenDuplicateKeys.contains($0) }) else { continue }
            seenDuplicateKeys.formUnion(duplicateKeys)
            results.append(
                ThreadSearchResult(
                    id: "fts-\(messageID)",
                    messageID: messageID,
                    senderDisplayName: database.columnText(statement, index: 1) ?? "Unknown",
                    timestamp: Date(timeIntervalSince1970: database.columnDouble(statement, index: 2) ?? 0),
                    snippet: (database.columnText(statement, index: 3) ?? "").replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                )
            )
        }
        return results
    }

    private func searchInThreadUsingLike(threadID: String, query: String) throws -> [ThreadSearchResult] {
        let sql = """
        SELECT id, sender_display_name, timestamp, body_text, is_outgoing, service, metadata_json
        FROM messages
        WHERE thread_id = ?1 AND body_text LIKE ?2 COLLATE NOCASE
        ORDER BY timestamp ASC
        LIMIT ?3;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)
        database.bind("%\(query)%", at: 2, in: statement)
        database.bind(maxThreadSearchResults, at: 3, in: statement)

        var results: [ThreadSearchResult] = []
        var seenDuplicateKeys = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            let text = database.columnText(statement, index: 3) ?? ""
            let messageID = database.columnText(statement, index: 0) ?? ""
            let duplicateKeys = SearchMessageDuplicateKey.keys(
                scope: threadID,
                messageID: messageID,
                senderDisplayName: database.columnText(statement, index: 1) ?? "Unknown",
                isOutgoing: database.columnInt(statement, index: 4) == 1,
                timestamp: database.columnDouble(statement, index: 2) ?? 0,
                bodyText: text,
                service: database.columnText(statement, index: 5) ?? "",
                metadataJSON: database.columnText(statement, index: 6)
            )
            guard duplicateKeys.allSatisfy({ !seenDuplicateKeys.contains($0) }) else { continue }
            seenDuplicateKeys.formUnion(duplicateKeys)
            results.append(
                ThreadSearchResult(
                    id: "like-\(messageID)",
                    messageID: messageID,
                    senderDisplayName: database.columnText(statement, index: 1) ?? "Unknown",
                    timestamp: Date(timeIntervalSince1970: database.columnDouble(statement, index: 2) ?? 0),
                    snippet: snippet(for: text, query: query)
                )
            )
        }
        return results
    }

    func importArchive(_ payload: ParsedArchivePayload) throws {
        var timer = ImportPerformanceTimer(label: payload.archive.title, logger: ThreadKeepLog.store)
        let archive = payload.archive
        let payloadDeduplicatedMessages = deduplicatedImportedMessages(archive.messages, archiveID: archive.id)
        timer.mark("dedupe key generation", items: payloadDeduplicatedMessages.count)

        let rawArchiveURL = importsDirectoryURL.appendingPathComponent(payload.storedFilename(for: archive.id))
        try payload.rawData.write(to: rawArchiveURL, options: .atomic)
        timer.mark("raw archive snapshot")

        let removedSourceMessageIDs = try sourceMessageIDs(threadID: archive.id)
        var existingSourceMessageIDs = try existingSourceMessageIDsForImport()
        existingSourceMessageIDs.subtract(removedSourceMessageIDs)
        let archiveMessages = messagesSkippingExistingSourceDuplicates(
            payloadDeduplicatedMessages,
            existingSourceMessageIDs: existingSourceMessageIDs
        )
        let insertedSourceMessageIDs = sourceMessageIDs(in: archiveMessages)
        timer.mark("existing source lookup + duplicate filtering", items: archiveMessages.count)

        let scopedParticipantIDs = Dictionary(uniqueKeysWithValues: archive.participants.map {
            ($0.id, scopedID(threadID: archive.id, kind: "participant", rawID: $0.id))
        })
        let scopedAttachmentIDs = Dictionary(uniqueKeysWithValues: archive.attachments.map {
            ($0.id, scopedID(threadID: archive.id, kind: "attachment", rawID: $0.id))
        })
        let scopedMessageIDs = Dictionary(uniqueKeysWithValues: archiveMessages.map {
            ($0.id, scopedID(threadID: archive.id, kind: "message", rawID: $0.id))
        })
        timer.mark("scoped id preparation")

        try database.transaction {
            try deleteThreadRecords(threadID: archive.id)

            guard !archiveMessages.isEmpty else {
                try Self.cleanupOrphanedParticipants(on: database)
                return
            }

            let threadInsert = try database.prepare(
                """
                INSERT INTO threads (
                    id, title, start_date, end_date, participant_count, message_count, attachment_count,
                    has_attachments, imported_at, raw_archive_path, import_source_kind
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11);
                """
            )
            defer { database.finalize(threadInsert) }

            let dateRange = dateRange(for: archiveMessages)
            database.bind(archive.id, at: 1, in: threadInsert)
            database.bind(archive.title, at: 2, in: threadInsert)
            database.bind(dateRange?.lowerBound.timeIntervalSince1970, at: 3, in: threadInsert)
            database.bind(dateRange?.upperBound.timeIntervalSince1970, at: 4, in: threadInsert)
            database.bind(archive.participantCount, at: 5, in: threadInsert)
            database.bind(archiveMessages.count, at: 6, in: threadInsert)
            database.bind(archive.attachmentCount, at: 7, in: threadInsert)
            database.bind(archive.attachmentCount > 0, at: 8, in: threadInsert)
            database.bind(Date().timeIntervalSince1970, at: 9, in: threadInsert)
            database.bind(rawArchiveURL.path, at: 10, in: threadInsert)
            database.bind(payload.sourceKind.rawValue, at: 11, in: threadInsert)
            try database.step(threadInsert)

            let participantInsert = try database.prepare(
                "INSERT OR REPLACE INTO participants (id, display_name) VALUES (?1, ?2);"
            )
            let threadParticipantInsert = try database.prepare(
                "INSERT INTO thread_participants (thread_id, participant_id) VALUES (?1, ?2);"
            )
            defer {
                database.finalize(participantInsert)
                database.finalize(threadParticipantInsert)
            }

            for participant in archive.participants {
                let participantID = scopedParticipantIDs[participant.id] ?? participant.id
                database.reset(participantInsert)
                database.bind(participantID, at: 1, in: participantInsert)
                database.bind(participant.displayName, at: 2, in: participantInsert)
                try database.step(participantInsert)

                database.reset(threadParticipantInsert)
                database.bind(archive.id, at: 1, in: threadParticipantInsert)
                database.bind(participantID, at: 2, in: threadParticipantInsert)
                try database.step(threadParticipantInsert)
            }

            let attachmentInsert = try database.prepare(
                """
                INSERT INTO attachments (id, thread_id, type, filename, local_path, mime_type, thumbnail, url)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8);
                """
            )
            defer { database.finalize(attachmentInsert) }

            for attachment in archive.attachments {
                let attachmentID = scopedAttachmentIDs[attachment.id] ?? attachment.id
                database.reset(attachmentInsert)
                database.bind(attachmentID, at: 1, in: attachmentInsert)
                database.bind(archive.id, at: 2, in: attachmentInsert)
                database.bind(attachment.type.rawValue, at: 3, in: attachmentInsert)
                database.bind(attachment.filename, at: 4, in: attachmentInsert)
                database.bind(attachment.localPath, at: 5, in: attachmentInsert)
                database.bind(attachment.mimeType, at: 6, in: attachmentInsert)
                database.bind(attachment.thumbnail, at: 7, in: attachmentInsert)
                database.bind(attachment.url, at: 8, in: attachmentInsert)
                try database.step(attachmentInsert)
            }

            let messageInsert = try database.prepare(
                """
                INSERT INTO messages (
                    id, thread_id, sender_id, sender_display_name, is_outgoing, body_text,
                    timestamp, service, reply_to_message_id, metadata_json
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10);
                """
            )
            let messageAttachmentInsert = try database.prepare(
                "INSERT INTO message_attachments (message_id, attachment_id, position) VALUES (?1, ?2, ?3);"
            )
            let reactionInsert = try database.prepare(
                """
                INSERT INTO message_reactions (
                    thread_id, message_id, sender_id, sender_display_name, emoji, type
                )
                VALUES (?1, ?2, ?3, ?4, ?5, ?6);
                """
            )
            let ftsInsert = try database.prepare(
                """
                INSERT INTO message_fts (body_text, sender_display_name, message_id, thread_id, message_timestamp)
                VALUES (?1, ?2, ?3, ?4, ?5);
                """
            )
            defer {
                database.finalize(messageInsert)
                database.finalize(messageAttachmentInsert)
                database.finalize(reactionInsert)
                database.finalize(ftsInsert)
            }

            for message in archiveMessages {
                let messageID = scopedMessageIDs[message.id] ?? message.id
                let senderID = scopedParticipantIDs[message.senderID] ?? message.senderID
                let replyToMessageID = message.replyToMessageID.flatMap { scopedMessageIDs[$0] }
                database.reset(messageInsert)
                database.bind(messageID, at: 1, in: messageInsert)
                database.bind(archive.id, at: 2, in: messageInsert)
                database.bind(senderID, at: 3, in: messageInsert)
                database.bind(message.senderDisplayName, at: 4, in: messageInsert)
                database.bind(message.isOutgoing, at: 5, in: messageInsert)
                database.bind(message.bodyText, at: 6, in: messageInsert)
                database.bind(message.timestamp.timeIntervalSince1970, at: 7, in: messageInsert)
                database.bind(message.service.displayName, at: 8, in: messageInsert)
                database.bind(replyToMessageID, at: 9, in: messageInsert)
                database.bind(message.metadataJSON, at: 10, in: messageInsert)
                try database.step(messageInsert)

                database.reset(ftsInsert)
                database.bind(message.bodyText, at: 1, in: ftsInsert)
                database.bind(message.senderDisplayName, at: 2, in: ftsInsert)
                database.bind(messageID, at: 3, in: ftsInsert)
                database.bind(archive.id, at: 4, in: ftsInsert)
                database.bind(message.timestamp.timeIntervalSince1970, at: 5, in: ftsInsert)
                try database.step(ftsInsert)

                for (index, attachmentID) in message.attachmentIDs.enumerated() {
                    database.reset(messageAttachmentInsert)
                    database.bind(messageID, at: 1, in: messageAttachmentInsert)
                    database.bind(scopedAttachmentIDs[attachmentID] ?? attachmentID, at: 2, in: messageAttachmentInsert)
                    database.bind(index, at: 3, in: messageAttachmentInsert)
                    try database.step(messageAttachmentInsert)
                }

                for reaction in message.reactions {
                    database.reset(reactionInsert)
                    database.bind(archive.id, at: 1, in: reactionInsert)
                    database.bind(messageID, at: 2, in: reactionInsert)
                    database.bind(reaction.senderID.flatMap { scopedParticipantIDs[$0] }, at: 3, in: reactionInsert)
                    database.bind(reaction.senderDisplayName, at: 4, in: reactionInsert)
                    database.bind(reaction.emoji, at: 5, in: reactionInsert)
                    database.bind(reaction.type, at: 6, in: reactionInsert)
                    try database.step(reactionInsert)
                }
            }

            try Self.cleanupOrphanedParticipants(on: database)
        }

        updateCachedSourceMessageIDs(removing: removedSourceMessageIDs, adding: insertedSourceMessageIDs)
        timer.mark("database insertion + metadata updates", items: archiveMessages.count)
    }

    private func scopedID(threadID: String, kind: String, rawID: String) -> String {
        "\(threadID)::\(kind)::\(rawID)"
    }

    private func dateRange(for messages: [ImportedMessage]) -> ClosedRange<Date>? {
        guard let first = messages.first?.timestamp, let last = messages.last?.timestamp else {
            return nil
        }
        return first ... last
    }

    private func deduplicatedImportedMessages(_ messages: [ImportedMessage], archiveID: String) -> [ImportedMessage] {
        var seenKeys = Set<String>()
        return messages.filter { message in
            let keys = ImportedMessageDuplicateKey.keys(for: message, archiveID: archiveID)
            guard keys.allSatisfy({ !seenKeys.contains($0) }) else { return false }
            seenKeys.formUnion(keys)
            return true
        }
    }

    private func messagesSkippingExistingSourceDuplicates(
        _ messages: [ImportedMessage],
        existingSourceMessageIDs: Set<String>
    ) -> [ImportedMessage] {
        var seenSourceMessageIDs = existingSourceMessageIDs
        return messages.filter { message in
            let sourceIDs = MessageDuplicateKeyHelpers.sourceMessageIDs(from: message.metadataJSON)
            guard !sourceIDs.isEmpty else {
                return true
            }
            guard sourceIDs.allSatisfy({ !seenSourceMessageIDs.contains($0) }) else {
                return false
            }
            seenSourceMessageIDs.formUnion(sourceIDs)
            return true
        }
    }

    private func existingSourceMessageIDsForImport() throws -> Set<String> {
        if let existingSourceMessageIDCache {
            return existingSourceMessageIDCache
        }

        let ids = try Self.loadSourceMessageIDs(on: database)
        existingSourceMessageIDCache = ids
        return ids
    }

    private func sourceMessageIDs(threadID: String) throws -> Set<String> {
        try Self.loadSourceMessageIDs(on: database, threadID: threadID)
    }

    private func sourceMessageIDs(in messages: [ImportedMessage]) -> Set<String> {
        Set(messages.flatMap { MessageDuplicateKeyHelpers.sourceMessageIDs(from: $0.metadataJSON) })
    }

    private func updateCachedSourceMessageIDs(removing removedIDs: Set<String>, adding addedIDs: Set<String>) {
        guard existingSourceMessageIDCache != nil else { return }
        existingSourceMessageIDCache?.subtract(removedIDs)
        existingSourceMessageIDCache?.formUnion(addedIDs)
    }

    func exportRawArchiveData(for threadID: String) throws -> Data {
        guard let path = try loadThreadSummary(id: threadID)?.rawArchivePath else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    func exportThreadKeepArchiveData(for threadID: String) throws -> Data {
        let archive = try loadArchiveForThreadKeepExport(threadID: threadID)
        return try ThreadKeepMobileArchiveExporter().export(archive: archive)
    }

    func deleteThread(threadID: String) throws {
        let rawArchivePath = try loadThreadSummary(id: threadID)?.rawArchivePath
        let removedSourceMessageIDs = try sourceMessageIDs(threadID: threadID)
        try database.transaction {
            try deleteThreadRecords(threadID: threadID)
            try Self.cleanupOrphanedParticipants(on: database)
        }
        updateCachedSourceMessageIDs(removing: removedSourceMessageIDs, adding: [])

        if let rawArchivePath {
            try? fileManager.removeItem(atPath: rawArchivePath)
        }
    }

    private func loadArchiveForThreadKeepExport(threadID: String) throws -> ImportedConversationArchive {
        if let rawArchivePath = try loadThreadSummary(id: threadID)?.rawArchivePath {
            let rawArchiveURL = URL(fileURLWithPath: rawArchivePath)

            if fileManager.fileExists(atPath: rawArchiveURL.path),
               let payload = try? ArchiveParser.parseFile(at: rawArchiveURL) {
                return payload.archive
            }
        }

        guard let thread = try loadThreadDetail(id: threadID) else {
            throw CocoaError(.fileNoSuchFile)
        }

        return ImportedConversationArchive(
            id: thread.id,
            title: thread.title,
            participants: thread.participants.map { participant in
                ImportedParticipant(id: participant.id, displayName: participant.displayName)
            },
            messages: thread.messages.map { message in
                ImportedMessage(
                    id: message.id,
                    senderID: message.senderID,
                    senderDisplayName: message.senderDisplayName,
                    isOutgoing: message.isOutgoing,
                    bodyText: message.bodyText,
                    timestamp: message.timestamp,
                    service: message.service,
                    attachmentIDs: message.attachments.map(\.id),
                    replyToMessageID: message.replyToMessageID,
                    reactions: message.reactions.map { reaction in
                        ImportedReaction(
                            senderID: reaction.senderID,
                            senderDisplayName: reaction.senderDisplayName,
                            emoji: reaction.emoji,
                            type: reaction.type
                        )
                    },
                    metadataJSON: message.metadataJSON
                )
            },
            attachments: thread.allAttachments.map { attachment in
                ImportedAttachment(
                    id: attachment.id,
                    type: attachment.type,
                    filename: attachment.filename,
                    localPath: attachment.localPath,
                    mimeType: attachment.mimeType,
                    thumbnail: attachment.thumbnail,
                    url: attachment.url
                )
            },
            warnings: [],
            sourceFilename: thread.rawImportFilename
        )
    }

    func deleteAllData() throws {
        try database.transaction {
            try database.execute("DELETE FROM message_reactions;")
            try database.execute("DELETE FROM message_attachments;")
            try database.execute("DELETE FROM messages;")
            try database.execute("DELETE FROM attachments;")
            try database.execute("DELETE FROM thread_participants;")
            try database.execute("DELETE FROM threads;")
            try database.execute("DELETE FROM participants;")
            try database.execute("DELETE FROM message_fts;")
        }

        if fileManager.fileExists(atPath: importsDirectoryURL.path) {
            let contents = try fileManager.contentsOfDirectory(at: importsDirectoryURL, includingPropertiesForKeys: nil)
            for item in contents {
                try? fileManager.removeItem(at: item)
            }
        }

        existingSourceMessageIDCache = []
    }

    private static func initializeSchema(on database: SQLiteDatabase) throws {
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS threads (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                start_date REAL,
                end_date REAL,
                participant_count INTEGER NOT NULL,
                message_count INTEGER NOT NULL,
                attachment_count INTEGER NOT NULL,
                has_attachments INTEGER NOT NULL DEFAULT 0,
                imported_at REAL NOT NULL,
                raw_archive_path TEXT,
                import_source_kind TEXT NOT NULL DEFAULT 'jsonArchive'
            );

            CREATE TABLE IF NOT EXISTS participants (
                id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS thread_participants (
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                participant_id TEXT NOT NULL REFERENCES participants(id) ON DELETE CASCADE,
                PRIMARY KEY (thread_id, participant_id)
            );

            CREATE TABLE IF NOT EXISTS attachments (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                type TEXT NOT NULL,
                filename TEXT NOT NULL,
                local_path TEXT,
                mime_type TEXT,
                thumbnail TEXT,
                url TEXT
            );

            CREATE TABLE IF NOT EXISTS messages (
                id TEXT PRIMARY KEY,
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                sender_id TEXT NOT NULL,
                sender_display_name TEXT NOT NULL,
                is_outgoing INTEGER NOT NULL,
                body_text TEXT NOT NULL,
                timestamp REAL NOT NULL,
                service TEXT NOT NULL,
                reply_to_message_id TEXT,
                metadata_json TEXT
            );

            CREATE TABLE IF NOT EXISTS message_attachments (
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                attachment_id TEXT NOT NULL REFERENCES attachments(id) ON DELETE CASCADE,
                position INTEGER NOT NULL DEFAULT 0,
                PRIMARY KEY (message_id, attachment_id)
            );

            CREATE TABLE IF NOT EXISTS message_reactions (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                thread_id TEXT NOT NULL REFERENCES threads(id) ON DELETE CASCADE,
                message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
                sender_id TEXT,
                sender_display_name TEXT,
                emoji TEXT NOT NULL,
                type TEXT
            );

            CREATE INDEX IF NOT EXISTS idx_messages_thread_timestamp ON messages(thread_id, timestamp);
            CREATE INDEX IF NOT EXISTS idx_attachments_thread ON attachments(thread_id);
            CREATE INDEX IF NOT EXISTS idx_thread_participants_participant ON thread_participants(participant_id);
            CREATE INDEX IF NOT EXISTS idx_message_reactions_message ON message_reactions(message_id);
            """
        )

        try Self.ensureMessageFTSSchema(on: database)

        try Self.addColumnIfNeeded(
            on: database,
            table: "threads",
            column: "import_source_kind",
            definition: "TEXT NOT NULL DEFAULT 'jsonArchive'"
        )
    }

    private static func ensureMessageFTSSchema(on database: SQLiteDatabase) throws {
        let existingColumns = try tableColumns(database: database, table: "message_fts")
        let expectedColumns: Set<String> = [
            "body_text",
            "sender_display_name",
            "message_id",
            "thread_id",
            "message_timestamp"
        ]

        if !existingColumns.isEmpty && !expectedColumns.isSubset(of: existingColumns) {
            try database.execute("DROP TABLE IF EXISTS message_fts;")
        }

        try database.execute(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS message_fts USING fts5(
                body_text,
                sender_display_name,
                message_id UNINDEXED,
                thread_id UNINDEXED,
                message_timestamp UNINDEXED
            );
            """
        )

        if existingColumns.isEmpty || !expectedColumns.isSubset(of: existingColumns) {
            try rebuildMessageFTSIndex(on: database)
        }
    }

    private static func rebuildMessageFTSIndex(on database: SQLiteDatabase) throws {
        try database.execute(
            """
            INSERT INTO message_fts (body_text, sender_display_name, message_id, thread_id, message_timestamp)
            SELECT body_text, sender_display_name, id, thread_id, timestamp
            FROM messages;
            """
        )
    }

    private static func tableColumns(database: SQLiteDatabase, table: String) throws -> Set<String> {
        let statement = try database.prepare("PRAGMA table_info(\(table));")
        defer { database.finalize(statement) }

        var columns = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            if let column = database.columnText(statement, index: 1) {
                columns.insert(column)
            }
        }
        return columns
    }

    private func threadCount() throws -> Int {
        let statement = try database.prepare("SELECT COUNT(*) FROM threads;")
        defer { database.finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return 0
        }
        return database.columnInt(statement, index: 0)
    }

    private func loadThreadSummary(id threadID: String) throws -> ThreadSummary? {
        let sql = """
        SELECT id, title, start_date, end_date, participant_count, message_count, attachment_count,
               has_attachments, imported_at, raw_archive_path, import_source_kind
        FROM threads
        WHERE id = ?1
        LIMIT 1;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return ThreadSummary(
            id: database.columnText(statement, index: 0) ?? "",
            title: database.columnText(statement, index: 1) ?? "Untitled Thread",
            startDate: database.columnDouble(statement, index: 2).map(Date.init(timeIntervalSince1970:)),
            endDate: database.columnDouble(statement, index: 3).map(Date.init(timeIntervalSince1970:)),
            participantNames: try loadParticipants(for: threadID).map(\.displayName),
            participantCount: database.columnInt(statement, index: 4),
            messageCount: database.columnInt(statement, index: 5),
            attachmentCount: database.columnInt(statement, index: 6),
            hasAttachments: database.columnInt(statement, index: 7) == 1,
            importedAt: Date(timeIntervalSince1970: database.columnDouble(statement, index: 8) ?? Date().timeIntervalSince1970),
            rawArchivePath: database.columnText(statement, index: 9),
            importSourceKind: ImportSourceKind(rawValue: database.columnText(statement, index: 10) ?? "") ?? .jsonArchive,
            matchCount: nil,
            latestMessageText: nil,
            latestMessageTimestamp: nil,
            latestSenderDisplayName: nil,
            latestMessageIsOutgoing: false
        )
    }

    private func loadParticipants(for threadID: String) throws -> [ParticipantRecord] {
        let sql = """
        SELECT p.id, p.display_name
        FROM participants p
        JOIN thread_participants tp ON tp.participant_id = p.id
        WHERE tp.thread_id = ?1
        ORDER BY p.display_name COLLATE NOCASE ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)

        var participants: [ParticipantRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            participants.append(
                ParticipantRecord(
                    id: database.columnText(statement, index: 0) ?? "",
                    displayName: database.columnText(statement, index: 1) ?? "Unknown"
                )
            )
        }
        return participants
    }

    private func loadAttachmentsByMessage(for threadID: String) throws -> [String: [AttachmentRecord]] {
        let sql = """
        SELECT
            ma.message_id,
            a.id,
            a.type,
            a.filename,
            a.local_path,
            a.mime_type,
            a.thumbnail,
            a.url
        FROM message_attachments ma
        JOIN attachments a ON a.id = ma.attachment_id
        JOIN messages m ON m.id = ma.message_id
        WHERE m.thread_id = ?1
        ORDER BY m.timestamp ASC, ma.position ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)

        var result: [String: [AttachmentRecord]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            let attachment = AttachmentRecord(
                id: database.columnText(statement, index: 1) ?? "",
                type: AttachmentKind(rawArchiveValue: database.columnText(statement, index: 2) ?? "unknown"),
                filename: database.columnText(statement, index: 3) ?? "Attachment",
                localPath: database.columnText(statement, index: 4),
                mimeType: database.columnText(statement, index: 5),
                thumbnail: database.columnText(statement, index: 6),
                url: database.columnText(statement, index: 7)
            )
            result[messageID, default: []].append(attachment)
        }
        return result
    }

    private func loadReactionsByMessage(for threadID: String) throws -> [String: [MessageReactionRecord]] {
        let sql = """
        SELECT message_id, sender_id, sender_display_name, emoji, type
        FROM message_reactions
        WHERE thread_id = ?1
        ORDER BY id ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(threadID, at: 1, in: statement)

        var result: [String: [MessageReactionRecord]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            result[messageID, default: []].append(
                MessageReactionRecord(
                    senderID: database.columnText(statement, index: 1),
                    senderDisplayName: database.columnText(statement, index: 2),
                    emoji: database.columnText(statement, index: 3) ?? "",
                    type: database.columnText(statement, index: 4)
                )
            )
        }
        return result
    }

    private func matchingThreadCounts(for query: String) throws -> [String: Int] {
        let trimmedQuery = query.trimmed
        guard !trimmedQuery.isEmpty else {
            return [:]
        }

        if let expression = ftsExpression(for: trimmedQuery) {
            do {
                let counts = try matchingThreadCountsUsingFTS(expression: expression)
                if !counts.isEmpty {
                    return counts
                }
            } catch {
                // Fall back to substring search for queries that FTS tokenization misses.
            }
        }

        return try matchingThreadCountsUsingLike(query: trimmedQuery)
    }

    private func matchingThreadCountsUsingFTS(expression: String) throws -> [String: Int] {
        let sql = """
        SELECT thread_id, COUNT(*)
        FROM message_fts
        WHERE message_fts MATCH ?1
        GROUP BY thread_id;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind(expression, at: 1, in: statement)
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            counts[database.columnText(statement, index: 0) ?? ""] = database.columnInt(statement, index: 1)
        }
        return counts
    }

    private func matchingThreadCountsUsingLike(query: String) throws -> [String: Int] {
        let sql = """
        SELECT thread_id, COUNT(*)
        FROM messages
        WHERE body_text LIKE ?1 COLLATE NOCASE
        GROUP BY thread_id;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        database.bind("%\(query)%", at: 1, in: statement)
        var counts: [String: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            counts[database.columnText(statement, index: 0) ?? ""] = database.columnInt(statement, index: 1)
        }
        return counts
    }

    private func ftsExpression(for query: String) -> String? {
        let tokens = query
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map(\.trimmed)
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else {
            return nil
        }

        return tokens
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }
            .joined(separator: " AND ")
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

    private func deleteThreadRecords(threadID: String) throws {
        let ftsDelete = try database.prepare("DELETE FROM message_fts WHERE thread_id = ?1;")
        defer { database.finalize(ftsDelete) }
        database.bind(threadID, at: 1, in: ftsDelete)
        try database.step(ftsDelete)

        let delete = try database.prepare("DELETE FROM threads WHERE id = ?1;")
        defer { database.finalize(delete) }
        database.bind(threadID, at: 1, in: delete)
        try database.step(delete)
    }

    private static func cleanupOrphanedParticipants(on database: SQLiteDatabase) throws {
        try database.execute(
            """
            DELETE FROM participants
            WHERE id NOT IN (
                SELECT DISTINCT participant_id FROM thread_participants
            );
            """
        )
    }

    private static func addColumnIfNeeded(on database: SQLiteDatabase, table: String, column: String, definition: String) throws {
        let statement = try database.prepare("PRAGMA table_info(\(table));")
        defer { database.finalize(statement) }

        var hasColumn = false
        while sqlite3_step(statement) == SQLITE_ROW {
            if database.columnText(statement, index: 1) == column {
                hasColumn = true
                break
            }
        }

        if !hasColumn {
            try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
        }
    }

    private static func runDuplicateMessageCleanupMigrationIfNeeded(on database: SQLiteDatabase, markerURL: URL) throws {
        guard !FileManager.default.fileExists(atPath: markerURL.path) else {
            return
        }

        var timer = ImportPerformanceTimer(label: "duplicate cleanup migration", logger: ThreadKeepLog.store)
        let cleanedCount = try cleanupDuplicateStoredMessages(on: database)
        timer.mark("one-time stored duplicate cleanup", items: cleanedCount)

        let marker = "completed_at=\(ISO8601DateFormatter().string(from: Date()))\n"
        try marker.write(to: markerURL, atomically: true, encoding: .utf8)
    }

    private static func loadSourceMessageIDs(on database: SQLiteDatabase, threadID: String? = nil) throws -> Set<String> {
        let sql: String
        if threadID == nil {
            sql = """
            SELECT metadata_json
            FROM messages
            WHERE metadata_json IS NOT NULL
              AND (metadata_json LIKE '%messages_guid%' OR metadata_json LIKE '%messages_rowid%');
            """
        } else {
            sql = """
            SELECT metadata_json
            FROM messages
            WHERE thread_id = ?1
              AND metadata_json IS NOT NULL
              AND (metadata_json LIKE '%messages_guid%' OR metadata_json LIKE '%messages_rowid%');
            """
        }

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        if let threadID {
            database.bind(threadID, at: 1, in: statement)
        }

        var ids = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            ids.formUnion(MessageDuplicateKeyHelpers.sourceMessageIDs(from: database.columnText(statement, index: 0)))
        }
        return ids
    }

    @discardableResult
    private static func cleanupDuplicateStoredMessages(on database: SQLiteDatabase) throws -> Int {
        let candidates = try loadStoredMessageDuplicateCandidates(on: database)
        var seenKeys = Set<String>()
        var duplicateIDs: [String] = []

        for candidate in candidates {
            let keys = StoredMessageDuplicateKey.keys(for: candidate)
            guard keys.allSatisfy({ !seenKeys.contains($0) }) else {
                duplicateIDs.append(candidate.id)
                continue
            }
            seenKeys.formUnion(keys)
        }

        guard !duplicateIDs.isEmpty else {
            try database.transaction {
                try repairStoredThreadStatistics(on: database)
            }
            return 0
        }
        ThreadKeepLog.store.notice("Cleaning \(duplicateIDs.count, privacy: .public) duplicate stored message records.")

        try database.transaction {
            try database.execute("DROP TABLE IF EXISTS temp_duplicate_message_ids;")
            try database.execute("CREATE TEMP TABLE temp_duplicate_message_ids (id TEXT PRIMARY KEY);")

            let duplicateInsert = try database.prepare("INSERT OR IGNORE INTO temp_duplicate_message_ids (id) VALUES (?1);")
            defer { database.finalize(duplicateInsert) }

            for messageID in duplicateIDs {
                database.reset(duplicateInsert)
                database.bind(messageID, at: 1, in: duplicateInsert)
                try database.step(duplicateInsert)
            }

            try database.execute(
                """
                DELETE FROM messages
                WHERE id IN (SELECT id FROM temp_duplicate_message_ids);
                """
            )

            try repairStoredThreadStatistics(on: database)

            try database.execute("DELETE FROM message_fts;")
            try Self.rebuildMessageFTSIndex(on: database)
            try Self.cleanupOrphanedParticipants(on: database)
            try database.execute("DROP TABLE IF EXISTS temp_duplicate_message_ids;")
        }

        ThreadKeepLog.store.notice("Cleaned \(duplicateIDs.count, privacy: .public) duplicate stored message records and rebuilt message counts.")
        return duplicateIDs.count
    }

    private static func repairStoredThreadStatistics(on database: SQLiteDatabase) throws {
        try database.execute(
            """
            DELETE FROM threads
            WHERE id NOT IN (
                SELECT DISTINCT thread_id FROM messages
            );
            """
        )

        try database.execute(
            """
            DELETE FROM attachments
            WHERE id NOT IN (
                SELECT DISTINCT attachment_id FROM message_attachments
            );
            """
        )

        try database.execute(
            """
            UPDATE threads
            SET
                start_date = (SELECT MIN(timestamp) FROM messages WHERE messages.thread_id = threads.id),
                end_date = (SELECT MAX(timestamp) FROM messages WHERE messages.thread_id = threads.id),
                message_count = (SELECT COUNT(*) FROM messages WHERE messages.thread_id = threads.id),
                attachment_count = (
                    SELECT COUNT(DISTINCT ma.attachment_id)
                    FROM message_attachments ma
                    JOIN messages m ON m.id = ma.message_id
                    WHERE m.thread_id = threads.id
                ),
                has_attachments = CASE WHEN EXISTS (
                    SELECT 1
                    FROM message_attachments ma
                    JOIN messages m ON m.id = ma.message_id
                    WHERE m.thread_id = threads.id
                ) THEN 1 ELSE 0 END;
            """
        )

        try cleanupOrphanedParticipants(on: database)
    }

    private static func loadStoredMessageDuplicateCandidates(on database: SQLiteDatabase) throws -> [StoredMessageDuplicateCandidate] {
        let sql = """
        SELECT id, thread_id, sender_id, sender_display_name, is_outgoing, body_text, timestamp, service, metadata_json
        FROM messages
        ORDER BY timestamp ASC, id ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        let attachmentSignatures = try loadAttachmentSignaturesByMessage(on: database)
        var candidates: [StoredMessageDuplicateCandidate] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            candidates.append(
                StoredMessageDuplicateCandidate(
                    id: messageID,
                    threadID: database.columnText(statement, index: 1) ?? "",
                    senderID: database.columnText(statement, index: 2) ?? "",
                    senderDisplayName: database.columnText(statement, index: 3) ?? "",
                    isOutgoing: database.columnInt(statement, index: 4) == 1,
                    bodyText: database.columnText(statement, index: 5) ?? "",
                    timestamp: database.columnDouble(statement, index: 6) ?? 0,
                    service: database.columnText(statement, index: 7) ?? "",
                    metadataJSON: database.columnText(statement, index: 8),
                    attachmentSignature: attachmentSignatures[messageID] ?? ""
                )
            )
        }
        return candidates
    }

    private static func loadAttachmentSignaturesByMessage(on database: SQLiteDatabase) throws -> [String: String] {
        let sql = """
        SELECT ma.message_id, a.type, a.filename, COALESCE(a.local_path, a.url, '')
        FROM message_attachments ma
        JOIN attachments a ON a.id = ma.attachment_id
        ORDER BY ma.message_id ASC, ma.position ASC, a.id ASC;
        """

        let statement = try database.prepare(sql)
        defer { database.finalize(statement) }

        var partsByMessage: [String: [String]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let messageID = database.columnText(statement, index: 0) ?? ""
            let attachmentPart = [
                database.columnText(statement, index: 1) ?? "",
                database.columnText(statement, index: 2) ?? "",
                database.columnText(statement, index: 3) ?? ""
            ]
                .map(MessageDuplicateKeyHelpers.normalizedText)
                .joined(separator: ":")
            partsByMessage[messageID, default: []].append(attachmentPart)
        }

        return partsByMessage.mapValues { $0.joined(separator: "|") }
    }

    private func deduplicatedMessagesForDisplay(_ messages: [MessageRecord]) -> [MessageRecord] {
        var seenKeys = Set<String>()
        return messages.filter { message in
            let keys = MessageDisplayDuplicateKey.keys(for: message)
            guard keys.allSatisfy({ !seenKeys.contains($0) }) else { return false }
            seenKeys.formUnion(keys)
            return true
        }
    }

    private func makeStatistics(messages: [MessageRecord]) -> ConversationStatistics {
        let grouped = Dictionary(grouping: messages) { message -> String in
            let components = Calendar.current.dateComponents([.year, .month], from: message.timestamp)
            let year = components.year ?? 0
            let month = components.month ?? 0
            return String(format: "%04d-%02d", year, month)
        }
        let buckets = grouped.keys.sorted().map { key -> TimelineBucket in
            let components = key.split(separator: "-").compactMap { Int($0) }
            let label: String
            let startDate: Date
            if components.count == 2 {
                var dateComponents = DateComponents()
                dateComponents.year = components[0]
                dateComponents.month = components[1]
                dateComponents.day = 1
                if let date = Calendar.current.date(from: dateComponents) {
                    startDate = date
                    let formatter = DateFormatter()
                    formatter.dateFormat = "LLL yyyy"
                    label = formatter.string(from: date)
                } else {
                    startDate = grouped[key]?.first?.timestamp ?? messages.first?.timestamp ?? .distantPast
                    label = key
                }
            } else {
                startDate = grouped[key]?.first?.timestamp ?? messages.first?.timestamp ?? .distantPast
                label = key
            }
            return TimelineBucket(id: key, label: label, count: grouped[key]?.count ?? 0, startDate: startDate)
        }

        return ConversationStatistics(
            totalMessages: messages.count,
            outgoingMessages: messages.filter(\.isOutgoing).count,
            incomingMessages: messages.filter { !$0.isOutgoing }.count,
            attachmentMessages: messages.filter(\.hasAttachments).count,
            monthlyBuckets: buckets
        )
    }

    private enum MessageDisplayDuplicateKey {
        static func keys(for message: MessageRecord) -> [String] {
            var keys: [String] = []
            keys.append(contentsOf: MessageDuplicateKeyHelpers.sourceMessageIDs(from: message.metadataJSON).map { "source:\($0)" })

            let senderKey = message.isOutgoing
                ? "outgoing:me"
                : "incoming:\(MessageDuplicateKeyHelpers.normalizedText(message.senderDisplayName))"
            let attachmentKey = message.attachments
                .map { attachment in
                    [
                        attachment.type.rawValue,
                        MessageDuplicateKeyHelpers.normalizedText(attachment.filename),
                        MessageDuplicateKeyHelpers.normalizedText(attachment.localPath ?? attachment.url ?? "")
                    ].joined(separator: ":")
                }
                .joined(separator: "|")

            keys.append(MessageDuplicateKeyHelpers.exactMessageKey(
                scope: nil,
                senderKey: senderKey,
                isOutgoing: message.isOutgoing,
                timestamp: message.timestamp.timeIntervalSince1970,
                bodyText: message.bodyText,
                service: message.service.rawValue,
                attachmentSignature: attachmentKey
            ))
            return keys
        }
    }

    private enum ImportedMessageDuplicateKey {
        static func keys(for message: ImportedMessage, archiveID: String) -> [String] {
            var keys: [String] = []
            keys.append(contentsOf: MessageDuplicateKeyHelpers.sourceMessageIDs(from: message.metadataJSON).map { "source:\(archiveID):\($0)" })

            keys.append(MessageDuplicateKeyHelpers.exactMessageKey(
                scope: archiveID,
                senderKey: message.senderID,
                isOutgoing: message.isOutgoing,
                timestamp: message.timestamp.timeIntervalSince1970,
                bodyText: message.bodyText,
                service: message.service.rawValue,
                attachmentSignature: message.attachmentIDs.joined(separator: "|")
            ))
            return keys
        }
    }

    private struct StoredMessageDuplicateCandidate {
        let id: String
        let threadID: String
        let senderID: String
        let senderDisplayName: String
        let isOutgoing: Bool
        let bodyText: String
        let timestamp: Double
        let service: String
        let metadataJSON: String?
        let attachmentSignature: String
    }

    private enum StoredMessageDuplicateKey {
        static func keys(for candidate: StoredMessageDuplicateCandidate) -> [String] {
            var keys: [String] = []
            keys.append(contentsOf: MessageDuplicateKeyHelpers.sourceMessageIDs(from: candidate.metadataJSON).map { "source:\($0)" })

            keys.append(MessageDuplicateKeyHelpers.exactMessageKey(
                scope: candidate.threadID,
                senderKey: candidate.senderID,
                isOutgoing: candidate.isOutgoing,
                timestamp: candidate.timestamp,
                bodyText: candidate.bodyText,
                service: candidate.service,
                attachmentSignature: candidate.attachmentSignature
            ))
            return keys
        }
    }

    private enum SearchMessageDuplicateKey {
        static func keys(
            scope: String?,
            messageID: String,
            senderDisplayName: String,
            isOutgoing: Bool,
            timestamp: Double,
            bodyText: String,
            service: String,
            metadataJSON: String?
        ) -> [String] {
            var keys = ["message-id:\(messageID)"]
            keys.append(contentsOf: MessageDuplicateKeyHelpers.sourceMessageIDs(from: metadataJSON).map { "source:\($0)" })

            let senderKey = isOutgoing
                ? "outgoing:me"
                : "incoming:\(MessageDuplicateKeyHelpers.normalizedText(senderDisplayName))"
            keys.append(MessageDuplicateKeyHelpers.exactMessageKey(
                scope: scope,
                senderKey: senderKey,
                isOutgoing: isOutgoing,
                timestamp: timestamp,
                bodyText: bodyText,
                service: service,
                attachmentSignature: ""
            ))
            return keys
        }
    }

    private enum MessageDuplicateKeyHelpers {
        static func sourceMessageID(from metadataJSON: String?) -> String? {
            sourceMessageIDs(from: metadataJSON).first
        }

        static func sourceMessageIDs(from metadataJSON: String?) -> [String] {
            guard let metadataJSON else {
                return []
            }

            var ids: [String] = []

            func append(_ id: String) {
                guard !ids.contains(id) else { return }
                ids.append(id)
            }

            if let rowID = fastJSONIntValue(for: "messages_rowid", in: metadataJSON) {
                append("messages-rowid:\(rowID)")
            }

            if let guid = fastJSONStringValue(for: "messages_guid", in: metadataJSON)?.trimmed.nilIfBlank {
                append("messages-guid:\(guid.lowercased())")
            }

            guard let data = metadataJSON.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  !object.isEmpty
            else {
                return ids
            }

            if let rowID = object["messages_rowid"] {
                if let number = rowID as? NSNumber {
                    append("messages-rowid:\(number.intValue)")
                } else if let string = rowID as? String, let intValue = Int(string) {
                    append("messages-rowid:\(intValue)")
                }
            }

            if let guid = (object["messages_guid"] as? String)?.trimmed.nilIfBlank {
                append("messages-guid:\(guid.lowercased())")
            }

            return ids
        }

        private static func fastJSONStringValue(for key: String, in json: String) -> String? {
            let needle = "\"\(key)\""
            guard let keyRange = json.range(of: needle),
                  let colonRange = json[keyRange.upperBound...].range(of: ":")
            else {
                return nil
            }

            var cursor = colonRange.upperBound
            while cursor < json.endIndex, json[cursor].isWhitespace {
                cursor = json.index(after: cursor)
            }

            guard cursor < json.endIndex, json[cursor] == "\"" else {
                return nil
            }

            let valueStart = json.index(after: cursor)
            var valueEnd = valueStart
            var isEscaped = false
            while valueEnd < json.endIndex {
                let character = json[valueEnd]
                if character == "\"" && !isEscaped {
                    return String(json[valueStart..<valueEnd])
                }
                isEscaped = character == "\\" && !isEscaped
                if character != "\\" {
                    isEscaped = false
                }
                valueEnd = json.index(after: valueEnd)
            }
            return nil
        }

        private static func fastJSONIntValue(for key: String, in json: String) -> Int? {
            let needle = "\"\(key)\""
            guard let keyRange = json.range(of: needle),
                  let colonRange = json[keyRange.upperBound...].range(of: ":")
            else {
                return nil
            }

            var cursor = colonRange.upperBound
            while cursor < json.endIndex, json[cursor].isWhitespace {
                cursor = json.index(after: cursor)
            }

            let valueStart = cursor
            while cursor < json.endIndex, json[cursor].isNumber {
                cursor = json.index(after: cursor)
            }

            guard valueStart < cursor else {
                return nil
            }
            return Int(json[valueStart..<cursor])
        }

        static func normalizedText(_ value: String) -> String {
            value
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        }

        static func exactMessageKey(
            scope: String?,
            senderKey: String,
            isOutgoing: Bool,
            timestamp: Double,
            bodyText: String,
            service: String,
            attachmentSignature: String
        ) -> String {
            [
                "exact",
                scope ?? "any-thread",
                normalizedText(senderKey),
                isOutgoing ? "outgoing" : "incoming",
                timestampKey(timestamp),
                normalizedText(bodyText),
                service.lowercased(),
                attachmentSignature
            ].joined(separator: "\u{1F}")
        }

        static func timestampKey(_ timestamp: Double) -> String {
            String(Int64(timestamp.rounded(.down)))
        }
    }
}
