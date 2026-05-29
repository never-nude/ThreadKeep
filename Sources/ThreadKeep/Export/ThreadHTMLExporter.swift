import Foundation

/// Per-thread standalone HTML transcript with inline CSS (no external assets). Messages are
/// rendered in order with sender and timestamp; attachments are referenced by filename.
struct ThreadHTMLExporter {
    private static let displayTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func suggestedFilename(for thread: ThreadDetail, exportedAt: Date = Date()) -> String {
        "\(thread.title.slugified)-\(ThreadExportDateStamp.local(from: exportedAt)).html"
    }

    func export(
        thread: ThreadDetail,
        nameResolution: ThreadJSONNameResolution,
        exportedAt: Date = Date()
    ) -> String {
        let title = Self.escape(nameResolution.threadTitle)
        var html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(title)</title>
        <style>
        :root { color-scheme: light dark; }
        body { font: 16px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; margin: 0; padding: 2rem; background: #f5f5f7; color: #1d1d1f; }
        .thread { max-width: 720px; margin: 0 auto; }
        h1 { font-size: 1.5rem; margin: 0 0 1.5rem; }
        .message { padding: 0.75rem 1rem; margin: 0.5rem 0; border-radius: 12px; background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,0.06); }
        .message.you { background: #0b93f6; color: #fff; }
        .meta { font-size: 0.8rem; opacity: 0.7; margin-bottom: 0.25rem; }
        .sender { font-weight: 600; }
        .body { white-space: pre-wrap; word-wrap: break-word; }
        .attachments { margin: 0.5rem 0 0; padding-left: 1.25rem; font-size: 0.85rem; }
        @media (prefers-color-scheme: dark) {
          body { background: #1d1d1f; color: #f5f5f7; }
          .message { background: #2c2c2e; }
        }
        </style>
        </head>
        <body>
        <main class="thread">
        <h1>\(title)</h1>

        """

        for message in thread.messages {
            let directionClass = message.isOutgoing ? "you" : "them"
            let sender = Self.escape(nameResolution.senderName(for: message))
            let timestamp = Self.escape(Self.displayTimestamp.string(from: message.timestamp))
            let isoTimestamp = Self.escape(ThreadExportTimestamp.iso8601(from: message.timestamp))
            let body = Self.escape(message.bodyText)

            html += """
            <article class="message \(directionClass)">
            <div class="meta"><span class="sender">\(sender)</span> · <time datetime="\(isoTimestamp)">\(timestamp)</time></div>
            <div class="body">\(body)</div>
            """

            if !message.attachments.isEmpty {
                html += "\n<ul class=\"attachments\">\n"
                for attachment in message.attachments {
                    html += "<li>\(Self.escape(attachment.filename))</li>\n"
                }
                html += "</ul>"
            }

            html += "\n</article>\n"
        }

        html += """
        </main>
        </body>
        </html>

        """

        return html
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
