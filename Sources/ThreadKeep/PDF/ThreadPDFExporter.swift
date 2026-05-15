import AppKit
import CoreGraphics
import Foundation

enum PDFExportMode: String, CaseIterable, Identifiable, Sendable {
    case review
    case memorial

    var id: String { rawValue }

    var displayName: String {
        "Export PDF"
    }
}

enum ThreadPDFExportError: LocalizedError {
    case failedToCreateContext

    var errorDescription: String? {
        switch self {
        case .failedToCreateContext:
            return "The PDF renderer could not create a writable PDF context."
        }
    }
}

/// Caller-supplied resolved display strings so the PDF never leaks raw phone numbers.
/// Produced by the main-actor `ContactDisplayResolver` before export.
struct PDFNameResolution: Sendable {
    var threadTitle: String?
    var participantSummary: String?
    /// Maps raw `senderDisplayName`/participant identifier → resolved display name.
    var senderNames: [String: String] = [:]
}

struct ThreadPDFExporter {
    func export(thread: ThreadDetail, mode: PDFExportMode, resolution: PDFNameResolution = .init()) throws -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = NSMutableData()

        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw ThreadPDFExportError.failedToCreateContext
        }

        var mediaBox = pageRect
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ThreadPDFExportError.failedToCreateContext
        }

        let renderer = PDFRenderer(context: context, pageRect: pageRect, thread: thread, mode: mode, resolution: resolution)
        renderer.render()
        context.closePDF()
        return data as Data
    }

    func suggestedFilename(for thread: ThreadDetail, mode: PDFExportMode) -> String {
        let safeTitle = thread.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let timestamp = AppFormatters.exportTimestamp.string(from: Date())
        switch mode {
        case .review:
            return "\(safeTitle)-\(timestamp).pdf"
        case .memorial:
            return "\(safeTitle)-\(timestamp).pdf"
        }
    }
}

private final class PDFRenderer {
    private let context: CGContext
    private let pageRect: CGRect
    private let thread: ThreadDetail
    private let mode: PDFExportMode
    private let resolution: PDFNameResolution
    private let displayTitle: String
    private let participantSummary: String
    private let margins = NSEdgeInsets(top: 54, left: 48, bottom: 42, right: 48)
    private let headerHeight: CGFloat = 42
    private let footerHeight: CGFloat = 24
    private let dayHeaderHeight: CGFloat = 28
    private let messageSpacing: CGFloat = 12
    private let attachmentCardHeight: CGFloat = 44
    private let contentWidth: CGFloat
    private let bubbleMaxWidth: CGFloat
    private let paragraphStyle: NSParagraphStyle
    private let pageBackgroundColor = NSColor.white
    private let titleColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    private let bodyTextColor = NSColor(calibratedWhite: 0.12, alpha: 1)
    private let secondaryTextColor = NSColor(calibratedWhite: 0.38, alpha: 1)
    private let tertiaryTextColor = NSColor(calibratedWhite: 0.56, alpha: 1)
    private let separatorColor = NSColor(calibratedWhite: 0.85, alpha: 1)
    private let dayChipColor = NSColor(calibratedWhite: 0.94, alpha: 1)
    private let outgoingBubbleColor = NSColor(calibratedRed: 0.07, green: 0.46, blue: 0.96, alpha: 1)
    private let incomingBubbleColor = NSColor(calibratedWhite: 0.92, alpha: 1)
    private let outgoingAttachmentColor = NSColor(calibratedRed: 0.84, green: 0.91, blue: 0.99, alpha: 1)
    private let incomingAttachmentColor = NSColor(calibratedWhite: 0.98, alpha: 1)

    private var pageNumber = 0
    private var currentY: CGFloat = 0

    init(context: CGContext, pageRect: CGRect, thread: ThreadDetail, mode: PDFExportMode, resolution: PDFNameResolution) {
        self.context = context
        self.pageRect = pageRect
        self.thread = thread
        self.mode = mode
        self.resolution = resolution
        self.displayTitle = resolution.threadTitle?.nilIfBlank ?? thread.title
        self.participantSummary = resolution.participantSummary?.nilIfBlank
            ?? thread.participants.map(\.displayName).joined(separator: ", ")
        self.contentWidth = pageRect.width - margins.left - margins.right
        self.bubbleMaxWidth = min(360, contentWidth * 0.72)

        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 1.5
        style.paragraphSpacing = 0
        paragraphStyle = style
    }

    func render() {
        if mode == .memorial {
            beginPage()
            drawCoverPage()
            endPage()
        }

        beginPage()
        drawTranscript()
        endPage()

        if !thread.allAttachments.isEmpty || !thread.uniqueLinkURLs.isEmpty {
            beginPage()
            drawAppendix()
            endPage()
        }
    }

    private func drawTranscript() {
        var previousMessage: MessageRecord?

        for group in thread.groupedMessages {
            ensureSpace(dayHeaderHeight + 8)
            drawDayHeader(group.date)
            currentY += dayHeaderHeight + 4

            for message in group.messages {
                let showsSender = shouldShowSenderLabel(for: message, previous: previousMessage)
                let height = messageHeight(for: message, showsSender: showsSender)
                ensureSpace(height)
                drawMessage(message, showsSender: showsSender)
                currentY += height + messageSpacing
                previousMessage = message
            }
        }
    }

    private func drawAppendix() {
        drawSectionTitle("Appendix")
        currentY += 12

        if !thread.allAttachments.isEmpty {
            drawSubheading("Attachments")
            currentY += 8

            for attachment in thread.allAttachments {
                let rowHeight = appendixRowHeight(primary: attachment.filename, secondary: appendixDetail(for: attachment))
                ensureSpace(rowHeight + 10)
                drawAppendixRow(
                    title: "\(attachment.type.displayName) - \(attachment.filename)",
                    detail: appendixDetail(for: attachment),
                    tint: NSColor.systemGray
                )
                currentY += rowHeight + 8
            }

            currentY += 12
        }

        if !thread.uniqueLinkURLs.isEmpty {
            ensureSpace(32)
            drawSubheading("Link URLs")
            currentY += 8

            for url in thread.uniqueLinkURLs {
                let rowHeight = appendixRowHeight(primary: url.absoluteString, secondary: nil)
                ensureSpace(rowHeight + 10)
                drawAppendixRow(title: url.absoluteString, detail: nil, tint: NSColor.systemBlue)
                currentY += rowHeight + 8
            }
        }
    }

    private func beginPage() {
        pageNumber += 1
        context.beginPDFPage(nil)
        context.saveGState()
        context.translateBy(x: 0, y: pageRect.height)
        context.scaleBy(x: 1, y: -1)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

        pageBackgroundColor.setFill()
        NSBezierPath(rect: pageRect).fill()
        drawPageChrome()
        currentY = margins.top + headerHeight + 18
    }

    private func endPage() {
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
        context.endPDFPage()
    }

    private func drawPageChrome() {
        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
            .foregroundColor: titleColor
        ]
        let metaAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]

        let title = NSAttributedString(string: displayTitle, attributes: titleAttributes)
        title.draw(in: CGRect(x: margins.left, y: margins.top, width: contentWidth, height: 20))

        let meta = [
            AppFormatters.threadDateRange(start: thread.startDate, end: thread.endDate),
            "\(thread.participants.count) participants",
            "\(thread.messages.count) messages"
        ].joined(separator: " • ")
        NSAttributedString(string: meta, attributes: metaAttributes)
            .draw(in: CGRect(x: margins.left, y: margins.top + 20, width: contentWidth, height: 16))

        let divider = NSBezierPath()
        divider.move(to: CGPoint(x: margins.left, y: margins.top + headerHeight))
        divider.line(to: CGPoint(x: pageRect.width - margins.right, y: margins.top + headerHeight))
        separatorColor.setStroke()
        divider.lineWidth = 0.5
        divider.stroke()

        let footerRect = CGRect(
            x: margins.left,
            y: pageRect.height - margins.bottom - footerHeight,
            width: contentWidth,
            height: footerHeight
        )
        let footerText = "Page \(pageNumber) • ThreadKeep local archive"
        NSAttributedString(
            string: footerText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 9, weight: .regular),
                .foregroundColor: tertiaryTextColor
            ]
        ).draw(in: footerRect)
    }

    private func drawCoverPage() {
        let coverRect = CGRect(
            x: margins.left,
            y: 170,
            width: contentWidth,
            height: pageRect.height - 340
        )

        let title = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 28, weight: .semibold),
                .foregroundColor: titleColor
            ]
        )
        title.draw(in: CGRect(x: coverRect.minX, y: coverRect.minY, width: coverRect.width, height: 40))

        let subhead = [
            AppFormatters.threadDateRange(start: thread.startDate, end: thread.endDate),
            participantSummary
        ].joined(separator: "\n")

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4

        NSAttributedString(
            string: subhead,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .regular),
                .foregroundColor: secondaryTextColor,
                .paragraphStyle: paragraph
            ]
        ).draw(in: CGRect(x: coverRect.minX, y: coverRect.minY + 58, width: coverRect.width, height: 80))

        let note = "Prepared for private preservation and review. Exported locally from ThreadKeep."
        NSAttributedString(
            string: note,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: tertiaryTextColor
            ]
        ).draw(in: CGRect(x: coverRect.minX, y: coverRect.minY + 150, width: coverRect.width, height: 50))
    }

    private func drawDayHeader(_ date: Date) {
        let label = AppFormatters.transcriptDayHeader.string(from: date)
        let attributed = NSAttributedString(
            string: label,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: secondaryTextColor
            ]
        )

        let size = attributed.size()
        let width = size.width + 24
        let chipRect = CGRect(x: (pageRect.width - width) / 2, y: currentY, width: width, height: 22)
        dayChipColor.setFill()
        NSBezierPath(roundedRect: chipRect, xRadius: 11, yRadius: 11).fill()
        attributed.draw(in: chipRect.insetBy(dx: 12, dy: 4))
    }

    private func resolvedSender(for message: MessageRecord) -> String {
        let raw = message.senderDisplayName
        return resolution.senderNames[raw]?.nilIfBlank ?? raw
    }

    private func drawMessage(_ message: MessageRecord, showsSender: Bool) {
        let bubbleWidth = bubbleWidth(for: message)
        let x = message.isOutgoing
            ? pageRect.width - margins.right - bubbleWidth
            : margins.left
        var y = currentY

        if showsSender {
            let senderText = NSAttributedString(
                string: resolvedSender(for: message),
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: secondaryTextColor
                ]
            )
            senderText.draw(in: CGRect(x: x + 6, y: y, width: bubbleWidth, height: 14))
            y += 16
        }

        let bubbleRect = CGRect(x: x, y: y, width: bubbleWidth, height: bubbleInnerHeight(for: message))
        (message.isOutgoing ? outgoingBubbleColor : incomingBubbleColor).setFill()
        NSBezierPath(roundedRect: bubbleRect, xRadius: 18, yRadius: 18).fill()

        let bodyColor = message.isOutgoing ? NSColor.white : bodyTextColor
        let metaColor = message.isOutgoing ? NSColor.white.withAlphaComponent(0.88) : secondaryTextColor
        let insetRect = bubbleRect.insetBy(dx: 14, dy: 10)
        var cursorY = insetRect.minY

        if !message.bodyText.trimmed.isEmpty {
            let body = NSAttributedString(
                string: message.bodyText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                    .foregroundColor: bodyColor,
                    .paragraphStyle: paragraphStyle
                ]
            )
            let bodyHeight = body.boundingRect(
                with: CGSize(width: insetRect.width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height.rounded(.up)
            body.draw(
                with: CGRect(x: insetRect.minX, y: cursorY, width: insetRect.width, height: bodyHeight),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            cursorY += bodyHeight
        }

        if !message.attachments.isEmpty {
            cursorY += 8
            for attachment in message.attachments {
                let cardRect = CGRect(x: insetRect.minX, y: cursorY, width: insetRect.width, height: attachmentCardHeight)
                let cardFill = message.isOutgoing ? outgoingAttachmentColor : incomingAttachmentColor
                cardFill.setFill()
                NSBezierPath(roundedRect: cardRect, xRadius: 12, yRadius: 12).fill()

                let title = "\(attachment.type.displayName) • \(attachment.filename)"
                let detail = appendixDetail(for: attachment) ?? "Local attachment reference"
                NSAttributedString(
                    string: title,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                        .foregroundColor: bodyColor
                    ]
                ).draw(in: CGRect(x: cardRect.minX + 10, y: cardRect.minY + 8, width: cardRect.width - 20, height: 14))

                NSAttributedString(
                    string: detail,
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                        .foregroundColor: metaColor
                    ]
                ).draw(in: CGRect(x: cardRect.minX + 10, y: cardRect.minY + 22, width: cardRect.width - 20, height: 12))

                cursorY += attachmentCardHeight + 6
            }
            cursorY -= 6
        }

        if !message.reactions.isEmpty {
            cursorY += 8
            let reactionText = message.reactions.map(\.emoji).joined(separator: " ")
            NSAttributedString(
                string: reactionText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                    .foregroundColor: bodyColor
                ]
            ).draw(in: CGRect(x: insetRect.minX, y: cursorY, width: insetRect.width, height: 14))
            cursorY += 14
        }

        cursorY += 8
        let metaString: String
        switch mode {
        case .review:
            metaString = "\(AppFormatters.preciseMessageTimestamp.string(from: message.timestamp)) • \(message.service.displayName)"
        case .memorial:
            metaString = AppFormatters.preciseMessageTimestamp.string(from: message.timestamp)
        }

        NSAttributedString(
            string: metaString,
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
                .foregroundColor: metaColor
            ]
        ).draw(in: CGRect(x: insetRect.minX, y: cursorY, width: insetRect.width, height: 12))
    }

    private func bubbleWidth(for message: MessageRecord) -> CGFloat {
        let estimatedText = max(80, min(bubbleMaxWidth, CGFloat(message.bodyText.count) * 4.8 + 70))
        return min(bubbleMaxWidth, max(170, estimatedText))
    }

    private func bubbleInnerHeight(for message: MessageRecord) -> CGFloat {
        let width = bubbleWidth(for: message) - 28
        let bodyHeight: CGFloat
        if message.bodyText.trimmed.isEmpty {
            bodyHeight = 0
        } else {
            let body = NSAttributedString(
                string: message.bodyText,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12.5, weight: .regular),
                    .paragraphStyle: paragraphStyle
                ]
            )
            bodyHeight = body.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height.rounded(.up)
        }

        let attachmentsHeight = CGFloat(message.attachments.count) * (attachmentCardHeight + 6)
        let reactionsHeight = message.reactions.isEmpty ? CGFloat(0) : CGFloat(22)
        let spacing = CGFloat(
            (message.bodyText.trimmed.isEmpty ? 0 : 0)
                + (message.attachments.isEmpty ? 0 : 8)
                + (message.reactions.isEmpty ? 0 : 8)
                + 12
        )
        return 20 + bodyHeight + attachmentsHeight + reactionsHeight + spacing
    }

    private func messageHeight(for message: MessageRecord, showsSender: Bool) -> CGFloat {
        bubbleInnerHeight(for: message) + (showsSender ? 16 : 0)
    }

    private func shouldShowSenderLabel(for message: MessageRecord, previous: MessageRecord?) -> Bool {
        guard !message.isOutgoing else { return false }
        guard thread.participants.count > 2 else { return previous?.isOutgoing == true }
        return previous?.senderID != message.senderID
    }

    private func ensureSpace(_ neededHeight: CGFloat) {
        let bottomLimit = pageRect.height - margins.bottom - footerHeight - 8
        if currentY + neededHeight > bottomLimit {
            endPage()
            beginPage()
        }
    }

    private func drawSectionTitle(_ title: String) {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .semibold),
                .foregroundColor: titleColor
            ]
        ).draw(in: CGRect(x: margins.left, y: currentY, width: contentWidth, height: 24))
        currentY += 24
    }

    private func drawSubheading(_ title: String) {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: secondaryTextColor
            ]
        ).draw(in: CGRect(x: margins.left, y: currentY, width: contentWidth, height: 16))
        currentY += 16
    }

    private func drawAppendixRow(title: String, detail: String?, tint: NSColor) {
        let titleHeight = appendixRowHeight(primary: title, secondary: detail)
        let rowRect = CGRect(x: margins.left, y: currentY, width: contentWidth, height: titleHeight)
        let markerRect = CGRect(x: rowRect.minX, y: rowRect.minY + 6, width: 6, height: 6)
        tint.setFill()
        NSBezierPath(ovalIn: markerRect).fill()

        let titleAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: titleColor
        ]
        let detailAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: secondaryTextColor
        ]

        let textRect = CGRect(x: rowRect.minX + 16, y: rowRect.minY, width: rowRect.width - 16, height: rowRect.height)
        let attributedTitle = NSAttributedString(string: title, attributes: titleAttributes)
        let titleBounds = attributedTitle.boundingRect(
            with: CGSize(width: textRect.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        attributedTitle.draw(
            with: CGRect(x: textRect.minX, y: textRect.minY, width: textRect.width, height: titleBounds.height),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        if let detail {
            NSAttributedString(string: detail, attributes: detailAttributes).draw(
                with: CGRect(
                    x: textRect.minX,
                    y: textRect.minY + titleBounds.height + 2,
                    width: textRect.width,
                    height: rowRect.height - titleBounds.height - 2
                ),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
    }

    private func appendixRowHeight(primary: String, secondary: String?) -> CGFloat {
        let width = contentWidth - 16
        let titleHeight = NSAttributedString(
            string: primary,
            attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .medium)]
        )
        .boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height.rounded(.up)

        let detailHeight: CGFloat
        if let secondary {
            detailHeight = NSAttributedString(
                string: secondary,
                attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .regular)]
            )
            .boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height.rounded(.up)
        } else {
            detailHeight = 0
        }

        return titleHeight + detailHeight + (secondary == nil ? 4 : 8)
    }

    private func appendixDetail(for attachment: AttachmentRecord) -> String? {
        let parts = [attachment.url, attachment.localPath, attachment.mimeType].compactMap { $0?.trimmed }
        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}
