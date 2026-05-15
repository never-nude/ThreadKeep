import CoreGraphics
import Foundation
import PDFKit

enum MessagesPDFImportError: LocalizedError, Sendable {
    case invalidPDF
    case lockedPDF
    case unreadableText
    case noMessagesDetected

    var errorDescription: String? {
        switch self {
        case .invalidPDF:
            return "This file could not be opened as a PDF."
        case .lockedPDF:
            return "This PDF is locked and its text cannot be imported."
        case .unreadableText:
            return "This PDF does not appear to contain selectable text. Export the conversation as a standard searchable PDF from Messages on Mac."
        case .noMessagesDetected:
            return "ThreadKeep could not detect message content in this PDF. Try exporting the conversation again from Messages on Mac using Print > PDF."
        }
    }
}

struct PDFTranscriptLine: Hashable, Sendable {
    let text: String
    let pageIndex: Int
    let bounds: CGRect
    let pageSize: CGSize

    var alignment: PDFTranscriptAlignment {
        let pageWidth = max(pageSize.width, 1)
        let midRatio = bounds.midX / pageWidth
        let minRatio = bounds.minX / pageWidth

        if abs(midRatio - 0.5) < 0.12, bounds.width < pageWidth * 0.62 {
            return .center
        }

        if midRatio > 0.58 || minRatio > 0.42 {
            return .right
        }

        return .left
    }

    var isNearHeaderOrFooter: Bool {
        let visualTop = pageSize.height - bounds.maxY
        let bottomInset = bounds.minY
        return visualTop < pageSize.height * 0.10 || bottomInset < pageSize.height * 0.08
    }
}

enum PDFTranscriptAlignment: String, Hashable, Sendable {
    case left
    case center
    case right
}

struct PDFTranscriptBlock: Hashable, Sendable {
    let lines: [PDFTranscriptLine]

    var pageIndex: Int { lines.first?.pageIndex ?? 0 }
    var alignment: PDFTranscriptAlignment { lines.first?.alignment ?? .left }
    var text: String { lines.map(\.text).joined(separator: "\n").trimmed }
    var frame: CGRect {
        lines.reduce(into: CGRect.null) { partial, line in
            partial = partial.union(line.bounds)
        }
    }

    func gap(to next: PDFTranscriptBlock) -> CGFloat {
        guard pageIndex == next.pageIndex else { return .greatestFiniteMagnitude }
        return frame.minY - next.frame.maxY
    }
}

struct MessagesPDFImporter {
    func parse(data: Data, sourceFilename: String?) throws -> ImportedConversationArchive {
        guard let document = PDFDocument(data: data) else {
            throw MessagesPDFImportError.invalidPDF
        }

        if document.isLocked, !document.unlock(withPassword: "") {
            throw MessagesPDFImportError.lockedPDF
        }

        let lines = extractLines(from: document)
        guard !lines.isEmpty else {
            throw MessagesPDFImportError.unreadableText
        }

        let metadataTitle = (document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)?.trimmed
        let creationDate = document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date

        return try parseExtractedLines(
            lines,
            sourceFilename: sourceFilename,
            documentTitle: metadataTitle,
            fallbackDate: creationDate
        )
    }

    func parseExtractedLines(
        _ extractedLines: [PDFTranscriptLine],
        sourceFilename: String?,
        documentTitle: String?,
        fallbackDate: Date?
    ) throws -> ImportedConversationArchive {
        let filteredLines = removeRepeatedHeadersAndFooters(from: extractedLines)
        let blocks = groupBlocks(from: filteredLines)
        guard !blocks.isEmpty else {
            throw MessagesPDFImportError.noMessagesDetected
        }

        let inferredTitle = normalizedTitle(documentTitle)
            ?? inferTitle(from: blocks)
            ?? sourceFilename.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? "Imported Conversation"

        var warnings: [String] = [
            "Messages PDF imports reconstruct the thread from selectable PDF text. Attachments, reactions, and some exact transcript metadata may not survive print export."
        ]

        var drafts: [MessageDraft] = []
        var currentDay: Date?
        var pendingSender: [PDFTranscriptAlignment: String] = [:]
        var inferredTimestampCount = 0

        for index in blocks.indices {
            let block = blocks[index]

            if let day = parseDateHeader(block.text) {
                currentDay = day
                continue
            }

            if shouldIgnoreAsDocumentHeader(block, inferredTitle: inferredTitle, messagesSeen: drafts.isEmpty) {
                continue
            }

            if let sender = senderLabelCandidate(for: block),
               let nextBlock = blocks[safe: index + 1],
               nextBlock.alignment == block.alignment,
               nextBlock.alignment != .center,
               block.gap(to: nextBlock) < 22
            {
                pendingSender[block.alignment] = sender
                continue
            }

            if let timestamp = parseTimestamp(block.text, currentDay: currentDay),
               block.text.count <= 32,
               let previousDraft = drafts.last,
               previousDraft.alignment == block.alignment,
               previousDraft.pageIndex == block.pageIndex,
               blocks[safe: index - 1]?.gap(to: block) ?? .greatestFiniteMagnitude < 18
            {
                drafts[drafts.count - 1].timestamp = timestamp
                currentDay = Calendar.current.startOfDay(for: timestamp)
                continue
            }

            guard block.alignment != .center else {
                continue
            }

            var components = messageComponents(from: block, currentDay: currentDay)
            if components.bodyText.isEmpty {
                continue
            }

            if components.senderDisplayName == nil {
                components.senderDisplayName = pendingSender.removeValue(forKey: block.alignment)
            }

            if components.timestamp == nil {
                components.timestamp = synthesizedTimestamp(
                    currentDay: currentDay,
                    previousTimestamp: drafts.last?.timestamp,
                    fallbackDate: fallbackDate,
                    sequenceIndex: drafts.count
                )
                inferredTimestampCount += 1
            }

            if let timestamp = components.timestamp {
                currentDay = Calendar.current.startOfDay(for: timestamp)
            }

            drafts.append(
                MessageDraft(
                    senderDisplayName: components.senderDisplayName,
                    isOutgoing: block.alignment == .right,
                    bodyText: components.bodyText,
                    timestamp: components.timestamp,
                    alignment: block.alignment,
                    pageIndex: block.pageIndex
                )
            )
        }

        let compactDrafts = drafts.filter { !$0.bodyText.trimmed.isEmpty }
        guard !compactDrafts.isEmpty else {
            throw MessagesPDFImportError.noMessagesDetected
        }

        if inferredTimestampCount > 0 {
            warnings.append("ThreadKeep inferred timestamps for \(inferredTimestampCount) message(s) because the print export did not expose a readable timestamp on every bubble.")
        }

        let incomingFallbackName = fallbackIncomingParticipantName(
            inferredTitle: inferredTitle,
            drafts: compactDrafts
        )

        var participantsByID: [String: ImportedParticipant] = [:]
        var messages: [ImportedMessage] = []

        for (index, draft) in compactDrafts.enumerated() {
            let participant: ImportedParticipant
            if draft.isOutgoing {
                participant = ensureParticipant(
                    id: "you",
                    displayName: "You",
                    in: &participantsByID
                )
            } else {
                let displayName = draft.senderDisplayName?.trimmed.nilIfBlank ?? incomingFallbackName
                participant = ensureParticipant(
                    id: "participant-\(displayName.slugified)",
                    displayName: displayName,
                    in: &participantsByID
                )
            }

            messages.append(
                ImportedMessage(
                    id: "pdf-message-\(index + 1)",
                    senderID: participant.id,
                    senderDisplayName: participant.displayName,
                    isOutgoing: draft.isOutgoing,
                    bodyText: draft.bodyText,
                    timestamp: draft.timestamp ?? synthesizedTimestamp(
                        currentDay: currentDay,
                        previousTimestamp: messages.last?.timestamp,
                        fallbackDate: fallbackDate,
                        sequenceIndex: index
                    ),
                    service: .unknown,
                    attachmentIDs: [],
                    replyToMessageID: nil,
                    reactions: [],
                    metadataJSON: "{\"import_source\":\"messages_pdf\"}"
                )
            )
        }

        let archiveKey = messages.map {
            "\($0.timestamp.timeIntervalSince1970)|\($0.isOutgoing)|\($0.senderDisplayName)|\($0.bodyText)"
        }.joined(separator: "\n")
        let threadID = "messages-pdf-\(inferredTitle.slugified)-\(StableHash.fnv1a64Hex(archiveKey).prefix(12))"

        return ImportedConversationArchive(
            id: threadID,
            title: inferredTitle,
            participants: participantsByID.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            messages: messages.sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            },
            attachments: [],
            warnings: warnings,
            sourceFilename: sourceFilename
        )
    }

    private func extractLines(from document: PDFDocument) -> [PDFTranscriptLine] {
        if let selection = document.selectionForEntireDocument {
            let lines = selection.selectionsByLine().compactMap { selection -> PDFTranscriptLine? in
                guard let page = selection.pages.first else { return nil }
                let pageIndex = document.index(for: page)
                let pageBounds = page.bounds(for: .cropBox)
                let text = normalizeLine(selection.string ?? "")
                guard !text.isEmpty else { return nil }
                return PDFTranscriptLine(
                    text: text,
                    pageIndex: pageIndex,
                    bounds: selection.bounds(for: page),
                    pageSize: pageBounds.size
                )
            }

            if !lines.isEmpty {
                return lines
            }
        }

        var fallback: [PDFTranscriptLine] = []
        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex), let pageText = page.string else { continue }
            let pageBounds = page.bounds(for: .cropBox)
            let parts = pageText
                .components(separatedBy: .newlines)
                .map(normalizeLine(_:))
                .filter { !$0.isEmpty }

            var y = pageBounds.height - 40
            for part in parts {
                fallback.append(
                    PDFTranscriptLine(
                        text: part,
                        pageIndex: pageIndex,
                        bounds: CGRect(x: 72, y: y, width: pageBounds.width - 144, height: 14),
                        pageSize: pageBounds.size
                    )
                )
                y -= 18
            }
        }
        return fallback
    }

    private func normalizeLine(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmed
    }

    private func removeRepeatedHeadersAndFooters(from lines: [PDFTranscriptLine]) -> [PDFTranscriptLine] {
        let repeated = Dictionary(grouping: lines, by: \.text)
            .filter { text, entries in
                let pageCount = Set(entries.map(\.pageIndex)).count
                guard pageCount >= 2 else { return false }
                guard !isLikelyDateOrTime(text) else { return false }
                return entries.allSatisfy(\.isNearHeaderOrFooter)
            }
            .map(\.key)

        return lines.filter { line in
            !repeated.contains(line.text) && !isIgnoredNoiseLine(line.text)
        }
    }

    private func isIgnoredNoiseLine(_ text: String) -> Bool {
        let trimmed = text.trimmed
        if trimmed.isEmpty {
            return true
        }

        let patterns = [
            #"^Page \d+ of \d+$"#,
            #"^\d+$"#,
            #"^Messages$"#,
            #"^Conversation$"#,
            #"^Printed from"#,
            #"^Saved from"#,
            #"^From: "#,
            #"^To: "#
        ]

        return patterns.contains { pattern in
            trimmed.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private func groupBlocks(from lines: [PDFTranscriptLine]) -> [PDFTranscriptBlock] {
        let sorted = lines.sorted { lhs, rhs in
            if lhs.pageIndex != rhs.pageIndex {
                return lhs.pageIndex < rhs.pageIndex
            }
            if abs(lhs.bounds.maxY - rhs.bounds.maxY) > 0.5 {
                return lhs.bounds.maxY > rhs.bounds.maxY
            }
            return lhs.bounds.minX < rhs.bounds.minX
        }

        var blocks: [PDFTranscriptBlock] = []
        var current: [PDFTranscriptLine] = []

        for line in sorted {
            if let last = current.last, shouldAppend(line, to: last) {
                current.append(line)
            } else {
                if !current.isEmpty {
                    blocks.append(PDFTranscriptBlock(lines: current))
                }
                current = [line]
            }
        }

        if !current.isEmpty {
            blocks.append(PDFTranscriptBlock(lines: current))
        }

        return blocks
    }

    private func shouldAppend(_ candidate: PDFTranscriptLine, to previous: PDFTranscriptLine) -> Bool {
        guard candidate.pageIndex == previous.pageIndex else { return false }
        guard candidate.alignment == previous.alignment else { return false }

        let verticalGap = previous.bounds.minY - candidate.bounds.maxY
        let horizontalDrift = abs(previous.bounds.minX - candidate.bounds.minX)

        switch candidate.alignment {
        case .center:
            return verticalGap < 14 && horizontalDrift < 80
        case .left, .right:
            return verticalGap < 22 && horizontalDrift < 40
        }
    }

    private func inferTitle(from blocks: [PDFTranscriptBlock]) -> String? {
        let candidates = blocks.filter {
            $0.pageIndex == 0 &&
            $0.alignment == .center &&
            !isLikelyDateOrTime($0.text) &&
            !isIgnoredNoiseLine($0.text) &&
            $0.text.count <= 80
        }

        return candidates
            .sorted { $0.frame.maxY > $1.frame.maxY }
            .compactMap { normalizedTitle($0.text) }
            .first
    }

    private func normalizedTitle(_ candidate: String?) -> String? {
        guard let candidate = candidate?.trimmed.nilIfBlank else { return nil }
        let generic = ["messages", "conversation", "untitled", "chat"]
        guard !generic.contains(candidate.lowercased()) else { return nil }
        return candidate
    }

    private func shouldIgnoreAsDocumentHeader(
        _ block: PDFTranscriptBlock,
        inferredTitle: String,
        messagesSeen: Bool
    ) -> Bool {
        guard !messagesSeen, block.pageIndex == 0 else { return false }
        guard block.alignment == .center else { return false }

        if block.text.caseInsensitiveCompare(inferredTitle) == .orderedSame {
            return true
        }

        return isIgnoredNoiseLine(block.text)
    }

    private func senderLabelCandidate(for block: PDFTranscriptBlock) -> String? {
        let text = block.text.replacingOccurrences(of: ":", with: "").trimmed
        guard block.alignment != .center else { return nil }
        guard text.count <= 40 else { return nil }
        guard !isLikelyDateOrTime(text) else { return nil }
        guard !text.contains("http") else { return nil }

        if text.range(of: #"^[\p{L}\p{N}][\p{L}\p{N} .,'’\-]{0,38}$"#, options: .regularExpression) != nil {
            return text
        }

        return nil
    }

    private func messageComponents(from block: PDFTranscriptBlock, currentDay: Date?) -> MessageComponents {
        var lines = block.lines.map(\.text)
        var senderDisplayName: String?
        var timestamp: Date?

        if let first = lines.first,
           let inline = inlineSenderAndBody(from: first)
        {
            senderDisplayName = inline.sender
            lines[0] = inline.body
        }

        if let last = lines.last,
           let parsedTimestamp = parseTimestamp(last, currentDay: currentDay),
           (lines.count > 1 || last.count <= 32)
        {
            timestamp = parsedTimestamp
            lines.removeLast()
        }

        var bodyText = lines.joined(separator: " ").trimmed
        if timestamp == nil, let trailing = trailingTimeSplit(bodyText), let parsedTimestamp = parseTimestamp(trailing.timestampText, currentDay: currentDay) {
            timestamp = parsedTimestamp
            bodyText = trailing.bodyText.trimmed
        }

        if senderDisplayName == nil,
           let first = lines.first,
           let senderOnly = senderLabelCandidate(for: PDFTranscriptBlock(lines: [PDFTranscriptLine(text: first, pageIndex: block.pageIndex, bounds: block.lines.first?.bounds ?? .zero, pageSize: block.lines.first?.pageSize ?? .zero)])),
           lines.count > 1
        {
            senderDisplayName = senderOnly
            bodyText = lines.dropFirst().joined(separator: " ").trimmed
        }

        return MessageComponents(
            senderDisplayName: senderDisplayName,
            bodyText: bodyText,
            timestamp: timestamp
        )
    }

    private func inlineSenderAndBody(from line: String) -> (sender: String, body: String)? {
        guard let match = line.range(
            of: #"^([\p{L}\p{N}][\p{L}\p{N} .,'’\-]{0,38}):\s+(.+)$"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let text = String(line[match])
        let parts = text.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0].trimmed, parts[1].trimmed)
    }

    private func trailingTimeSplit(_ text: String) -> (bodyText: String, timestampText: String)? {
        let patterns = [
            #"^(.*?)(\b\d{1,2}:\d{2}(?::\d{2})?\s?[APMapm]{2}\b)$"#,
            #"^(.*?)(\b[A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4},\s+\d{1,2}:\d{2}\s?[APMapm]{2}\b)$"#
        ]

        for pattern in patterns {
            guard let range = text.range(of: pattern, options: .regularExpression) else { continue }
            let matched = String(text[range])
            if let splitIndex = matched.lastIndex(of: " ") {
                let head = String(matched[..<splitIndex]).trimmed
                let tail = String(matched[matched.index(after: splitIndex)...]).trimmed
                if !head.isEmpty, !tail.isEmpty {
                    return (head, tail)
                }
            }
        }

        return nil
    }

    private func parseDateHeader(_ text: String) -> Date? {
        parseWithFormats(
            text,
            formats: [
                "EEEE, MMMM d, yyyy",
                "EEEE, MMM d, yyyy",
                "MMMM d, yyyy",
                "MMM d, yyyy",
                "M/d/yy",
                "M/d/yyyy"
            ]
        )
        .map { Calendar.current.startOfDay(for: $0) }
    }

    private func parseTimestamp(_ text: String, currentDay: Date?) -> Date? {
        let cleaned = text
            .replacingOccurrences(of: "Delivered", with: "")
            .replacingOccurrences(of: "Read", with: "")
            .replacingOccurrences(of: "Edited", with: "")
            .replacingOccurrences(of: "Sent as Text Message", with: "")
            .trimmed

        if let fullDate = parseWithFormats(
            cleaned,
            formats: [
                "EEEE, MMMM d, yyyy 'at' h:mm a",
                "EEEE, MMMM d, yyyy, h:mm a",
                "EEEE, MMM d, yyyy, h:mm a",
                "MMMM d, yyyy 'at' h:mm a",
                "MMMM d, yyyy, h:mm a",
                "MMM d, yyyy, h:mm a",
                "M/d/yy, h:mm a",
                "M/d/yyyy, h:mm a"
            ]
        ) {
            return fullDate
        }

        guard let currentDay else { return nil }
        if let timeOnly = parseWithFormats(cleaned, formats: ["h:mm a", "h:mm:ss a"]) {
            let time = Calendar.current.dateComponents([.hour, .minute, .second], from: timeOnly)
            return Calendar.current.date(bySettingHour: time.hour ?? 12, minute: time.minute ?? 0, second: time.second ?? 0, of: currentDay)
        }

        return nil
    }

    private func parseWithFormats(_ text: String, formats: [String]) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                return date
            }
        }

        return nil
    }

    private func isLikelyDateOrTime(_ text: String) -> Bool {
        parseDateHeader(text) != nil || parseTimestamp(text, currentDay: Date()) != nil
    }

    private func synthesizedTimestamp(
        currentDay: Date?,
        previousTimestamp: Date?,
        fallbackDate: Date?,
        sequenceIndex: Int
    ) -> Date {
        if let previousTimestamp {
            return previousTimestamp.addingTimeInterval(60)
        }

        let baseDay = currentDay
            ?? fallbackDate.map { Calendar.current.startOfDay(for: $0) }
            ?? Calendar.current.startOfDay(for: Date())

        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: baseDay) ?? baseDay
        return noon.addingTimeInterval(TimeInterval(sequenceIndex * 60))
    }

    private func fallbackIncomingParticipantName(
        inferredTitle: String,
        drafts: [MessageDraft]
    ) -> String {
        let incomingNames = drafts.compactMap(\.senderDisplayName?.trimmed.nilIfBlank)
        if let singleName = Set(incomingNames).onlyElement {
            return singleName
        }
        return inferredTitle
    }

    private func ensureParticipant(
        id: String,
        displayName: String,
        in participants: inout [String: ImportedParticipant]
    ) -> ImportedParticipant {
        if let existing = participants[id] {
            return existing
        }

        let participant = ImportedParticipant(id: id, displayName: displayName)
        participants[id] = participant
        return participant
    }
}

private struct MessageComponents {
    var senderDisplayName: String?
    var bodyText: String
    var timestamp: Date?
}

private struct MessageDraft {
    var senderDisplayName: String?
    let isOutgoing: Bool
    let bodyText: String
    var timestamp: Date?
    let alignment: PDFTranscriptAlignment
    let pageIndex: Int
}

private extension Set {
    var onlyElement: Element? {
        count == 1 ? first : nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
