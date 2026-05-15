import Foundation

struct ArchiveValidationError: LocalizedError, Sendable {
    let issues: [String]

    var errorDescription: String? {
        issues.joined(separator: "\n")
    }
}

struct ArchiveValidator {
    static func validate(_ dto: ConversationArchiveDTO, sourceFilename: String?) throws -> ImportedConversationArchive {
        var issues: [String] = []
        var warnings: [String] = []

        let threadID = dto.threadID.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = dto.threadTitle.trimmingCharacters(in: .whitespacesAndNewlines)

        if threadID.isEmpty {
            issues.append("`thread_id` must be a non-empty string.")
        }

        if title.isEmpty {
            issues.append("`thread_title` must be a non-empty string.")
        }

        if dto.participants.isEmpty {
            issues.append("`participants` must contain at least one participant.")
        }

        if dto.messages.isEmpty {
            issues.append("`messages` must contain at least one message.")
        }

        let normalizedParticipants = normalizeParticipants(dto.participants, issues: &issues)
        let participantLookup = Dictionary(uniqueKeysWithValues: normalizedParticipants.map { ($0.id, $0) })
        let normalizedAttachments = normalizeAttachments(dto.attachments, issues: &issues)
        let attachmentLookup = Dictionary(uniqueKeysWithValues: normalizedAttachments.map { ($0.id, $0) })
        let normalizedMessages = normalizeMessages(
            dto.messages,
            participantLookup: participantLookup,
            attachmentLookup: attachmentLookup,
            issues: &issues,
            warnings: &warnings
        )

        let messageIDs = Set(normalizedMessages.map(\.id))
        for message in normalizedMessages {
            if let replyToMessageID = message.replyToMessageID, !messageIDs.contains(replyToMessageID) {
                issues.append("Message `\(message.id)` references missing `reply_to_message_id` `\(replyToMessageID)`.")
            }
        }

        if !issues.isEmpty {
            throw ArchiveValidationError(issues: issues)
        }

        return ImportedConversationArchive(
            id: threadID,
            title: title,
            participants: normalizedParticipants.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending },
            messages: normalizedMessages.sorted { lhs, rhs in
                if lhs.timestamp == rhs.timestamp {
                    return lhs.id < rhs.id
                }
                return lhs.timestamp < rhs.timestamp
            },
            attachments: normalizedAttachments.sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending },
            warnings: warnings,
            sourceFilename: sourceFilename
        )
    }

    private static func normalizeParticipants(
        _ participants: [ArchiveParticipantDTO],
        issues: inout [String]
    ) -> [ImportedParticipant] {
        var seen = Set<String>()
        var normalized: [ImportedParticipant] = []

        for participant in participants {
            let id = participant.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = participant.displayName.trimmingCharacters(in: .whitespacesAndNewlines)

            if id.isEmpty {
                issues.append("Participant entries must include a non-empty `id`.")
                continue
            }

            if displayName.isEmpty {
                issues.append("Participant `\(id)` must include a non-empty `display_name`.")
                continue
            }

            if seen.contains(id) {
                issues.append("Duplicate participant id `\(id)` found in `participants`.")
                continue
            }

            seen.insert(id)
            normalized.append(ImportedParticipant(id: id, displayName: displayName))
        }

        return normalized
    }

    private static func normalizeAttachments(
        _ attachments: [ArchiveAttachmentDTO],
        issues: inout [String]
    ) -> [ImportedAttachment] {
        var seen = Set<String>()
        var normalized: [ImportedAttachment] = []

        for attachment in attachments {
            let id = attachment.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let filename = attachment.filename.trimmingCharacters(in: .whitespacesAndNewlines)

            if id.isEmpty {
                issues.append("Attachment entries must include a non-empty `id`.")
                continue
            }

            if filename.isEmpty {
                issues.append("Attachment `\(id)` must include a non-empty `filename`.")
                continue
            }

            if seen.contains(id) {
                issues.append("Duplicate attachment id `\(id)` found in `attachments`.")
                continue
            }

            seen.insert(id)
            normalized.append(
                ImportedAttachment(
                    id: id,
                    type: AttachmentKind(rawArchiveValue: attachment.type),
                    filename: filename,
                    localPath: attachment.localPath?.nilIfBlank,
                    mimeType: attachment.mimeType?.nilIfBlank,
                    thumbnail: attachment.thumbnail?.nilIfBlank,
                    url: attachment.url?.nilIfBlank
                )
            )
        }

        return normalized
    }

    private static func normalizeMessages(
        _ messages: [ArchiveMessageDTO],
        participantLookup: [String: ImportedParticipant],
        attachmentLookup: [String: ImportedAttachment],
        issues: inout [String],
        warnings: inout [String]
    ) -> [ImportedMessage] {
        let timestampParser = ArchiveTimestampParser()
        var seen = Set<String>()
        var normalized: [ImportedMessage] = []

        for message in messages {
            let id = message.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let senderID = message.senderID.trimmingCharacters(in: .whitespacesAndNewlines)

            if id.isEmpty {
                issues.append("Message entries must include a non-empty `id`.")
                continue
            }

            if seen.contains(id) {
                issues.append("Duplicate message id `\(id)` found in `messages`.")
                continue
            }
            seen.insert(id)

            if senderID.isEmpty {
                issues.append("Message `\(id)` must include a non-empty `sender_id`.")
                continue
            }

            guard let participant = participantLookup[senderID] else {
                issues.append("Message `\(id)` references unknown `sender_id` `\(senderID)`.")
                continue
            }

            let bodyText = message.bodyText
            if bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachmentIDs.isEmpty {
                issues.append("Message `\(id)` must include `body_text` or at least one attachment.")
                continue
            }

            guard let timestamp = timestampParser.parse(message.timestamp) else {
                issues.append("Message `\(id)` has invalid `timestamp` `\(message.timestamp)`. Use ISO 8601.")
                continue
            }

            for attachmentID in message.attachmentIDs {
                if attachmentLookup[attachmentID] == nil {
                    issues.append("Message `\(id)` references missing attachment id `\(attachmentID)`.")
                }
            }

            let normalizedReactions = (message.reactions ?? []).compactMap { reaction -> ImportedReaction? in
                let emoji = reaction.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !emoji.isEmpty else {
                    warnings.append("Message `\(id)` contained a reaction with an empty emoji and it was ignored.")
                    return nil
                }

                return ImportedReaction(
                    senderID: reaction.senderID?.nilIfBlank,
                    senderDisplayName: reaction.senderDisplayName?.nilIfBlank,
                    emoji: emoji,
                    type: reaction.type?.nilIfBlank
                )
            }

            let senderDisplayName = message.senderDisplayName?.nilIfBlank ?? participant.displayName
            let metadataJSON: String?
            if let metadata = message.metadata {
                if JSONSerialization.isValidJSONObject(metadata.jsonObject),
                   let data = try? JSONSerialization.data(withJSONObject: metadata.jsonObject, options: [.sortedKeys]) {
                    metadataJSON = String(data: data, encoding: .utf8)
                } else {
                    warnings.append("Message `\(id)` metadata could not be serialized and was skipped.")
                    metadataJSON = nil
                }
            } else {
                metadataJSON = nil
            }

            normalized.append(
                ImportedMessage(
                    id: id,
                    senderID: senderID,
                    senderDisplayName: senderDisplayName,
                    isOutgoing: message.isOutgoing,
                    bodyText: bodyText,
                    timestamp: timestamp,
                    service: ServiceKind(rawArchiveValue: message.service),
                    attachmentIDs: message.attachmentIDs,
                    replyToMessageID: message.replyToMessageID?.nilIfBlank,
                    reactions: normalizedReactions,
                    metadataJSON: metadataJSON
                )
            )
        }

        return normalized
    }
}

private struct ArchiveTimestampParser {
    func parse(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractional.date(from: value) {
            return date
        }

        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var jsonObject: [String: Any] {
        mapValues(\.foundationObject)
    }
}

private extension JSONValue {
    var foundationObject: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.foundationObject)
        case .array(let value):
            return value.map(\.foundationObject)
        case .null:
            return NSNull()
        }
    }
}
