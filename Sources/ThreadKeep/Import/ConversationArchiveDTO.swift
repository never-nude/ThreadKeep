import Foundation

struct ConversationArchiveDTO: Codable, Sendable {
    let threadID: String
    let threadTitle: String
    let participants: [ArchiveParticipantDTO]
    let messages: [ArchiveMessageDTO]
    let attachments: [ArchiveAttachmentDTO]

    enum CodingKeys: String, CodingKey {
        case threadID = "thread_id"
        case threadTitle = "thread_title"
        case participants
        case messages
        case attachments
    }
}

extension ConversationArchiveDTO {
    init(archive: ImportedConversationArchive) {
        self.threadID = archive.id
        self.threadTitle = archive.title
        self.participants = archive.participants.map(ArchiveParticipantDTO.init(participant:))
        self.messages = archive.messages.map(ArchiveMessageDTO.init(message:))
        self.attachments = archive.attachments.map(ArchiveAttachmentDTO.init(attachment:))
    }
}

struct ArchiveParticipantDTO: Codable, Sendable {
    let id: String
    let displayName: String

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

extension ArchiveParticipantDTO {
    init(participant: ImportedParticipant) {
        self.id = participant.id
        self.displayName = participant.displayName
    }
}

struct ArchiveMessageDTO: Codable, Sendable {
    let id: String
    let senderID: String
    let senderDisplayName: String?
    let isOutgoing: Bool
    let bodyText: String
    let timestamp: String
    let service: String
    let attachmentIDs: [String]
    let replyToMessageID: String?
    let reactions: [ArchiveReactionDTO]?
    let metadata: [String: JSONValue]?

    enum CodingKeys: String, CodingKey {
        case id
        case senderID = "sender_id"
        case senderDisplayName = "sender_display_name"
        case isOutgoing = "is_outgoing"
        case bodyText = "body_text"
        case timestamp
        case service
        case attachmentIDs = "attachment_ids"
        case replyToMessageID = "reply_to_message_id"
        case reactions
        case metadata
    }
}

extension ArchiveMessageDTO {
    init(message: ImportedMessage) {
        self.id = message.id
        self.senderID = message.senderID
        self.senderDisplayName = message.senderDisplayName
        self.isOutgoing = message.isOutgoing
        self.bodyText = message.bodyText
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.timestamp = formatter.string(from: message.timestamp)
        self.service = message.service.displayName
        self.attachmentIDs = message.attachmentIDs
        self.replyToMessageID = message.replyToMessageID
        self.reactions = message.reactions.map(ArchiveReactionDTO.init(reaction:))
        self.metadata = JSONValue.objectDictionary(fromJSONString: message.metadataJSON)
    }
}

struct ArchiveReactionDTO: Codable, Sendable, Hashable {
    let senderID: String?
    let senderDisplayName: String?
    let emoji: String
    let type: String?

    enum CodingKeys: String, CodingKey {
        case senderID = "sender_id"
        case senderDisplayName = "sender_display_name"
        case emoji
        case type
    }
}

extension ArchiveReactionDTO {
    init(reaction: ImportedReaction) {
        self.senderID = reaction.senderID
        self.senderDisplayName = reaction.senderDisplayName
        self.emoji = reaction.emoji
        self.type = reaction.type
    }
}

struct ArchiveAttachmentDTO: Codable, Sendable {
    let id: String
    let type: String
    let filename: String
    let localPath: String?
    let mimeType: String?
    let thumbnail: String?
    let url: String?

    enum CodingKeys: String, CodingKey {
        case id
        case type
        case filename
        case localPath = "local_path"
        case mimeType = "mime_type"
        case thumbnail
        case url
    }
}

extension ArchiveAttachmentDTO {
    init(attachment: ImportedAttachment) {
        self.id = attachment.id
        self.type = attachment.type.rawValue
        self.filename = attachment.filename
        self.localPath = attachment.localPath
        self.mimeType = attachment.mimeType
        self.thumbnail = attachment.thumbnail
        self.url = attachment.url
    }
}

enum JSONValue: Codable, Sendable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unsupported JSON value"
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

extension JSONValue {
    static func objectDictionary(fromJSONString json: String?) -> [String: JSONValue]? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else {
            return nil
        }

        return dictionary.compactMapValues(JSONValue.init(foundationObject:))
    }

    init?(foundationObject: Any) {
        switch foundationObject {
        case let value as String:
            self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = .bool(value.boolValue)
            } else {
                self = .number(value.doubleValue)
            }
        case let value as [String: Any]:
            self = .object(value.compactMapValues(JSONValue.init(foundationObject:)))
        case let value as [Any]:
            self = .array(value.compactMap(JSONValue.init(foundationObject:)))
        case _ as NSNull:
            self = .null
        default:
            return nil
        }
    }
}
