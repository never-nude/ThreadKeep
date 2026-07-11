@preconcurrency import Contacts
import Foundation
import SwiftUI

private actor ContactAccessRequestCoordinator {
    static let shared = ContactAccessRequestCoordinator()

    private var inFlightRequest: Task<MessagesContactAccessState, Never>?

    func requestIfNeeded(enabled: Bool) async -> MessagesContactAccessState {
        if let inFlightRequest {
            return await inFlightRequest.value
        }

        let request = Task {
            await MessagesStoreImporter.requestContactAccessIfNeeded(enabled: enabled)
        }
        inFlightRequest = request
        let result = await request.value
        inFlightRequest = nil
        return result
    }
}

@MainActor
final class ContactDisplayResolver: ObservableObject {
    struct DisplayEntry {
        let key: String
        let title: String
        let label: String
    }

    struct ResolvedParticipant: Hashable {
        let canonicalKey: String
        let displayName: String
        let label: String
        let handle: String
        let hasImage: Bool
    }

    @Published private var phoneIndex: [String: String] = [:]
    @Published private var emailIndex: [String: String] = [:]
    @Published private var contactIdentifierIndex: [String: String] = [:]
    @Published private var imageIndex: [String: Data] = [:]
    @Published private(set) var isReady = false
    private var entryCache: [String: DisplayEntry] = [:]

    init(
        phoneIndex: [String: String] = [:],
        emailIndex: [String: String] = [:],
        contactIdentifierIndex: [String: String] = [:],
        imageIndex: [String: Data] = [:],
        isReady: Bool = false
    ) {
        _phoneIndex = Published(initialValue: phoneIndex)
        _emailIndex = Published(initialValue: emailIndex)
        _contactIdentifierIndex = Published(initialValue: contactIdentifierIndex)
        _imageIndex = Published(initialValue: imageIndex)
        _isReady = Published(initialValue: isReady)
    }

    func refresh(enabled: Bool, requestAccessIfNeeded: Bool = true) async {
        var accessState = MessagesStoreImporter.currentContactAccessState(enabled: enabled)
        if accessState == .notDetermined && requestAccessIfNeeded {
            accessState = await ContactAccessRequestCoordinator.shared.requestIfNeeded(enabled: enabled)
            NotificationCenter.default.post(name: .threadKeepContactsAccessDidChange, object: accessState)
        }

        guard accessState == .authorized else {
            if !phoneIndex.isEmpty || !emailIndex.isEmpty {
                phoneIndex = [:]
                emailIndex = [:]
                contactIdentifierIndex = [:]
                imageIndex = [:]
            }
            entryCache.removeAll()
            isReady = true
            return
        }

        isReady = false
        let (phoneIndex, emailIndex, idIndex, imageIndex) = await Self.loadContactIndexes()
        self.phoneIndex = phoneIndex
        self.emailIndex = emailIndex
        self.contactIdentifierIndex = idIndex
        self.imageIndex = imageIndex
        entryCache.removeAll()
        isReady = true
    }

    /// Contact image bytes (typically JPEG/PNG) for a handle, if present in Contacts.
    func imageData(for identifier: String) -> Data? {
        let base = baseIdentifier(from: identifier)
        if let imageData = imageIndex[base] {
            return imageData
        }
        if base.contains("@") {
            return imageIndex[Self.normalizedEmail(base)]
        }
        for key in Self.phoneLookupKeys(for: base) {
            if let data = imageIndex[key] {
                return data
            }
        }
        return nil
    }

    func hasImage(for identifier: String) -> Bool {
        imageData(for: identifier) != nil
    }

    func title(rawTitle: String, participantNames: [String]) -> String {
        let rawTitle = rawTitle.trimmed
        let otherEntries = uniqueEntries(from: participantNames.filter { !Self.isYou($0) })
        let rawEntries = uniqueEntries(from: splitIdentifiers(rawTitle))

        if !otherEntries.isEmpty {
            let rawKeys = Set(rawEntries.map(\.key))
            let otherKeys = Set(otherEntries.map(\.key))

            if shouldReplaceTitle(rawTitle, participantNames: participantNames)
                || rawKeys == otherKeys
                || (otherEntries.count == 1 && rawTitle.contains("("))
            {
                let participantTitle = otherEntries.map(\.title).joined(separator: ", ")
                if let participantTitle = participantTitle.nilIfBlank {
                    return participantTitle
                }
            }
        }

        if let resolvedTitle = uniqueEntries(from: [rawTitle]).first?.title.nilIfBlank {
            return resolvedTitle
        }

        let otherTitles = otherEntries.map(\.title).joined(separator: ", ")
        if let participantTitle = otherTitles.nilIfBlank {
            return participantTitle
        }

        return rawTitle
    }

    func participantSummary(for participantNames: [String]) -> String {
        uniqueParticipants(from: participantNames).map(\.label).joined(separator: ", ")
    }

    func displayLabel(for identifier: String) -> String {
        displayEntry(for: identifier).label
    }

    /// Resolved display name for a single handle/identifier (e.g. a message sender).
    /// Falls back to a prettified phone number when no contact matches.
    func resolvedName(for identifier: String) -> String {
        displayEntry(for: identifier).title
    }

    /// All candidate contact identifiers (CNContact.identifier) for a participant handle.
    /// Used by avatar lookup to fetch imageData.
    func contactIdentifiers(for identifier: String) -> [String] {
        let base = baseIdentifier(from: identifier)
        var ids: [String] = []
        if base.contains("@") {
            if let id = contactIdentifierIndex[Self.normalizedEmail(base)] {
                ids.append(id)
            }
        } else {
            for key in Self.phoneLookupKeys(for: base) {
                if let id = contactIdentifierIndex[key] {
                    ids.append(id)
                }
            }
        }
        return ids
    }

    func canonicalContactKey(for handle: String) -> String {
        let base = baseIdentifier(from: handle).trimmed
        guard let normalizedHandle = base.nilIfBlank else {
            return ""
        }

        if Self.isYou(normalizedHandle) {
            return "you"
        }

        if let identifier = contactIdentifier(for: normalizedHandle) {
            return "contact:\(identifier)"
        }

        return "handle:\(normalizedHandleKey(normalizedHandle))"
    }

    func uniqueParticipants(from handles: [String], excludingYou: Bool = false) -> [ResolvedParticipant] {
        var ordered: [ResolvedParticipant] = []
        var indexByCanonicalKey: [String: Int] = [:]

        for handle in handles {
            let trimmedHandle = handle.trimmed
            if excludingYou && Self.isYou(trimmedHandle) {
                continue
            }

            let entry = displayEntry(for: handle)
            let canonicalKey = entry.key.nilIfBlank ?? canonicalContactKey(for: handle)
            guard let canonicalKey = canonicalKey.nilIfBlank else { continue }

            let candidate = ResolvedParticipant(
                canonicalKey: canonicalKey,
                displayName: entry.title,
                label: entry.label,
                handle: handle,
                hasImage: hasImage(for: handle)
            )

            if let existingIndex = indexByCanonicalKey[canonicalKey] {
                if !ordered[existingIndex].hasImage && candidate.hasImage {
                    ordered[existingIndex] = candidate
                }
                continue
            }

            indexByCanonicalKey[canonicalKey] = ordered.count
            ordered.append(candidate)
        }

        return ordered
    }

    func primaryHandle(rawTitle: String, participantNames: [String]) -> String {
        let participantCandidates = participantNames
            .filter { !Self.isYou($0) }
            .map(baseIdentifier(from:))
            .map(\.trimmed)
            .filter { !$0.isEmpty }

        if let first = participantCandidates.first {
            return canonicalIdentifierKey(for: first)
        }

        let titleCandidates = splitIdentifiers(rawTitle)
            .filter { !Self.isYou($0) }
            .map(baseIdentifier(from:))
            .map(\.trimmed)
            .filter { !$0.isEmpty }

        if let first = titleCandidates.first {
            return canonicalIdentifierKey(for: first)
        }

        return canonicalIdentifierKey(for: rawTitle)
    }

    private func shouldReplaceTitle(_ title: String, participantNames: [String]) -> Bool {
        guard let trimmedTitle = title.nilIfBlank else {
            return true
        }

        if trimmedTitle.localizedCaseInsensitiveCompare("Untitled Thread") == .orderedSame {
            return true
        }

        if Self.looksLikeHandleList(trimmedTitle) {
            return true
        }

        let normalizedTitle = Self.normalizedSequence(trimmedTitle)
        let allParticipants = Self.normalizedSequence(participantNames.joined(separator: ", "))
        let otherParticipants = Self.normalizedSequence(
            participantNames
                .filter { !Self.isYou($0) }
                .joined(separator: ", ")
        )

        return normalizedTitle == allParticipants || normalizedTitle == otherParticipants
    }

    private func contactName(for identifier: String) -> String? {
        if identifier.contains("@") {
            return emailIndex[Self.normalizedEmail(identifier)]
        }

        for key in Self.phoneLookupKeys(for: identifier) {
            if let name = phoneIndex[key] {
                return name
            }
        }

        return nil
    }

    private func contactIdentifier(for handle: String) -> String? {
        if handle.contains("@") {
            return contactIdentifierIndex[Self.normalizedEmail(handle)]
        }

        for key in Self.phoneLookupKeys(for: handle) {
            if let identifier = contactIdentifierIndex[key] {
                return identifier
            }
        }

        return nil
    }

    private func uniqueEntries(from values: [String]) -> [DisplayEntry] {
        var seen: Set<String> = []
        var ordered: [DisplayEntry] = []

        for value in values {
            let entry = displayEntry(for: value)
            guard !entry.key.isEmpty, !seen.contains(entry.key) else { continue }
            seen.insert(entry.key)
            ordered.append(entry)
        }

        return ordered
    }

    private func displayEntry(for identifier: String) -> DisplayEntry {
        if let cached = entryCache[identifier] {
            return cached
        }

        let entry = computeDisplayEntry(for: identifier)
        entryCache[identifier] = entry
        return entry
    }

    private func computeDisplayEntry(for identifier: String) -> DisplayEntry {
        let trimmedIdentifier = identifier.trimmed
        guard let normalizedIdentifier = trimmedIdentifier.nilIfBlank else {
            return DisplayEntry(key: "", title: identifier, label: identifier)
        }

        guard !Self.isYou(normalizedIdentifier) else {
            return DisplayEntry(key: "you", title: "You", label: "You")
        }

        let baseIdentifier = baseIdentifier(from: normalizedIdentifier)
        let existingName = decoratedName(from: normalizedIdentifier)
        let resolvedName = existingName ?? contactName(for: baseIdentifier)?.trimmed.nilIfBlank
        let cleanBaseIdentifier = baseIdentifier.trimmed
        let prettyBase = Self.prettifyHandle(cleanBaseIdentifier)
        let canonicalKey = canonicalContactKey(for: cleanBaseIdentifier)

        if let resolvedName, resolvedName.localizedCaseInsensitiveCompare(cleanBaseIdentifier) != .orderedSame {
            return DisplayEntry(
                key: canonicalKey,
                title: resolvedName,
                label: "\(resolvedName) · \(prettyBase)"
            )
        }

        return DisplayEntry(
            key: canonicalKey,
            title: prettyBase,
            label: prettyBase
        )
    }

    /// Recovers the raw handle from a stored participant label ("Name (handle)"
    /// or a bare handle). Static so the read-only suffix-10 audit can parse
    /// stored labels without a resolver instance; instance resolution goes
    /// through the same logic via baseIdentifier(from:).
    nonisolated static func storedHandle(fromParticipantLabel value: String) -> String {
        guard let parsed = parseDecoratedLabel(value) else {
            return value.trimmed
        }

        let innerBase = storedHandle(fromParticipantLabel: parsed.inner)
        if looksLikeHandle(innerBase) || parseDecoratedLabel(innerBase) != nil {
            return innerBase
        }

        return value.trimmed
    }

    private func baseIdentifier(from value: String) -> String {
        Self.storedHandle(fromParticipantLabel: value)
    }

    private func decoratedName(from value: String) -> String? {
        guard let parsed = Self.parseDecoratedLabel(value),
              let name = parsed.name.trimmed.nilIfBlank
        else {
            return nil
        }

        if Self.looksLikeHandle(parsed.inner) || Self.parseDecoratedLabel(parsed.inner) != nil {
            return name
        }

        return nil
    }

    private func splitIdentifiers(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func canonicalIdentifierKey(for value: String) -> String {
        if value.contains("@") {
            return Self.normalizedEmail(value)
        }

        if let firstPhoneKey = Self.phoneLookupKeys(for: value).first {
            return firstPhoneKey
        }

        return value.lowercased()
    }

    // handle: identity uses the same canonical phone form as contact lookup,
    // so notation variants of one number (+1/bare/00-prefixed) share a key
    // whether or not a Contacts card exists. Strictly notation-level — see
    // canonicalPhoneKey for why this cannot equate two different numbers.
    private func normalizedHandleKey(_ value: String) -> String {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return trimmed }

        if trimmed.contains("@") {
            return Self.normalizedEmail(trimmed)
        }

        if let phoneKey = Self.canonicalPhoneKey(for: trimmed) {
            return phoneKey
        }

        return trimmed.lowercased()
    }

    /// Format a raw handle for display when no contact name is available.
    /// Converts E.164 phone numbers like `+19145550623` → `+1 (914) 555-0623`,
    /// and bare 10-digit strings to `(914) 555-0623`. Emails and unknown shapes
    /// pass through unchanged.
    nonisolated static func prettifyHandle(_ value: String) -> String {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return value }
        if trimmed.contains("@") { return trimmed }

        let digits = trimmed.filter(\.isNumber)
        guard !digits.isEmpty else { return trimmed }
        // Only prettify if the input is essentially digits (+ optional leading +, dashes, spaces, parens).
        let allowedSet = CharacterSet(charactersIn: "+0123456789 ()-.")
        if trimmed.rangeOfCharacter(from: allowedSet.inverted) != nil {
            return trimmed
        }

        if digits.count == 10 {
            return "(\(digits.prefix(3))) \(digits.dropFirst(3).prefix(3))-\(digits.suffix(4))"
        }
        if digits.count == 11, digits.hasPrefix("1") {
            let body = digits.dropFirst()
            return "+1 (\(body.prefix(3))) \(body.dropFirst(3).prefix(3))-\(body.suffix(4))"
        }
        if digits.count > 11 {
            // Leave international numbers in E.164-ish form with a leading plus.
            return trimmed.hasPrefix("+") ? trimmed : "+\(digits)"
        }
        return trimmed
    }

    nonisolated private static func loadContactIndexes() async -> ([String: String], [String: String], [String: String], [String: Data]) {
        await Task.detached(priority: .userInitiated) {
            let store = CNContactStore()
            var builder = ContactIndexBuilder()
            let keysToFetch: [CNKeyDescriptor] = [
                CNContactIdentifierKey as CNKeyDescriptor,
                CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
                CNContactNicknameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor,
                CNContactThumbnailImageDataKey as CNKeyDescriptor,
                CNContactImageDataKey as CNKeyDescriptor,
                CNContactImageDataAvailableKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keysToFetch)

            do {
                try store.enumerateContacts(with: request) { contact, _ in
                    guard let displayName = displayName(for: contact).trimmed.nilIfBlank else {
                        return
                    }

                    builder.add(
                        contactIdentifier: contact.identifier,
                        displayName: displayName,
                        phoneNumbers: contact.phoneNumbers.map { $0.value.stringValue },
                        emailAddresses: contact.emailAddresses.map { String($0.value) },
                        image: contact.thumbnailImageData ?? (contact.imageDataAvailable ? contact.imageData : nil)
                    )
                }
            } catch {
                return ([:], [:], [:], [:])
            }

            let indexes = builder.finalize()
            return (indexes.phoneIndex, indexes.emailIndex, indexes.contactIdentifierIndex, indexes.imageIndex)
        }.value
    }

    nonisolated private static func displayName(for contact: CNContact) -> String {
        let nickname = contact.nickname.trimmed.nilIfBlank
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)?.trimmed.nilIfBlank
        let company = contact.organizationName.trimmed.nilIfBlank

        var components: [String] = []

        if let nickname {
            components.append(nickname)
        }

        if let fullName,
           !components.contains(where: { $0.localizedCaseInsensitiveCompare(fullName) == .orderedSame }) {
            components.append(fullName)
        }

        if let company,
           !components.contains(where: { $0.localizedCaseInsensitiveCompare(company) == .orderedSame }) {
            components.append(company)
        }

        return components.joined(separator: " · ")
    }

    nonisolated private static func normalizedEmail(_ email: String) -> String {
        email.trimmed.lowercased()
    }

    nonisolated static func phoneLookupKeys(for value: String) -> [String] {
        guard let key = canonicalPhoneKey(for: value) else {
            return []
        }
        return [key]
    }

    /// Strict phone equivalence: two handles are the same number ONLY when their
    /// canonical forms match. The canonical form applies exactly three rules:
    ///   1. compare digit strings exactly;
    ///   2. international dialing notation: a leading `00` is dropped only when
    ///      at least 11 digits remain, so the result still carries its country
    ///      code (`0044…` == `+44…`) and can never shrink to a bare national
    ///      number that might belong to a different country;
    ///   3. NANP: an 11-digit string is reduced to 10 only when it leads with
    ///      `1` (the NANP country code) — `+1 914…` == `914…`.
    /// Every rule maps notations of the SAME E.164 number onto each other; no
    /// rule deletes a country code. The previous last-10-digits fallback did,
    /// and could merge two different people (a UK `+44 7911 123456` card would
    /// capture a US `791-112-3456` handle). Do not add fuzzier keys — the
    /// mutation tests in ContactDisplayResolverTests pin the exact key sets.
    nonisolated static func canonicalPhoneKey(for value: String) -> String? {
        var digits = value.filter(\.isNumber)
        guard !digits.isEmpty else {
            return nil
        }

        if digits.hasPrefix("00"), digits.count >= 13 {
            digits = String(digits.dropFirst(2))
        }

        if digits.count == 11, digits.hasPrefix("1") {
            digits = String(digits.dropFirst())
        }

        return digits
    }

    nonisolated private static func looksLikeHandleList(_ value: String) -> Bool {
        let components = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !components.isEmpty else { return false }
        return components.allSatisfy(looksLikeHandle(_:))
    }

    nonisolated private static func looksLikeHandle(_ value: String) -> Bool {
        if isYou(value) {
            return true
        }

        if value.contains("@") {
            return true
        }

        return value.filter(\.isNumber).count >= 7
    }

    nonisolated private static func normalizedSequence(_ value: String) -> String {
        value
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
    }

    nonisolated private static func isYou(_ value: String) -> Bool {
        value.trimmed.localizedCaseInsensitiveCompare("You") == .orderedSame
    }

    nonisolated private static func parseDecoratedLabel(_ value: String) -> (name: String, inner: String)? {
        guard let open = value.firstIndex(of: "("),
              let close = value.lastIndex(of: ")"),
              open < close
        else {
            return nil
        }

        let name = value[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let innerStart = value.index(after: open)
        let inner = value[innerStart..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !inner.isEmpty else { return nil }
        return (name, inner)
    }
}
