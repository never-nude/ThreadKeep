import Foundation

/// Per-thread plain-text transcript: a day separator, then `HH:MM  Sender: text` per
/// message, with attachments noted inline as `[attachment: filename]`.
struct ThreadTextExporter {
    private static let dayHeader: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter
    }()

    private static let messageTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func suggestedFilename(for thread: ThreadDetail, exportedAt: Date = Date()) -> String {
        "\(thread.title.slugified)-\(ThreadExportDateStamp.local(from: exportedAt)).txt"
    }

    func export(
        thread: ThreadDetail,
        nameResolution: ThreadJSONNameResolution,
        exportedAt: Date = Date()
    ) -> String {
        var lines: [String] = [nameResolution.threadTitle]

        for group in thread.groupedMessages {
            lines.append("")
            lines.append(Self.dayHeader.string(from: group.date))
            for message in group.messages {
                let time = Self.messageTime.string(from: message.timestamp)
                let sender = nameResolution.senderName(for: message)
                lines.append("\(time)  \(sender): \(message.bodyText)")
                for attachment in message.attachments {
                    lines.append("        [attachment: \(attachment.filename)]")
                }
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
