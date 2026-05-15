import CryptoKit
import Foundation
import UniformTypeIdentifiers

struct ThreadJSONNameResolution {
    let threadTitle: String
    let participantNamesByID: [String: String]
    let senderNamesByID: [String: String]

    func participantName(for participant: ParticipantRecord) -> String {
        participantNamesByID[participant.id] ?? participant.displayName
    }

    func senderName(for message: MessageRecord) -> String {
        if message.isOutgoing {
            return "Me"
        }
        return senderNamesByID[message.senderID] ?? message.senderDisplayName
    }
}

struct ThreadJSONExportResult: Sendable, Equatable {
    let folderURL: URL
    let jsonURL: URL
}

struct ThreadJSONExporter {
    private let fileManager: FileManager
    private let appVersion: String

    init(
        fileManager: FileManager = .default,
        appVersion: String = ThreadJSONExportAppVersion.current
    ) {
        self.fileManager = fileManager
        self.appVersion = appVersion
    }

    func suggestedFolderName(for thread: ThreadDetail) -> String {
        "\(thread.title.slugified)-json"
    }

    func export(
        thread: ThreadDetail,
        to parentDirectoryURL: URL,
        includeAttachments: Bool,
        nameResolution: ThreadJSONNameResolution,
        exportedAt: Date = Date()
    ) throws -> ThreadJSONExportResult {
        let folderURL = uniqueDirectoryURL(
            named: suggestedFolderName(for: thread),
            in: parentDirectoryURL
        )
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let attachmentsDirectoryURL = folderURL.appendingPathComponent("attachments", isDirectory: true)
        if includeAttachments, thread.allAttachments.contains(where: { localFileURL(for: $0.localPath) != nil }) {
            try fileManager.createDirectory(at: attachmentsDirectoryURL, withIntermediateDirectories: true)
        }

        var attachmentExportPaths: [String: String] = [:]
        var usedAttachmentFilenames = Set<String>()

        let messages = thread.messages.map { message in
            ThreadJSONV1.Message(
                message: message,
                senderDisplayName: nameResolution.senderName(for: message),
                senderHandle: sourceHandle(from: message.metadataJSON),
                attachments: message.attachments.map { attachment in
                    ThreadJSONV1.Attachment(
                        attachment: attachment,
                        relativePath: relativeAttachmentPath(
                            for: attachment,
                            includeAttachments: includeAttachments,
                            attachmentsDirectoryURL: attachmentsDirectoryURL,
                            exportedPaths: &attachmentExportPaths,
                            usedFilenames: &usedAttachmentFilenames
                        )
                    )
                }
            )
        }

        let payload = ThreadJSONV1(
            threadkeepVersion: appVersion,
            exportedAt: exportedAt,
            source: ThreadJSONV1.Source(
                chatDBSHA256: nil,
                sourceArchiveSHA256: checksumIfAvailable(at: thread.rawArchivePath),
                importedAt: thread.importedAt
            ),
            thread: ThreadJSONV1.Thread(
                detail: thread,
                displayName: nameResolution.threadTitle,
                participants: thread.participants.map { participant in
                    ThreadJSONV1.Participant(
                        participant: participant,
                        displayName: nameResolution.participantName(for: participant),
                        handles: participantHandles(for: participant, in: thread.messages)
                    )
                }
            ),
            messages: messages
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        let jsonURL = folderURL.appendingPathComponent("\(thread.title.slugified).json", isDirectory: false)
        try data.write(to: jsonURL, options: [.atomic])

        return ThreadJSONExportResult(folderURL: folderURL, jsonURL: jsonURL)
    }

    private func relativeAttachmentPath(
        for attachment: AttachmentRecord,
        includeAttachments: Bool,
        attachmentsDirectoryURL: URL,
        exportedPaths: inout [String: String],
        usedFilenames: inout Set<String>
    ) -> String? {
        guard includeAttachments,
              let sourceURL = localFileURL(for: attachment.localPath),
              fileManager.fileExists(atPath: sourceURL.path)
        else {
            return nil
        }

        if let existing = exportedPaths[attachment.id] {
            return existing
        }

        let filename = uniqueAttachmentFilename(
            preferredName: attachment.filename,
            fallbackID: attachment.id,
            usedFilenames: &usedFilenames
        )
        let destinationURL = attachmentsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            let relativePath = "attachments/\(filename)"
            exportedPaths[attachment.id] = relativePath
            return relativePath
        } catch {
            return nil
        }
    }

    private func uniqueAttachmentFilename(
        preferredName: String,
        fallbackID: String,
        usedFilenames: inout Set<String>
    ) -> String {
        let baseName = URL(fileURLWithPath: preferredName).lastPathComponent.nilIfBlank
            ?? "attachment-\(fallbackID.slugified)"
        let url = URL(fileURLWithPath: baseName)
        let stem = url.deletingPathExtension().lastPathComponent.nilIfBlank ?? "attachment"
        let ext = url.pathExtension

        var candidate = baseName
        var counter = 2
        while usedFilenames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            counter += 1
        }
        usedFilenames.insert(candidate.lowercased())
        return candidate
    }

    private func uniqueDirectoryURL(named name: String, in parentDirectoryURL: URL) -> URL {
        let safeName = name.nilIfBlank ?? "threadkeep-json-export"
        var candidate = parentDirectoryURL.appendingPathComponent(safeName, isDirectory: true)
        var counter = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parentDirectoryURL.appendingPathComponent("\(safeName)-\(counter)", isDirectory: true)
            counter += 1
        }
        return candidate
    }

    private func participantHandles(for participant: ParticipantRecord, in messages: [MessageRecord]) -> [String] {
        var handles: [String] = []
        var seen = Set<String>()

        func append(_ handle: String?) {
            guard let handle = handle?.trimmed.nilIfBlank else { return }
            let key = canonicalHandleKey(handle)
            guard seen.insert(key).inserted else { return }
            handles.append(handle)
        }

        if participant.displayName.contains("@") || participant.displayName.filter(\.isNumber).count >= 7 {
            append(participant.displayName)
        }

        for message in messages where message.senderID == participant.id {
            append(sourceHandle(from: message.metadataJSON))
        }

        return handles
    }

    private func sourceHandle(from metadataJSON: String?) -> String? {
        guard let metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handle = object["sender_handle"] as? String
        else {
            return nil
        }
        return handle.trimmed.nilIfBlank
    }

    private func checksumIfAvailable(at path: String?) -> String? {
        guard let url = localFileURL(for: path),
              fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func localFileURL(for path: String?) -> URL? {
        guard let path = path?.trimmed.nilIfBlank else { return nil }
        if path.hasPrefix("file://") {
            return URL(string: path)
        }
        return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
    }

    private func canonicalHandleKey(_ value: String) -> String {
        let trimmed = value.trimmed.lowercased()
        if trimmed.contains("@") {
            return trimmed
        }

        let digits = trimmed.filter(\.isNumber)
        if digits.count == 11, digits.hasPrefix("1") {
            return String(digits.dropFirst())
        }
        return digits.nilIfBlank ?? trimmed
    }
}

extension UTType {
    static let threadkeepJSONExport = UTType(filenameExtension: "json") ?? .json
}

private enum ThreadJSONExportAppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

private struct ThreadJSONV1: Encodable {
    let threadkeepVersion: String
    let schemaVersion = 1
    let exportedAt: String
    let source: Source
    let thread: Thread
    let messages: [Message]

    init(
        threadkeepVersion: String,
        exportedAt: Date,
        source: Source,
        thread: Thread,
        messages: [Message]
    ) {
        self.threadkeepVersion = threadkeepVersion
        self.exportedAt = ThreadJSONTimestampFormatter.string(from: exportedAt)
        self.source = source
        self.thread = thread
        self.messages = messages
    }

    enum CodingKeys: String, CodingKey {
        case threadkeepVersion = "threadkeep_version"
        case schemaVersion = "schema_version"
        case exportedAt = "exported_at"
        case source
        case thread
        case messages
    }

    struct Source: Encodable {
        let chatDBSHA256: String?
        let sourceArchiveSHA256: String?
        let importedAt: String

        init(chatDBSHA256: String?, sourceArchiveSHA256: String?, importedAt: Date) {
            self.chatDBSHA256 = chatDBSHA256
            self.sourceArchiveSHA256 = sourceArchiveSHA256
            self.importedAt = ThreadJSONTimestampFormatter.string(from: importedAt)
        }

        enum CodingKeys: String, CodingKey {
            case chatDBSHA256 = "chat_db_sha256"
            case sourceArchiveSHA256 = "source_archive_sha256"
            case importedAt = "imported_at"
        }
    }

    struct Thread: Encodable {
        let id: String
        let type: String
        let displayName: String
        let participants: [Participant]
        let firstMessageAt: String?
        let lastMessageAt: String?
        let messageCount: Int

        init(detail: ThreadDetail, displayName: String, participants: [Participant]) {
            id = detail.id
            type = participants.filter { !$0.isMe }.count <= 1 ? "direct" : "group"
            self.displayName = displayName
            self.participants = participants
            firstMessageAt = detail.startDate.map(ThreadJSONTimestampFormatter.string(from:))
            lastMessageAt = detail.endDate.map(ThreadJSONTimestampFormatter.string(from:))
            messageCount = detail.messages.count
        }

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case displayName = "display_name"
            case participants
            case firstMessageAt = "first_message_at"
            case lastMessageAt = "last_message_at"
            case messageCount = "message_count"
        }
    }

    struct Participant: Encodable {
        let displayName: String
        let handles: [String]
        let isMe: Bool

        init(participant: ParticipantRecord, displayName: String, handles: [String]) {
            self.displayName = participant.displayName.localizedCaseInsensitiveCompare("You") == .orderedSame ? "Me" : displayName
            self.handles = handles
            isMe = participant.displayName.localizedCaseInsensitiveCompare("You") == .orderedSame || participant.id == "you"
        }

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case handles
            case isMe = "is_me"
        }
    }

    struct Message: Encodable {
        let id: String
        let sender: Sender
        let timestamp: String
        let service: String
        let body: String
        let attachments: [Attachment]
        let reactions: [Reaction]
        let replyToMessageID: String?
        let edited: Bool

        init(
            message: MessageRecord,
            senderDisplayName: String,
            senderHandle: String?,
            attachments: [Attachment]
        ) {
            id = message.id
            sender = Sender(
                displayName: message.isOutgoing ? "Me" : senderDisplayName,
                handle: senderHandle,
                isMe: message.isOutgoing
            )
            timestamp = ThreadJSONTimestampFormatter.string(from: message.timestamp)
            service = message.service.displayName
            body = message.bodyText.replacingOccurrences(of: "\u{FFFC}", with: "")
            self.attachments = attachments
            reactions = message.reactions.map(Reaction.init(reaction:))
            replyToMessageID = message.replyToMessageID
            edited = false
        }

        enum CodingKeys: String, CodingKey {
            case id
            case sender
            case timestamp
            case service
            case body
            case attachments
            case reactions
            case replyToMessageID = "reply_to_message_id"
            case edited
        }
    }

    struct Sender: Encodable {
        let displayName: String
        let handle: String?
        let isMe: Bool

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
            case handle
            case isMe = "is_me"
        }
    }

    struct Attachment: Encodable {
        let filename: String
        let uti: String?
        let sizeBytes: Int?
        let checksumSHA256: String?
        let relativePath: String?

        init(attachment: AttachmentRecord, relativePath: String?) {
            filename = attachment.filename
            uti = attachment.mimeType ?? attachment.type.rawValue
            sizeBytes = Self.sizeBytes(for: attachment.localPath)
            checksumSHA256 = Self.checksum(for: attachment.localPath)
            self.relativePath = relativePath
        }

        enum CodingKeys: String, CodingKey {
            case filename
            case uti
            case sizeBytes = "size_bytes"
            case checksumSHA256 = "checksum_sha256"
            case relativePath = "relative_path"
        }

        private static func sizeBytes(for path: String?) -> Int? {
            guard let url = fileURL(for: path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber
            else {
                return nil
            }
            return size.intValue
        }

        private static func checksum(for path: String?) -> String? {
            guard let url = fileURL(for: path),
                  let data = try? Data(contentsOf: url)
            else {
                return nil
            }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func fileURL(for path: String?) -> URL? {
            guard let path = path?.trimmed.nilIfBlank else { return nil }
            if path.hasPrefix("file://") {
                return URL(string: path)
            }
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
    }

    struct Reaction: Encodable {
        let kind: String
        let from: Sender
        let timestamp: String?

        init(reaction: MessageReactionRecord) {
            kind = reaction.type?.nilIfBlank ?? reaction.emoji
            from = Sender(
                displayName: reaction.senderDisplayName?.nilIfBlank ?? "Unknown",
                handle: nil,
                isMe: reaction.senderDisplayName?.localizedCaseInsensitiveCompare("You") == .orderedSame
            )
            timestamp = nil
        }
    }
}

private enum ThreadJSONTimestampFormatter {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
