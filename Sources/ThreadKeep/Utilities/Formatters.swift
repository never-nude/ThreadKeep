import Foundation

enum AppFormatters {
    static let libraryRangeStart: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    static let messageTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let preciseMessageTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static let transcriptDayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    static let preciseMessageTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()

    static let metadataTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    static let exportTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    static let sidebarWeekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }()

    static let sidebarDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()

    static func threadDateRange(start: Date?, end: Date?) -> String {
        switch (start, end) {
        case let (start?, end?):
            if Calendar.current.isDate(start, inSameDayAs: end) {
                return libraryRangeStart.string(from: start)
            }
            return "\(libraryRangeStart.string(from: start)) - \(libraryRangeStart.string(from: end))"
        case let (start?, nil):
            return "From \(libraryRangeStart.string(from: start))"
        case let (nil, end?):
            return "Until \(libraryRangeStart.string(from: end))"
        default:
            return "No dates"
        }
    }

    static func sidebarTimestamp(for date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return messageTime.string(from: date)
        }

        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }

        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return sidebarWeekday.string(from: date)
        }

        return sidebarDate.string(from: date)
    }
}
