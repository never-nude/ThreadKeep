import Foundation

enum ImportSourceKind: String, Codable, Sendable {
    case jsonArchive
    case messagesPDF
    case messagesMacBeta

    init(fileExtension: String?) {
        switch fileExtension?.lowercased() {
        case "pdf":
            self = .messagesPDF
        default:
            self = .jsonArchive
        }
    }

    var displayName: String {
        switch self {
        case .jsonArchive:
            return "Saved Archive"
        case .messagesPDF:
            return "Conversation PDF"
        case .messagesMacBeta:
            return "Messages on This Mac"
        }
    }

    var systemImageName: String {
        switch self {
        case .jsonArchive:
            return "curlybraces.square"
        case .messagesPDF:
            return "doc.richtext"
        case .messagesMacBeta:
            return "message"
        }
    }

    var defaultFileExtension: String {
        switch self {
        case .jsonArchive:
            return "json"
        case .messagesPDF:
            return "pdf"
        case .messagesMacBeta:
            return "json"
        }
    }
}

enum ServiceKind: String, Codable, CaseIterable, Sendable {
    case iMessage
    case sms = "SMS"
    case unknown = "Unknown"

    init(rawArchiveValue: String) {
        let normalized = rawArchiveValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "imessage", "i-message":
            self = .iMessage
        case "sms":
            self = .sms
        default:
            self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .iMessage:
            return "iMessage"
        case .sms:
            return "SMS"
        case .unknown:
            return "Unknown"
        }
    }
}

enum AttachmentKind: String, Codable, CaseIterable, Sendable {
    case image
    case video
    case audio
    case file
    case link
    case unknown

    init(rawArchiveValue: String) {
        let normalized = rawArchiveValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self = AttachmentKind(rawValue: normalized) ?? .unknown
    }

    var displayName: String {
        rawValue.capitalized
    }
}

struct ImportedConversationArchive: Identifiable, Sendable {
    let id: String
    let title: String
    let participants: [ImportedParticipant]
    let messages: [ImportedMessage]
    let attachments: [ImportedAttachment]
    let warnings: [String]
    let sourceFilename: String?

    var dateRange: ClosedRange<Date>? {
        guard let first = messages.first?.timestamp, let last = messages.last?.timestamp else {
            return nil
        }
        return first ... last
    }

    var messageCount: Int { messages.count }
    var participantCount: Int { participants.count }
    var attachmentCount: Int { attachments.count }
}

struct ImportedParticipant: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

struct ImportedAttachment: Identifiable, Hashable, Sendable {
    let id: String
    let type: AttachmentKind
    let filename: String
    let localPath: String?
    let mimeType: String?
    let thumbnail: String?
    let url: String?
}

struct ImportedReaction: Hashable, Sendable {
    let senderID: String?
    let senderDisplayName: String?
    let emoji: String
    let type: String?
}

struct ImportedMessage: Identifiable, Hashable, Sendable {
    let id: String
    let senderID: String
    let senderDisplayName: String
    let isOutgoing: Bool
    let bodyText: String
    let timestamp: Date
    let service: ServiceKind
    let attachmentIDs: [String]
    let replyToMessageID: String?
    let reactions: [ImportedReaction]
    let metadataJSON: String?
}

struct ThreadSummary: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let startDate: Date?
    let endDate: Date?
    let participantNames: [String]
    let participantCount: Int
    let messageCount: Int
    let attachmentCount: Int
    let hasAttachments: Bool
    let importedAt: Date
    let rawArchivePath: String?
    let importSourceKind: ImportSourceKind
    let matchCount: Int?
    let latestMessageText: String?
    let latestMessageTimestamp: Date?
    let latestSenderDisplayName: String?
    let latestMessageIsOutgoing: Bool

    var rawImportFilename: String? {
        rawArchivePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}

struct ParticipantRecord: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
}

struct AttachmentRecord: Identifiable, Hashable, Sendable {
    let id: String
    let type: AttachmentKind
    let filename: String
    let localPath: String?
    let mimeType: String?
    let thumbnail: String?
    let url: String?
}

struct MessageReactionRecord: Hashable, Sendable {
    let senderID: String?
    let senderDisplayName: String?
    let emoji: String
    let type: String?
}

struct MessageRecord: Identifiable, Hashable, Sendable {
    let id: String
    let threadID: String
    let senderID: String
    let senderDisplayName: String
    let isOutgoing: Bool
    let bodyText: String
    let timestamp: Date
    let service: ServiceKind
    let attachments: [AttachmentRecord]
    let replyToMessageID: String?
    let reactions: [MessageReactionRecord]
    let metadataJSON: String?

    var hasAttachments: Bool {
        !attachments.isEmpty
    }

    var linkURLs: [URL] {
        LinkDetector.urls(in: bodyText)
    }
}

struct ThreadSearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let messageID: String
    let senderDisplayName: String
    let timestamp: Date
    let snippet: String
}

struct LibrarySearchResult: Identifiable, Hashable, Sendable {
    let id: String
    let threadID: String
    let messageID: String
    let threadTitle: String
    let participantNames: [String]
    let senderDisplayName: String
    let timestamp: Date
    let snippet: String
}

struct TimelineBucket: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let count: Int
    let startDate: Date
}

struct ConversationStatistics: Hashable, Sendable {
    let totalMessages: Int
    let outgoingMessages: Int
    let incomingMessages: Int
    let attachmentMessages: Int
    let monthlyBuckets: [TimelineBucket]
}

struct MessagesChatCandidate: Identifiable, Hashable, Sendable {
    let id: Int
    let title: String
    let participantNames: [String]
    let serviceName: String?
    let startDate: Date?
    let endDate: Date?
    let messageCount: Int

    var subtitle: String {
        let names = participantNames.joined(separator: ", ")
        let dateRange = AppFormatters.threadDateRange(start: startDate, end: endDate)
        if names.isEmpty {
            return dateRange
        }
        return "\(names) • \(dateRange)"
    }
}

struct ThreadDetail: Identifiable, Sendable {
    let id: String
    let title: String
    let participants: [ParticipantRecord]
    let messages: [MessageRecord]
    let statistics: ConversationStatistics
    let rawArchivePath: String?
    let importedAt: Date
    let importSourceKind: ImportSourceKind
    let isMergedThread: Bool

    init(
        id: String,
        title: String,
        participants: [ParticipantRecord],
        messages: [MessageRecord],
        statistics: ConversationStatistics,
        rawArchivePath: String?,
        importedAt: Date,
        importSourceKind: ImportSourceKind,
        isMergedThread: Bool = false
    ) {
        self.id = id
        self.title = title
        self.participants = participants
        self.messages = messages
        self.statistics = statistics
        self.rawArchivePath = rawArchivePath
        self.importedAt = importedAt
        self.importSourceKind = importSourceKind
        self.isMergedThread = isMergedThread
    }

    var rawImportFilename: String? {
        rawArchivePath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    var startDate: Date? { messages.first?.timestamp }
    var endDate: Date? { messages.last?.timestamp }
    var attachmentCount: Int { messages.flatMap(\.attachments).count }

    var groupedMessages: [ConversationDayGroup] {
        Dictionary(grouping: messages) { Calendar.current.startOfDay(for: $0.timestamp) }
            .sorted { $0.key < $1.key }
            .map { ConversationDayGroup(date: $0.key, messages: $0.value.sorted { $0.timestamp < $1.timestamp }) }
    }

    var allAttachments: [AttachmentRecord] {
        Array(Set(messages.flatMap(\.attachments))).sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    var uniqueLinkURLs: [URL] {
        Array(Set(messages.flatMap(\.linkURLs))).sorted { $0.absoluteString < $1.absoluteString }
    }

    func firstMessageID(onOrAfter date: Date, calendar: Calendar = .current) -> String? {
        let startOfDay = calendar.startOfDay(for: date)
        if let match = messages.first(where: { $0.timestamp >= startOfDay }) {
            return match.id
        }
        return messages.last?.id
    }

    func firstDayOnOrAfter(_ date: Date, calendar: Calendar = .current) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        if let match = messages.first(where: { $0.timestamp >= startOfDay }) {
            return calendar.startOfDay(for: match.timestamp)
        }
        return messages.last.map { calendar.startOfDay(for: $0.timestamp) }
    }

    func firstDay(in bucket: TimelineBucket, calendar: Calendar = .current) -> Date? {
        firstDayOnOrAfter(bucket.startDate, calendar: calendar)
    }

    func firstMessageID(in bucket: TimelineBucket, calendar: Calendar = .current) -> String? {
        firstMessageID(onOrAfter: bucket.startDate, calendar: calendar)
    }

    func day(containingMessageID messageID: String, calendar: Calendar = .current) -> Date? {
        guard let message = messages.first(where: { $0.id == messageID }) else { return nil }
        return calendar.startOfDay(for: message.timestamp)
    }
}

struct ConversationDayGroup: Identifiable, Sendable {
    let date: Date
    let messages: [MessageRecord]

    var id: Date { date }
}

struct LibraryFilters: Equatable, Sendable {
    var keyword: String = ""
    var startDate: Date?
    var endDate: Date?
    var participantID: String?
    var hasAttachmentsOnly = false

    var hasActiveFilters: Bool {
        !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
        startDate != nil ||
        endDate != nil ||
        participantID != nil ||
        hasAttachmentsOnly
    }
}

enum LibraryThreadSortOption: String, CaseIterable, Identifiable, Sendable {
    case mostRecent
    case oldestFirst
    case nameAZ
    case nameZA
    case numberHandle
    case mostMessages

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .mostRecent:
            return "Most Recent"
        case .oldestFirst:
            return "Oldest"
        case .nameAZ:
            return "Name A-Z"
        case .nameZA:
            return "Name Z-A"
        case .numberHandle:
            return "Number / Handle"
        case .mostMessages:
            return "Most Messages"
        }
    }
}
