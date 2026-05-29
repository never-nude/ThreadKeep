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

struct ThreadDateJumpBucket: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let startDate: Date
    let firstMessageID: String
    let firstMessageDate: Date
    let messageCount: Int
}

struct ThreadDateJumpTarget: Hashable, Sendable {
    let messageID: String
    let messageDate: Date
    let messageDay: Date
    let requestedDate: Date

    func isExactDayMatch(calendar: Calendar = .current) -> Bool {
        calendar.isDate(messageDay, inSameDayAs: requestedDate)
    }
}

struct ThreadDateJumpIndex: Hashable, Sendable {
    let dayBuckets: [ThreadDateJumpBucket]
    let monthBuckets: [ThreadDateJumpBucket]
    private let lastMessageID: String?
    private let lastMessageDate: Date?

    init(messages: [MessageRecord], calendar: Calendar = .current) {
        let sortedMessages = messages.sorted {
            if $0.timestamp == $1.timestamp {
                return $0.id < $1.id
            }
            return $0.timestamp < $1.timestamp
        }
        lastMessageID = sortedMessages.last?.id
        lastMessageDate = sortedMessages.last?.timestamp

        var days: [String: BucketAccumulator] = [:]
        var months: [String: BucketAccumulator] = [:]

        for message in sortedMessages {
            let dayStart = calendar.startOfDay(for: message.timestamp)
            let monthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: message.timestamp)
            ) ?? dayStart

            Self.append(message, startDate: dayStart, id: Self.dayID(for: dayStart, calendar: calendar), to: &days)
            Self.append(message, startDate: monthStart, id: Self.monthID(for: monthStart, calendar: calendar), to: &months)
        }

        dayBuckets = days.map { id, accumulator in
            ThreadDateJumpBucket(
                id: id,
                label: Self.dayLabel(for: accumulator.startDate),
                startDate: accumulator.startDate,
                firstMessageID: accumulator.firstMessageID,
                firstMessageDate: accumulator.firstMessageDate,
                messageCount: accumulator.messageCount
            )
        }
        .sorted { $0.startDate < $1.startDate }

        monthBuckets = months.map { id, accumulator in
            ThreadDateJumpBucket(
                id: id,
                label: Self.monthLabel(for: accumulator.startDate),
                startDate: accumulator.startDate,
                firstMessageID: accumulator.firstMessageID,
                firstMessageDate: accumulator.firstMessageDate,
                messageCount: accumulator.messageCount
            )
        }
        .sorted { $0.startDate < $1.startDate }
    }

    func target(onOrAfter date: Date, calendar: Calendar = .current) -> ThreadDateJumpTarget? {
        let requestedDay = calendar.startOfDay(for: date)
        if let bucket = dayBuckets.first(where: { $0.startDate >= requestedDay }) {
            return target(for: bucket, requestedDate: date, calendar: calendar)
        }

        guard let lastMessageID, let lastMessageDate else {
            return nil
        }
        return ThreadDateJumpTarget(
            messageID: lastMessageID,
            messageDate: lastMessageDate,
            messageDay: calendar.startOfDay(for: lastMessageDate),
            requestedDate: date
        )
    }

    func target(forMonthID monthID: String, calendar: Calendar = .current) -> ThreadDateJumpTarget? {
        guard let bucket = monthBuckets.first(where: { $0.id == monthID }) else {
            return nil
        }
        return target(for: bucket, requestedDate: bucket.startDate, calendar: calendar)
    }

    private func target(for bucket: ThreadDateJumpBucket, requestedDate: Date, calendar: Calendar) -> ThreadDateJumpTarget {
        ThreadDateJumpTarget(
            messageID: bucket.firstMessageID,
            messageDate: bucket.firstMessageDate,
            messageDay: calendar.startOfDay(for: bucket.firstMessageDate),
            requestedDate: requestedDate
        )
    }

    private static func append(
        _ message: MessageRecord,
        startDate: Date,
        id: String,
        to buckets: inout [String: BucketAccumulator]
    ) {
        if var bucket = buckets[id] {
            bucket.messageCount += 1
            buckets[id] = bucket
        } else {
            buckets[id] = BucketAccumulator(
                startDate: startDate,
                firstMessageID: message.id,
                firstMessageDate: message.timestamp,
                messageCount: 1
            )
        }
    }

    private static func dayID(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private static func monthID(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
    }

    private static func dayLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private static func monthLabel(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).year())
    }

    private struct BucketAccumulator: Hashable {
        let startDate: Date
        let firstMessageID: String
        let firstMessageDate: Date
        var messageCount: Int
    }
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
            .map { ConversationDayGroup(date: $0.key, messages: $0.value.sorted { lhs, rhs in
                (lhs.timestamp, lhs.id) < (rhs.timestamp, rhs.id)
            }) }
    }

    var allAttachments: [AttachmentRecord] {
        Array(Set(messages.flatMap(\.attachments))).sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }
    }

    var uniqueLinkURLs: [URL] {
        Array(Set(messages.flatMap(\.linkURLs))).sorted { $0.absoluteString < $1.absoluteString }
    }

    var dateJumpIndex: ThreadDateJumpIndex {
        ThreadDateJumpIndex(messages: messages)
    }

    func dateJumpTarget(onOrAfter date: Date, calendar: Calendar = .current) -> ThreadDateJumpTarget? {
        ThreadDateJumpIndex(messages: messages, calendar: calendar).target(onOrAfter: date, calendar: calendar)
    }

    func dateJumpTarget(forMonthID monthID: String, calendar: Calendar = .current) -> ThreadDateJumpTarget? {
        ThreadDateJumpIndex(messages: messages, calendar: calendar).target(forMonthID: monthID, calendar: calendar)
    }

    func firstMessageID(onOrAfter date: Date, calendar: Calendar = .current) -> String? {
        dateJumpTarget(onOrAfter: date, calendar: calendar)?.messageID
    }

    func firstDayOnOrAfter(_ date: Date, calendar: Calendar = .current) -> Date? {
        dateJumpTarget(onOrAfter: date, calendar: calendar)?.messageDay
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
