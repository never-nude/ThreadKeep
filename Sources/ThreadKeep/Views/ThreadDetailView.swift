import AppKit
import QuickLookThumbnailing
import SwiftUI

struct ThreadDetailView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("threadkeep.import.useContactsNames") private var useContactsNames = true
    let thread: ThreadDetail

    @FocusState private var isSearchFieldFocused: Bool
    @StateObject private var contactsResolver = ContactDisplayResolver()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchBar
            Divider()
            transcript
        }
        .onChange(of: viewModel.threadSearchQuery) { _, _ in
            viewModel.scheduleThreadSearch()
        }
        .task(id: useContactsNames) {
            await contactsResolver.refresh(enabled: useContactsNames)
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepContactsAccessDidChange)) { _ in
            Task {
                await contactsResolver.refresh(enabled: useContactsNames)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepFocusSearch)) { _ in
            isSearchFieldFocused = true
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(participants: avatarParticipants, size: 40, resolver: contactsResolver)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayedThreadTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let groupPreview = displayedGroupParticipantPreview {
                    Text(groupPreview)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var searchBar: some View {
        HStack(spacing: 12) {
            Label {
                TextField("Search within this conversation", text: $viewModel.threadSearchQuery)
                    .textFieldStyle(.roundedBorder)
                    .focused($isSearchFieldFocused)
            } icon: {
                Image(systemName: "magnifyingglass")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !viewModel.threadSearchResults.isEmpty {
                Text(searchResultsLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Button {
                    viewModel.navigateSearchResult(delta: -1)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .help("Previous match")

                Button {
                    viewModel.navigateSearchResult(delta: 1)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .help("Next match")
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.thinMaterial)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            GeometryReader { geometry in
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(thread.groupedMessages) { group in
                            VStack(spacing: 8) {
                                DayRibbon(date: group.date)

                                ForEach(groupedMessages(in: group.messages)) { block in
                                    VStack(alignment: block.isOutgoing ? .trailing : .leading, spacing: 4) {
                                        ForEach(Array(block.messages.enumerated()), id: \.element.id) { index, message in
                                            MessageBubbleView(
                                                message: message,
                                                searchQuery: viewModel.threadSearchQuery,
                                                showsSenderLabel: isGroupChat && !block.isOutgoing && index == 0,
                                                isFocused: viewModel.focusedMessageID == message.id,
                                                resolvedSenderName: contactsResolver.resolvedName(for: block.senderDisplayValue),
                                                isGroupChat: isGroupChat,
                                                showsAvatar: isGroupChat && !block.isOutgoing && index == 0,
                                                isLastInRun: index == block.messages.count - 1,
                                                maxBubbleWidth: max(240, geometry.size.width * 0.7),
                                                senderHandle: block.senderDisplayValue,
                                                sourceHandle: thread.isMergedThread ? sourceHandle(for: message) : nil,
                                                resolver: contactsResolver
                                            )
                                            .id(TranscriptScrollTarget.message(message.id))
                                        }
                                    }
                                }
                            }
                            .id(dayAnchorID(for: group.date))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 22)
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .onAppear {
                    if let firstGroup = thread.groupedMessages.first {
                        scrollTranscript(
                            with: proxy,
                            request: viewModel.scrollRequest ?? MessageScrollRequest(target: .day(firstGroup.date), animated: false),
                            ignoreStaleRequests: viewModel.scrollRequest != nil
                        )
                    }
                }
                .onChange(of: viewModel.scrollRequest) { _, request in
                    guard let request else { return }
                    scrollTranscript(with: proxy, request: request, ignoreStaleRequests: true)
                }
            }
        }
    }

    private func groupedMessages(in messages: [MessageRecord]) -> [MessageSenderBlock] {
        guard !messages.isEmpty else { return [] }

        var blocks: [MessageSenderBlock] = []
        var currentMessages: [MessageRecord] = []
        var currentStartIndex = 0
        var currentSenderKey = ""
        var currentSenderDisplayValue = ""

        for (index, message) in messages.enumerated() {
            let senderDisplayValue = senderDisplayValue(for: message)
            let senderKey = senderBlockKey(for: message)

            if currentMessages.isEmpty {
                currentMessages = [message]
                currentStartIndex = index
                currentSenderKey = senderKey
                currentSenderDisplayValue = senderDisplayValue
                continue
            }

            if senderKey == currentSenderKey {
                currentMessages.append(message)
                continue
            }

            blocks.append(
                MessageSenderBlock(
                    id: currentMessages[0].id,
                    messages: currentMessages,
                    startIndex: currentStartIndex,
                    senderDisplayValue: currentSenderDisplayValue,
                    isOutgoing: currentMessages[0].isOutgoing
                )
            )
            currentMessages = [message]
            currentStartIndex = index
            currentSenderKey = senderKey
            currentSenderDisplayValue = senderDisplayValue
        }

        if !currentMessages.isEmpty {
            blocks.append(
                MessageSenderBlock(
                    id: currentMessages[0].id,
                    messages: currentMessages,
                    startIndex: currentStartIndex,
                    senderDisplayValue: currentSenderDisplayValue,
                    isOutgoing: currentMessages[0].isOutgoing
                )
            )
        }

        return blocks
    }

    private var displayedThreadTitle: String {
        let dedupedTitle = otherParticipants.map(\.displayName).joined(separator: ", ").trimmed
        if let dedupedTitle = dedupedTitle.nilIfBlank {
            return dedupedTitle
        }

        return contactsResolver.title(rawTitle: thread.title, participantNames: thread.participants.map(\.displayName))
    }

    private var avatarParticipants: [AvatarView.Participant] {
        otherParticipants.map {
            AvatarView.Participant(displayName: $0.displayName, handle: $0.handle)
        }
    }

    private var otherParticipants: [ContactDisplayResolver.ResolvedParticipant] {
        contactsResolver.uniqueParticipants(
            from: thread.participants.map(\.displayName),
            excludingYou: true
        )
    }

    private var isGroupChat: Bool {
        otherParticipants.count > 1
    }

    private var displayedGroupParticipantPreview: String? {
        guard isGroupChat else { return nil }

        let visibleNames = otherParticipants.prefix(3).map(\.displayName)
        guard !visibleNames.isEmpty else { return nil }

        let summary = visibleNames.joined(separator: ", ")
        let preview = otherParticipants.count > 3 ? "\(summary), …" : summary
        guard normalizedDisplayPreview(preview) != normalizedDisplayPreview(displayedThreadTitle) else {
            return nil
        }
        return preview
    }

    private func normalizedDisplayPreview(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
    }

    private func senderDisplayValue(for message: MessageRecord) -> String {
        if message.isOutgoing {
            return "You"
        }

        return message.senderDisplayName.trimmed.nilIfBlank
            ?? message.senderID.trimmed.nilIfBlank
            ?? "Unknown"
    }

    private func senderBlockKey(for message: MessageRecord) -> String {
        if message.isOutgoing {
            return "you"
        }

        if let senderID = message.senderID.trimmed.nilIfBlank {
            return senderID
        }

        let senderDisplayValue = senderDisplayValue(for: message)
        return contactsResolver.canonicalContactKey(for: senderDisplayValue).nilIfBlank ?? senderDisplayValue.lowercased()
    }

    private func sourceHandle(for message: MessageRecord) -> String? {
        guard let metadataJSON = message.metadataJSON,
              let data = metadataJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let handle = object["sender_handle"] as? String
        else {
            return nil
        }
        return handle.trimmed.nilIfBlank
    }

    private var searchResultsLabel: String {
        let resultCount = viewModel.threadSearchResults.count
        let currentPosition = min(viewModel.currentSearchResultIndex + 1, resultCount)
        if viewModel.threadSearchResults.count == 250 {
            return "\(currentPosition) of 250+ matches"
        }
        return "\(currentPosition) of \(resultCount.formatted(.number)) matches"
    }

    private func scrollTranscript(with proxy: ScrollViewProxy, request: MessageScrollRequest, ignoreStaleRequests: Bool) {
        switch request.target {
        case .day(let date):
            scrollToDay(date, with: proxy, animated: request.animated, requestID: request.id, ignoreStaleRequests: ignoreStaleRequests)
        case .message(let messageID):
            scrollToMessage(messageID, with: proxy, animated: request.animated, requestID: request.id, ignoreStaleRequests: ignoreStaleRequests)
        }
    }

    private func scrollToDay(_ date: Date, with proxy: ScrollViewProxy, animated: Bool, requestID: UUID, ignoreStaleRequests: Bool) {
        let anchorID = dayAnchorID(for: date)
        performScroll(with: proxy, target: anchorID, anchor: .top, animated: animated, delay: 0, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
        performScroll(with: proxy, target: anchorID, anchor: .top, animated: animated, delay: 0.08, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
    }

    private func scrollToMessage(_ messageID: String, with proxy: ScrollViewProxy, animated: Bool, requestID: UUID, ignoreStaleRequests: Bool) {
        if let day = thread.day(containingMessageID: messageID) {
            let dayAnchor = dayAnchorID(for: day)
            performScroll(with: proxy, target: dayAnchor, anchor: .top, animated: false, delay: 0, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
            performScroll(with: proxy, target: dayAnchor, anchor: .top, animated: false, delay: 0.05, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
        }

        let messageTarget = TranscriptScrollTarget.message(messageID)
        performScroll(with: proxy, target: messageTarget, anchor: .center, animated: animated, delay: 0.1, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
        performScroll(with: proxy, target: messageTarget, anchor: .center, animated: animated, delay: 0.22, requestID: requestID, ignoreStaleRequests: ignoreStaleRequests)
    }

    private func performScroll<T: Hashable>(
        with proxy: ScrollViewProxy,
        target: T,
        anchor: UnitPoint,
        animated: Bool,
        delay: TimeInterval,
        requestID: UUID,
        ignoreStaleRequests: Bool
    ) {
        let action = {
            if ignoreStaleRequests, viewModel.scrollRequest?.id != requestID {
                return
            }

            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(target, anchor: anchor)
                }
            } else {
                proxy.scrollTo(target, anchor: anchor)
            }
        }

        if delay == 0 {
            DispatchQueue.main.async {
                action()
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                action()
            }
        }
    }

    private func dayAnchorID(for date: Date) -> String {
        let normalizedDate = Calendar.current.startOfDay(for: date)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: normalizedDate)
        return String(format: "day-%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}

private struct DayRibbon: View {
    let date: Date

    var body: some View {
        Text(AppFormatters.transcriptDayHeader.string(from: date))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }
}

private struct MessageSenderBlock: Identifiable {
    let id: String
    let messages: [MessageRecord]
    let startIndex: Int
    let senderDisplayValue: String
    let isOutgoing: Bool
}

private struct MessageBubbleView: View {
    let message: MessageRecord
    let searchQuery: String
    let showsSenderLabel: Bool
    let isFocused: Bool
    let resolvedSenderName: String
    let isGroupChat: Bool
    let showsAvatar: Bool
    let isLastInRun: Bool
    let maxBubbleWidth: CGFloat
    let senderHandle: String
    let sourceHandle: String?
    @ObservedObject var resolver: ContactDisplayResolver

    private var bubbleBackground: Color {
        message.isOutgoing
            ? Color(nsColor: .systemBlue)
            : Color(nsColor: .secondarySystemBackground)
    }

    private var cornerRadius: CGFloat { 17 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if !message.isOutgoing {
                avatarSlot
                    .padding(.top, showsSenderLabel ? 16 : 0)
            }

            VStack(alignment: message.isOutgoing ? .trailing : .leading, spacing: 4) {
                if showsSenderLabel {
                    Text(resolvedSenderName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                bubbleContent
                    .background(
                        bubbleBackground,
                        in: ChatBubbleShape(
                            isOutgoing: message.isOutgoing,
                            radius: cornerRadius,
                            isLastInRun: isLastInRun
                        )
                    )
                    .overlay {
                        if isFocused {
                            ChatBubbleShape(
                                isOutgoing: message.isOutgoing,
                                radius: cornerRadius,
                                isLastInRun: isLastInRun
                            )
                                .stroke(Color.accentColor.opacity(0.55), lineWidth: 2)
                        }
                    }

                Text(AppFormatters.preciseMessageTime.string(from: message.timestamp))
                    .font(.system(size: 10, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .accessibilityLabel("Message sent \(AppFormatters.preciseMessageTimestamp.string(from: message.timestamp))")

                if let sourceHandle, !message.isOutgoing {
                    Text("via \(ContactDisplayResolver.prettifyHandle(sourceHandle))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 12)
                }
            }

            if !message.isOutgoing {
                Spacer(minLength: 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isOutgoing ? .trailing : .leading)
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var avatarSlot: some View {
        if isGroupChat {
            if showsAvatar {
                AvatarView(
                    participants: [AvatarView.Participant(displayName: resolvedSenderName, handle: senderHandle)],
                    size: 28,
                    resolver: resolver
                )
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
        }
    }

    private var bubbleContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !message.bodyText.trimmed.isEmpty {
                HighlightedMessageTextView(
                    text: message.bodyText,
                    query: searchQuery,
                    isOutgoing: message.isOutgoing
                )
            }

            if !message.attachments.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.attachments) { attachment in
                        AttachmentCardView(attachment: attachment, compact: false)
                    }
                }
            }

            if !message.reactions.isEmpty {
                Text(message.reactions.map(\.emoji).joined(separator: " "))
                    .font(.system(size: 13))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .foregroundStyle(message.isOutgoing ? Color.white : .primary)
    }
}

/// iMessage-style bubble shape — a rounded rectangle with the "tail" corner
/// (bottom-right for outgoing, bottom-left for incoming) squared off slightly
/// to hint at the tail direction, matching Messages.app's visual grammar.
private struct ChatBubbleShape: Shape {
    let isOutgoing: Bool
    let radius: CGFloat
    let isLastInRun: Bool

    func path(in rect: CGRect) -> Path {
        let tailRadius: CGFloat = 4
        let tl: CGFloat = radius
        let tr: CGFloat = radius
        let br: CGFloat = isOutgoing && isLastInRun ? tailRadius : radius
        let bl: CGFloat = !isOutgoing && isLastInRun ? tailRadius : radius
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
            path.addArc(center: CGPoint(x: rect.maxX - tr, y: rect.minY + tr), radius: tr, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
            path.addArc(center: CGPoint(x: rect.maxX - br, y: rect.maxY - br), radius: br, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
            path.addArc(center: CGPoint(x: rect.minX + bl, y: rect.maxY - bl), radius: bl, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
            path.addArc(center: CGPoint(x: rect.minX + tl, y: rect.minY + tl), radius: tl, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            path.closeSubpath()
        }
    }
}

private extension NSColor {
    /// AppKit doesn't expose UIKit's semantic `secondarySystemBackground`, so mirror it
    /// with a slightly lifted control background that stays distinct from the window.
    static var secondarySystemBackground: NSColor {
        controlBackgroundColor.highlight(withLevel: 0.14) ?? controlBackgroundColor
    }
}

private struct HighlightedMessageTextView: View {
    let text: String
    let query: String
    let isOutgoing: Bool

    var body: some View {
        Text(attributedText)
            .font(.system(size: 14))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributedText: AttributedString {
        let segments = TextSegmentBuilder.segments(for: text, query: query)
        var result = AttributedString()

        for segment in segments {
            var piece = AttributedString(segment.text)
            piece.foregroundColor = segment.isLink
                ? (isOutgoing ? Color.white.opacity(0.96) : Color.blue)
                : (isOutgoing ? Color.white : Color.primary)
            if segment.isLink {
                piece.underlineStyle = .single
            }
            if segment.isHighlighted {
                piece.backgroundColor = isOutgoing ? Color.white.opacity(0.2) : Color.yellow.opacity(0.35)
            }
            result.append(piece)
        }
        return result
    }
}

private struct AttachmentCardView: View {
    let attachment: AttachmentRecord
    let compact: Bool

    var body: some View {
        Group {
            if let action = attachmentAction {
                Button {
                    performAttachmentAction(action)
                } label: {
                    cardContent
                }
                .buttonStyle(.plain)
                .help(action.helpText)
            } else {
                cardContent
            }
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 6) {
            if let fileURL = localAttachmentURL {
                AttachmentThumbnailView(
                    fileURL: fileURL,
                    attachmentType: attachment.type,
                    compact: compact
                )
            }

            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(.secondary)
                Text(attachment.filename)
                    .font(.system(size: compact ? 11 : 12, weight: .medium))
                    .lineLimit(compact ? 1 : 2)

                Spacer(minLength: 8)

                if let action = attachmentAction {
                    Image(systemName: action.systemImageName)
                        .font(.system(size: compact ? 10 : 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Text(attachmentSubtitle)
                .font(.system(size: compact ? 10 : 11))
                .foregroundStyle(.secondary)

            if let urlString = attachment.url, URL(string: urlString) != nil {
                Text(urlString)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let localPath = attachment.localPath {
                Text((localPath as NSString).expandingTildeInPath)
                    .font(.system(size: compact ? 10 : 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(compact ? 0.18 : 0.16), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var attachmentAction: AttachmentAction? {
        if let fileURL = localAttachmentURL {
            if isPluginPayloadAttachment(fileURL: fileURL) {
                return .reveal(fileURL)
            }
            return .open(fileURL)
        }

        if let urlString = attachment.url?.trimmed.nilIfBlank {
            if let url = URL(string: urlString) {
                return .open(url)
            }
        }

        return nil
    }

    private var attachmentSubtitle: String {
        if attachmentAction == nil {
            return "Original attachment isn’t available on this Mac"
        }

        if let fileURL = localAttachmentURL {
            if isPluginPayloadAttachment(fileURL: fileURL) {
                return "Messages attachment package"
            }
        }

        return attachment.type.displayName
    }

    private func performAttachmentAction(_ action: AttachmentAction) {
        switch action {
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func isPluginPayloadAttachment(fileURL: URL) -> Bool {
        let fileName = fileURL.lastPathComponent.lowercased()
        return fileName.contains("pluginpayloadattachment") || fileURL.pathExtension.lowercased() == "pluginpayloadattachment"
    }

    private var localAttachmentURL: URL? {
        guard let localPath = attachment.localPath?.trimmed.nilIfBlank else {
            return nil
        }

        let expandedPath = (localPath as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expandedPath) else {
            return nil
        }

        return URL(fileURLWithPath: expandedPath)
    }

    private var iconName: String {
        switch attachment.type {
        case .image:
            return "photo"
        case .video:
            return "video"
        case .audio:
            return "waveform"
        case .file:
            return "doc"
        case .link:
            return "link"
        case .unknown:
            return "paperclip"
        }
    }
}

private struct AttachmentThumbnailView: View {
    let fileURL: URL
    let attachmentType: AttachmentKind
    let compact: Bool

    @StateObject private var loader = AttachmentThumbnailLoader()

    private var thumbnailSize: CGSize {
        compact ? CGSize(width: 144, height: 96) : CGSize(width: 292, height: 196)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.14))

            if let image = loader.image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipped()
            } else if loader.didFail {
                Image(systemName: fallbackIconName)
                    .font(.system(size: compact ? 26 : 34, weight: .regular))
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(compact ? .small : .regular)
            }

            if attachmentType == .video {
                Image(systemName: "play.fill")
                    .font(.system(size: compact ? 16 : 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(compact ? 8 : 11)
                    .background(Color.black.opacity(0.45), in: Circle())
            }
        }
        .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 1)
        )
        .task(id: fileURL.path) {
            loader.load(fileURL: fileURL, size: thumbnailSize)
        }
    }

    private var fallbackIconName: String {
        switch attachmentType {
        case .image:
            return "photo"
        case .video:
            return "video"
        case .audio:
            return "waveform"
        case .file:
            return "doc"
        case .link:
            return "link"
        case .unknown:
            return "paperclip"
        }
    }
}

@MainActor
private final class AttachmentThumbnailLoader: ObservableObject {
    @Published var image: NSImage?
    @Published var didFail = false

    private var loadedPath: String?

    func load(fileURL: URL, size: CGSize) {
        guard loadedPath != fileURL.path else {
            return
        }

        loadedPath = fileURL.path
        image = nil
        didFail = false

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: [.thumbnail, .icon]
        )

        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let generatedImage = representation?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                if let generatedImage {
                    self.image = generatedImage
                    self.didFail = false
                } else {
                    self.didFail = true
                }
            }
        }
    }
}

private enum AttachmentAction {
    case open(URL)
    case reveal(URL)

    var systemImageName: String {
        switch self {
        case .open:
            return "arrow.up.forward"
        case .reveal:
            return "folder"
        }
    }

    var helpText: String {
        switch self {
        case .open(let url):
            return url.isFileURL ? "Open attachment" : "Open link"
        case .reveal:
            return "Reveal in Finder"
        }
    }
}
