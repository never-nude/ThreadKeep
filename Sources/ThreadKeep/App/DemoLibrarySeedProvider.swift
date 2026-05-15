import Foundation

struct DemoLibrarySeedResult: Sendable, Equatable {
    let threadCount: Int
    let messageCount: Int
}

struct DemoLibrarySeedProvider: Sendable {
    enum SeedError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "ThreadKeep couldn’t find the bundled demo Messages data named `\(name)`."
            }
        }
    }

    static let mark = DemoLibrarySeedProvider(resourceName: "MarkDemo/chat_data")

    let resourceName: String

    func messagesFolderURL() throws -> URL {
        try bundledMessagesFolderURL()
    }

    func seedLibrary(into store: ArchiveStore) async throws -> DemoLibrarySeedResult {
        let messagesFolderURL = try bundledMessagesFolderURL()
        let importer = MessagesStoreImporter()
        let candidates = try importer.loadChatCandidates(from: messagesFolderURL, useContacts: false)

        var importedThreadCount = 0
        var importedMessageCount = 0

        for candidate in candidates {
            var payload = try importer.importChat(id: candidate.id, from: messagesFolderURL, useContacts: false)
            payload = try payload.preparingDemoArchive(resourceFolderURL: messagesFolderURL)
            try await store.importArchive(payload)
            importedThreadCount += 1
            importedMessageCount += payload.archive.messageCount
        }

        return DemoLibrarySeedResult(threadCount: importedThreadCount, messageCount: importedMessageCount)
    }

    private func bundledMessagesFolderURL() throws -> URL {
        let components = resourceName.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            throw SeedError.missingResource(resourceName)
        }

        let resource = components.last!
        let subdirectory = components.dropLast().joined(separator: "/").nilIfBlank

        if let url = Bundle.module.url(forResource: resource, withExtension: nil, subdirectory: subdirectory) {
            return url
        }

        if let databaseURL = Bundle.module.url(forResource: "chat", withExtension: "db") {
            return databaseURL.deletingLastPathComponent()
        }

        throw SeedError.missingResource(resourceName)
    }
}

extension ParsedArchivePayload {
    func preparingDemoArchive(resourceFolderURL: URL) throws -> ParsedArchivePayload {
        let title = archive.title.trimmed
        let resolvedTitle = title.nilIfBlank
        let otherParticipants = archive.participants.filter { !Self.isYou($0.displayName) }
        let oneToOneParticipantID = otherParticipants.count == 1 ? otherParticipants.first?.id : nil

        let updatedParticipants = archive.participants.map { participant in
            if participant.id == oneToOneParticipantID, let resolvedTitle {
                return ImportedParticipant(id: participant.id, displayName: resolvedTitle)
            }
            return participant
        }

        let updatedMessages = archive.messages.map { message in
            guard message.senderID == oneToOneParticipantID,
                  let resolvedTitle
            else {
                return message
            }
            return ImportedMessage(
                id: message.id,
                senderID: message.senderID,
                senderDisplayName: resolvedTitle,
                isOutgoing: message.isOutgoing,
                bodyText: message.bodyText,
                timestamp: message.timestamp,
                service: message.service,
                attachmentIDs: message.attachmentIDs,
                replyToMessageID: message.replyToMessageID,
                reactions: message.reactions,
                metadataJSON: message.metadataJSON
            )
        }

        let updatedAttachments = archive.attachments.map { attachment in
            guard let bundledPath = bundledAttachmentPath(for: attachment, resourceFolderURL: resourceFolderURL) else {
                return attachment
            }

            return ImportedAttachment(
                id: attachment.id,
                type: attachment.type,
                filename: attachment.filename,
                localPath: bundledPath,
                mimeType: attachment.mimeType,
                thumbnail: attachment.thumbnail,
                url: attachment.url
            )
        }

        let updatedArchive = ImportedConversationArchive(
            id: archive.id,
            title: archive.title,
            participants: updatedParticipants,
            messages: updatedMessages,
            attachments: updatedAttachments,
            warnings: archive.warnings,
            sourceFilename: archive.sourceFilename
        )

        return try ParsedArchivePayload.snapshot(archive: updatedArchive, sourceKind: sourceKind)
    }

    private static func isYou(_ value: String) -> Bool {
        value.trimmed.localizedCaseInsensitiveCompare("You") == .orderedSame
    }

    private func bundledAttachmentPath(for attachment: ImportedAttachment, resourceFolderURL: URL) -> String? {
        let filename = attachment.localPath
            .flatMap { URL(fileURLWithPath: $0).lastPathComponent.nilIfBlank }
            ?? attachment.filename.trimmed.nilIfBlank

        guard let filename else {
            return nil
        }

        let candidateURLs = [
            resourceFolderURL.appendingPathComponent(filename),
            resourceFolderURL.appendingPathComponent("Attachments").appendingPathComponent(filename),
            resourceFolderURL.appendingPathComponent("Attachments").appendingPathComponent("IM").appendingPathComponent(filename)
        ]

        if let match = candidateURLs.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            return match.path
        }

        return Bundle.module.url(forResource: filename, withExtension: nil)?.path
    }
}
