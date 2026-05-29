import Foundation

/// ISO 8601 timestamps shared by the text-based exporters (CSV/HTML) so all formats
/// agree on message timestamps.
enum ThreadExportTimestamp {
    static func iso8601(from date: Date) -> String {
        // Value-type API; default style is `.withInternetDateTime` (e.g. 2026-05-22T11:00:00Z).
        date.ISO8601Format()
    }
}

/// Local-date stamp (yyyy-MM-dd) for export filenames, matching the JSON exporter so the
/// file name reflects the day the user ran the export.
enum ThreadExportDateStamp {
    static func local(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
