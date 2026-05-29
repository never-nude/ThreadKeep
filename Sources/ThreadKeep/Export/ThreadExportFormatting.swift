import Foundation

/// ISO 8601 timestamps shared by the text-based exporters (CSV/HTML) so all formats
/// agree on message timestamps.
enum ThreadExportTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func iso8601(from date: Date) -> String {
        formatter.string(from: date)
    }
}

/// Local-date stamp (yyyy-MM-dd) for export filenames, matching the JSON exporter so the
/// file name reflects the day the user ran the export.
enum ThreadExportDateStamp {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func local(from date: Date) -> String {
        formatter.string(from: date)
    }
}
