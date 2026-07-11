import Contacts
import Foundation

/// Read-only blast-radius audit for the removed last-10-digits phone fallback.
///
/// Answers one question about an existing library: how many stored 1:1
/// participant handles resolved to a Contacts card ONLY because of the legacy
/// suffix-10 key — i.e. could have been merged/labeled as the wrong person?
///
/// Run with: ThreadKeep --audit-suffix10 (prints counts to stdout and exits;
/// reads the library and Contacts, writes nothing, transmits nothing).
enum Suffix10Audit {
    struct ContactFixture {
        let identifier: String
        let phoneNumbers: [String]
    }

    struct Result {
        var handlesAudited = 0
        /// Handles whose legacy resolution differed from strict resolution —
        /// each one is a thread that may have carried another person's name.
        var suffixDependentHandles = 0
        var threadsAudited = 0
        var suffixDependentThreads = 0
    }

    /// The REMOVED legacy key scheme, kept verbatim and quarantined here so the
    /// audit can reproduce historical behavior. Never call this from
    /// resolution code — strict equivalence lives in
    /// ContactDisplayResolver.canonicalPhoneKey.
    static func legacyPhoneLookupKeys(for value: String) -> [String] {
        let digits = value.filter(\.isNumber)
        guard !digits.isEmpty else { return [] }

        var keys: [String] = []
        func append(_ candidate: String) {
            guard !candidate.isEmpty, !keys.contains(candidate) else { return }
            keys.append(candidate)
        }

        append(digits)
        if digits.count == 11, digits.hasPrefix("1") {
            append(String(digits.dropFirst()))
        }
        if digits.count > 10 {
            append(String(digits.suffix(10)))
        }
        if digits.hasPrefix("001"), digits.count > 3 {
            append(String(digits.dropFirst(2)))
        }
        return keys
    }

    /// Pure core, fixture-testable: compares legacy vs strict resolution for
    /// every handle of every thread. `threads` is each thread's non-you raw
    /// phone handles (emails are exact-match in both schemes and never differ).
    static func run(threads: [[String]], contacts: [ContactFixture]) -> Result {
        var legacyIndex: [String: String] = [:]
        var strictIndex: [String: String] = [:]
        for contact in contacts {
            for number in contact.phoneNumbers {
                for key in legacyPhoneLookupKeys(for: number) {
                    legacyIndex[key] = legacyIndex[key] ?? contact.identifier
                }
                if let key = ContactDisplayResolver.canonicalPhoneKey(for: number) {
                    strictIndex[key] = strictIndex[key] ?? contact.identifier
                }
            }
        }

        func legacyResolution(_ handle: String) -> String? {
            for key in legacyPhoneLookupKeys(for: handle) {
                if let id = legacyIndex[key] { return id }
            }
            return nil
        }

        func strictResolution(_ handle: String) -> String? {
            guard let key = ContactDisplayResolver.canonicalPhoneKey(for: handle) else { return nil }
            return strictIndex[key]
        }

        var result = Result()
        for handles in threads {
            result.threadsAudited += 1
            var threadIsSuffixDependent = false
            for handle in handles {
                result.handlesAudited += 1
                if legacyResolution(handle) != strictResolution(handle) {
                    result.suffixDependentHandles += 1
                    threadIsSuffixDependent = true
                }
            }
            if threadIsSuffixDependent {
                result.suffixDependentThreads += 1
            }
        }
        return result
    }

    /// App-side glue: audits the real library against the real Contacts
    /// database. Read-only on both. Prints counts only — no names, numbers,
    /// or titles ever reach stdout.
    static func runOnLibraryAndPrint() async {
        guard await MessagesStoreImporter.requestContactAccessIfNeeded() == .authorized else {
            print("suffix10-audit: Contacts access not authorized — nothing to audit (legacy and strict both resolve no contacts without access).")
            return
        }

        let contacts = loadContactPhoneFixtures()
        let threads = await loadStoredPhoneHandlesPerThread()
        let result = run(threads: threads, contacts: contacts)

        print("suffix10-audit: threads audited: \(result.threadsAudited)")
        print("suffix10-audit: phone handles audited: \(result.handlesAudited)")
        print("suffix10-audit: handles whose resolution depended on the removed suffix-10 fallback: \(result.suffixDependentHandles)")
        print("suffix10-audit: threads affected: \(result.suffixDependentThreads)")
    }

    private static func loadContactPhoneFixtures() -> [ContactFixture] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        var fixtures: [ContactFixture] = []
        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let numbers = contact.phoneNumbers.map { $0.value.stringValue }
            guard !numbers.isEmpty else { return }
            fixtures.append(ContactFixture(identifier: contact.identifier, phoneNumbers: numbers))
        }
        return fixtures
    }

    private static func loadStoredPhoneHandlesPerThread() async -> [[String]] {
        guard let store = try? ArchiveStore(),
              let summaries = try? await store.loadThreadSummaries(filters: LibraryFilters())
        else {
            return []
        }

        return summaries.map { summary in
            summary.participantNames
                .map { ContactDisplayResolver.storedHandle(fromParticipantLabel: $0) }
                .filter { !$0.isEmpty && !$0.contains("@") && $0.lowercased() != "you" }
        }
    }
}
