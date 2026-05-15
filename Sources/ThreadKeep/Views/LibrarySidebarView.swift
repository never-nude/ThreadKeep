import SwiftUI

struct LibrarySidebarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @AppStorage("threadkeep.import.useContactsNames") private var useContactsNames = true
    @AppStorage("threadkeep.library.sortOption") private var librarySortOptionRawValue = LibraryThreadSortOption.mostRecent.rawValue
    @StateObject private var contactsResolver = ContactDisplayResolver()

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: max(26, proxy.safeAreaInsets.top + 8))
                sidebarControls
                Divider()
                threadList
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationSplitViewColumnWidth(min: 310, ideal: 360, max: 420)
        .task(id: useContactsNames) {
            await contactsResolver.refresh(enabled: useContactsNames)
        }
        .onReceive(NotificationCenter.default.publisher(for: .threadKeepContactsAccessDidChange)) { _ in
            Task {
                await contactsResolver.refresh(enabled: useContactsNames)
            }
        }
    }

    private var sidebarControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conversations")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
            }

            TextField("Search conversations", text: librarySearchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    viewModel.scheduleLibrarySearch(delay: .zero)
                }

            HStack(alignment: .center) {
                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Picker("Sort", selection: librarySortOption) {
                    ForEach(LibraryThreadSortOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var threadList: some View {
        Group {
            if viewModel.threads.isEmpty {
                VStack(spacing: 12) {
                    ContentUnavailableView(
                        "Your Messages Library",
                        systemImage: "text.bubble",
                        description: Text("Import Messages from this Mac to see your conversations here.")
                    )

                    Button {
                        NotificationCenter.default.post(name: .threadKeepRequestImport, object: nil)
                    } label: {
                        Label("Import Messages", systemImage: "tray.and.arrow.down.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !viewModel.librarySearchQuery.trimmed.isEmpty {
                librarySearchResults
            } else {
                List {
                    ForEach(sortedThreads) { thread in
                        Button {
                            viewModel.selectThread(thread.id)
                        } label: {
                            ThreadRowView(thread: thread, contactsResolver: contactsResolver)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                        .listRowBackground(
                            thread.id == viewModel.selectedThreadID
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear
                        )
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .onExitCommand {
            viewModel.clearLibrarySearch()
        }
    }

    private var librarySearchResults: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(librarySearchSummaryText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

            if viewModel.librarySearchResults.isEmpty {
                ContentUnavailableView(
                    "No Conversations Found",
                    systemImage: "magnifyingglass",
                    description: Text("Try a different name, number, or date.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.librarySearchResults) { result in
                        Button {
                            viewModel.openLibrarySearchResult(result)
                        } label: {
                            LibrarySearchResultRowView(
                                result: result,
                                query: viewModel.librarySearchQuery,
                                contactsResolver: contactsResolver
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 8))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var librarySearchSummaryText: String {
        let resultCount = viewModel.librarySearchResults.count
        let conversationCount = viewModel.librarySearchConversationCount
        if resultCount == 0 {
            return "No matches"
        }
        let resultWord = resultCount == 1 ? "result" : "results"
        let conversationWord = conversationCount == 1 ? "conversation" : "conversations"
        return "\(resultCount.formatted(.number)) \(resultWord) across \(conversationCount.formatted(.number)) \(conversationWord)"
    }

    private var librarySortOption: Binding<LibraryThreadSortOption> {
        Binding(
            get: { LibraryThreadSortOption(rawValue: librarySortOptionRawValue) ?? .mostRecent },
            set: { librarySortOptionRawValue = $0.rawValue }
        )
    }

    private var sortedThreads: [ThreadSummary] {
        let option = LibraryThreadSortOption(rawValue: librarySortOptionRawValue) ?? .mostRecent
        return viewModel.threads.sorted { lhs, rhs in
            compare(lhs, rhs, using: option)
        }
    }

    private func compare(_ lhs: ThreadSummary, _ rhs: ThreadSummary, using option: LibraryThreadSortOption) -> Bool {
        switch option {
        case .mostRecent:
            return compareDatesDescending(lhs.sortEndDate, rhs.sortEndDate, lhs: lhs, rhs: rhs)
        case .oldestFirst:
            return compareDatesAscending(lhs.sortEndDate, rhs.sortEndDate, lhs: lhs, rhs: rhs)
        case .nameAZ:
            return compareStringsAscending(displayTitle(for: lhs), displayTitle(for: rhs), lhs: lhs, rhs: rhs)
        case .nameZA:
            return compareStringsDescending(displayTitle(for: lhs), displayTitle(for: rhs), lhs: lhs, rhs: rhs)
        case .numberHandle:
            return compareStringsAscending(handleSortKey(for: lhs), handleSortKey(for: rhs), lhs: lhs, rhs: rhs)
        case .mostMessages:
            if lhs.messageCount != rhs.messageCount {
                return lhs.messageCount > rhs.messageCount
            }
            return compareDatesDescending(lhs.sortEndDate, rhs.sortEndDate, lhs: lhs, rhs: rhs)
        }
    }

    private func displayTitle(for thread: ThreadSummary) -> String {
        let participants = displayParticipants(for: thread)
        let dedupedTitle = participants.map(\.displayName).joined(separator: ", ").trimmed
        if let dedupedTitle = dedupedTitle.nilIfBlank {
            return dedupedTitle
        }

        return contactsResolver.title(rawTitle: thread.title, participantNames: thread.participantNames)
    }

    private func handleSortKey(for thread: ThreadSummary) -> String {
        let participants = displayParticipants(for: thread)
        let participantHandles = participants.map(\.handle)
        return contactsResolver.primaryHandle(
            rawTitle: thread.title,
            participantNames: participantHandles.isEmpty ? thread.participantNames : participantHandles
        )
    }

    private func compareDatesDescending(_ lhsDate: Date?, _ rhsDate: Date?, lhs: ThreadSummary, rhs: ThreadSummary) -> Bool {
        let lhsValue = lhsDate ?? .distantPast
        let rhsValue = rhsDate ?? .distantPast
        if lhsValue != rhsValue {
            return lhsValue > rhsValue
        }
        return compareStringsAscending(displayTitle(for: lhs), displayTitle(for: rhs), lhs: lhs, rhs: rhs)
    }

    private func compareDatesAscending(_ lhsDate: Date?, _ rhsDate: Date?, lhs: ThreadSummary, rhs: ThreadSummary) -> Bool {
        let lhsValue = lhsDate ?? .distantFuture
        let rhsValue = rhsDate ?? .distantFuture
        if lhsValue != rhsValue {
            return lhsValue < rhsValue
        }
        return compareStringsAscending(displayTitle(for: lhs), displayTitle(for: rhs), lhs: lhs, rhs: rhs)
    }

    private func compareStringsAscending(_ lhsValue: String, _ rhsValue: String, lhs: ThreadSummary, rhs: ThreadSummary) -> Bool {
        let comparison = lhsValue.localizedCaseInsensitiveCompare(rhsValue)
        if comparison != .orderedSame {
            return comparison == .orderedAscending
        }
        return lhs.id < rhs.id
    }

    private func compareStringsDescending(_ lhsValue: String, _ rhsValue: String, lhs: ThreadSummary, rhs: ThreadSummary) -> Bool {
        let comparison = lhsValue.localizedCaseInsensitiveCompare(rhsValue)
        if comparison != .orderedSame {
            return comparison == .orderedDescending
        }
        return lhs.id < rhs.id
    }

    private func displayParticipants(for thread: ThreadSummary) -> [ContactDisplayResolver.ResolvedParticipant] {
        contactsResolver.uniqueParticipants(from: thread.participantNames, excludingYou: true)
    }
}

private struct ThreadRowView: View {
    let thread: ThreadSummary
    @ObservedObject var contactsResolver: ContactDisplayResolver

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(participants: avatarParticipants, size: 42, resolver: contactsResolver)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    if let latestTimestamp = thread.latestMessageTimestamp ?? thread.sortEndDate {
                        Text(AppFormatters.sidebarTimestamp(for: latestTimestamp))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(previewText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 9)
        .frame(minHeight: 64, alignment: .leading)
    }

    private var avatarParticipants: [AvatarView.Participant] {
        participants.map {
            AvatarView.Participant(displayName: $0.displayName, handle: $0.handle)
        }
    }

    private var participants: [ContactDisplayResolver.ResolvedParticipant] {
        contactsResolver.uniqueParticipants(from: thread.participantNames, excludingYou: true)
    }

    private var isGroupConversation: Bool {
        participants.count > 1
    }

    private var displayTitle: String {
        let dedupedTitle = participants.map(\.displayName).joined(separator: ", ").trimmed
        if let dedupedTitle = dedupedTitle.nilIfBlank {
            return dedupedTitle
        }

        return contactsResolver.title(rawTitle: thread.title, participantNames: thread.participantNames)
    }

    private var previewText: String {
        let basePreview = thread.latestMessageText?.trimmed.nilIfBlank
            ?? (thread.hasAttachments ? "Attachment" : "No preview available")
        return previewPrefix + basePreview
    }

    private var previewPrefix: String {
        if thread.latestMessageIsOutgoing {
            return "You: "
        }

        guard isGroupConversation,
              let sender = thread.latestSenderDisplayName?.trimmed.nilIfBlank
        else {
            return ""
        }

        let resolvedSender = contactsResolver.resolvedName(for: sender)
        let firstName = resolvedSender
            .split(separator: " ")
            .first
            .map(String.init)?
            .nilIfBlank
            ?? resolvedSender
        return "\(firstName): "
    }
}

private extension LibrarySidebarView {
    var librarySearchQuery: Binding<String> {
        Binding(
            get: { viewModel.librarySearchQuery },
            set: { newValue in
                viewModel.librarySearchQuery = newValue
                viewModel.scheduleLibrarySearch()
            }
        )
    }
}

private struct LibrarySearchResultRowView: View {
    let result: LibrarySearchResult
    let query: String
    @ObservedObject var contactsResolver: ContactDisplayResolver

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            AvatarView(participants: avatarParticipants, size: 38, resolver: contactsResolver)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 6)

                    Text(AppFormatters.sidebarTimestamp(for: result.timestamp))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(snippetText)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                Text("in conversation with \(displayTitle)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .frame(minHeight: 70, alignment: .leading)
    }

    private var avatarParticipants: [AvatarView.Participant] {
        participants.map {
            AvatarView.Participant(displayName: $0.displayName, handle: $0.handle)
        }
    }

    private var participants: [ContactDisplayResolver.ResolvedParticipant] {
        contactsResolver.uniqueParticipants(from: result.participantNames, excludingYou: true)
    }

    private var displayTitle: String {
        let participantTitle = participants.map(\.displayName).joined(separator: ", ").trimmed
        if let participantTitle = participantTitle.nilIfBlank {
            return participantTitle
        }
        return contactsResolver.title(rawTitle: result.threadTitle, participantNames: result.participantNames)
    }

    private var snippetText: AttributedString {
        let segments = TextSegmentBuilder.segments(for: result.snippet, query: query)
        var output = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            if segment.isHighlighted {
                piece.backgroundColor = Color.yellow.opacity(0.35)
                piece.foregroundColor = Color.primary
            }
            output.append(piece)
        }
        return output
    }
}

private extension ThreadSummary {
    var sortEndDate: Date? {
        endDate ?? startDate ?? importedAt
    }
}
