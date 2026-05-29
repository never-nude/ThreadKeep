import Foundation

/// Per-thread CSV export: one row per message, RFC 4180 quoting.
/// Columns: timestamp (ISO 8601), sender, direction (you/them), type (sent/received),
/// text, attachments (semicolon-joined filenames).
struct ThreadCSVExporter {
    private static let columns = ["timestamp", "sender", "direction", "type", "text", "attachments"]

    func suggestedFilename(for thread: ThreadDetail, exportedAt: Date = Date()) -> String {
        "\(thread.title.slugified)-\(ThreadExportDateStamp.local(from: exportedAt)).csv"
    }

    func export(
        thread: ThreadDetail,
        nameResolution: ThreadJSONNameResolution,
        exportedAt: Date = Date()
    ) -> String {
        var rows: [String] = [Self.columns.map(Self.escapeField).joined(separator: ",")]

        for message in thread.messages {
            let fields = [
                ThreadExportTimestamp.iso8601(from: message.timestamp),
                nameResolution.senderName(for: message),
                message.isOutgoing ? "you" : "them",
                message.isOutgoing ? "sent" : "received",
                message.bodyText,
                message.attachments.map(\.filename).joined(separator: ";")
            ]
            rows.append(fields.map(Self.escapeField).joined(separator: ","))
        }

        return rows.joined(separator: "\n") + "\n"
    }

    /// RFC 4180 field escaping: quote fields containing comma, quote, or newline; double internal quotes.
    private static func escapeField(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return value
        }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}
