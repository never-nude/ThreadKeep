import Foundation

/// The single decision point for grouping stored threads into one visible
/// person. Read-time only — merge decisions are recomputed on every library
/// refresh and never persisted, so Contacts drift can never reorganize
/// stored archives.
enum ThreadMergeGrouping {
    /// Returns the key a 1:1 thread groups under, or nil to pass through.
    ///
    /// - `contact:<CNContact.identifier>` — the handle resolves unambiguously
    ///   to exactly one Contacts card.
    /// - `handle:<canonical>` — no card claims the handle (none exists, the
    ///   key is ambiguous between cards, or Contacts access is off/denied).
    ///   Groups only notation variants of the SAME handle — +1 vs bare vs
    ///   00-prefixed — never two different numbers.
    ///
    /// Multi-party threads and unkeyable participants never merge. A handle:
    /// key merges only when its value is an actual handle — an email or a
    /// digit string long enough to be a phone number. Bare display names
    /// ("Sam" from a JSON archive) are NOT identities: two archives with the
    /// same name may be two different people, so they always pass through.
    static func mergeKey(for participants: [ContactDisplayResolver.ResolvedParticipant]) -> String? {
        guard participants.count == 1, let participant = participants.first else {
            return nil
        }

        let key = participant.canonicalKey
        if key.hasPrefix("contact:") {
            return key
        }

        guard key.hasPrefix("handle:") else {
            return nil
        }

        let value = key.dropFirst("handle:".count)
        guard value.contains("@") || value.filter(\.isNumber).count >= 7 else {
            return nil
        }

        return key
    }
}
