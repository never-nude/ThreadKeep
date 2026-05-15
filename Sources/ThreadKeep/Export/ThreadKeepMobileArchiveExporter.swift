import Foundation
import UniformTypeIdentifiers

struct ThreadKeepMobileArchiveExporter {
    private let appVersion: String?

    init(appVersion: String? = ThreadKeepDesktopAppVersion.current) {
        self.appVersion = appVersion
    }

    func export(archive: ImportedConversationArchive, exportedAt: Date = Date()) throws -> Data {
        let payload = ThreadKeepMobileArchiveV1DTO(
            archive: archive,
            exportedAt: exportedAt,
            appVersion: appVersion
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    func suggestedFilename(for title: String) -> String {
        "ThreadKeep-\(title.slugified).threadkeeparchive"
    }
}

extension UTType {
    static let threadkeepArchive = UTType(exportedAs: "com.threadkeep.archive", conformingTo: .json)
}

private enum ThreadKeepDesktopAppVersion {
    static var current: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
}

private struct ThreadKeepMobileArchiveV1DTO: Encodable {
    let manifest: Manifest
    let thread: Thread
    let messages: [Message]
    let attachments: [Attachment]

    init(archive: ImportedConversationArchive, exportedAt: Date, appVersion: String?) {
        manifest = Manifest(
            schemaVersion: 1,
            archiveID: archive.id,
            archiveTitle: archive.title,
            exportedAt: ThreadKeepMobileTimestampFormatter.string(from: exportedAt),
            source: Source(kind: "threadkeep-desktop", appVersion: appVersion)
        )
        thread = Thread(
            threadID: archive.id,
            threadTitle: archive.title,
            participants: archive.participants.map(Participant.init(participant:))
        )
        messages = archive.messages.map(Message.init(message:))
        attachments = []
    }

    struct Manifest: Encodable {
        let schemaVersion: Int
        let archiveID: String
        let archiveTitle: String
        let exportedAt: String
        let source: Source

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case archiveID = "archive_id"
            case archiveTitle = "archive_title"
            case exportedAt = "exported_at"
            case source
        }
    }

    struct Source: Encodable {
        let kind: String
        let appVersion: String?

        enum CodingKeys: String, CodingKey {
            case kind
            case appVersion = "app_version"
        }
    }

    struct Thread: Encodable {
        let threadID: String
        let threadTitle: String
        let participants: [Participant]

        enum CodingKeys: String, CodingKey {
            case threadID = "thread_id"
            case threadTitle = "thread_title"
            case participants
        }
    }

    struct Participant: Encodable {
        let participantID: String
        let displayName: String

        init(participant: ImportedParticipant) {
            participantID = participant.id
            displayName = participant.displayName
        }

        enum CodingKeys: String, CodingKey {
            case participantID = "participant_id"
            case displayName = "display_name"
        }
    }

    struct Message: Encodable {
        let messageID: String
        let senderID: String
        let senderDisplayName: String
        let isOutgoing: Bool
        let bodyText: String
        let timestamp: String

        init(message: ImportedMessage) {
            messageID = message.id
            senderID = message.senderID
            senderDisplayName = message.senderDisplayName
            isOutgoing = message.isOutgoing
            bodyText = message.bodyText.replacingOccurrences(of: "\u{FFFC}", with: "")
            timestamp = ThreadKeepMobileTimestampFormatter.string(from: message.timestamp)
        }

        enum CodingKeys: String, CodingKey {
            case messageID = "message_id"
            case senderID = "sender_id"
            case senderDisplayName = "sender_display_name"
            case isOutgoing = "is_outgoing"
            case bodyText = "body_text"
            case timestamp
        }
    }

    struct Attachment: Encodable {}
}

private enum ThreadKeepMobileTimestampFormatter {
    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
