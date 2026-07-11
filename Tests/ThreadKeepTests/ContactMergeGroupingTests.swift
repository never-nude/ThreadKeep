import Foundation
import Testing
@testable import ThreadKeep

/// Commit-2 guarantees: shared handles refuse to resolve to either card
/// (deterministically, independent of Contacts enumeration order), and
/// no-card handles merge by canonical handle instead of not at all.
struct ContactMergeGroupingTests {
    private struct Card {
        let id: String
        let name: String
        let phones: [String]
        let emails: [String]
    }

    private static let mom = Card(id: "MOM-1", name: "Mom", phones: ["+1 (914) 555-0100", "+1 (914) 555-0111"], emails: [])
    private static let dad = Card(id: "DAD-1", name: "Dad", phones: ["+1 (914) 555-0100", "+1 (914) 555-0122"], emails: ["dad@example.com"])

    private func buildIndexes(order: [Card]) -> ContactIndexBuilder.Indexes {
        var builder = ContactIndexBuilder()
        for card in order {
            builder.add(
                contactIdentifier: card.id,
                displayName: card.name,
                phoneNumbers: card.phones,
                emailAddresses: card.emails
            )
        }
        return builder.finalize()
    }

    @Test
    func s2SharedKeyRefusesBothCardsIndependentOfEnumerationOrder() {
        let forward = buildIndexes(order: [Self.mom, Self.dad])
        let reversed = buildIndexes(order: [Self.dad, Self.mom])

        // The shared landline resolves to NOBODY — not the first card
        // enumerated. The coin flip was the bug; identical output under
        // reversed enumeration is the proof it is gone.
        #expect(forward.phoneIndex["9145550100"] == nil)
        #expect(forward.contactIdentifierIndex["9145550100"] == nil)

        #expect(forward.phoneIndex == reversed.phoneIndex)
        #expect(forward.emailIndex == reversed.emailIndex)
        #expect(forward.contactIdentifierIndex == reversed.contactIdentifierIndex)
        #expect(forward.imageIndex == reversed.imageIndex)

        // Each parent's own cell still resolves to exactly their card.
        #expect(forward.contactIdentifierIndex["9145550111"] == "MOM-1")
        #expect(forward.contactIdentifierIndex["9145550122"] == "DAD-1")
        #expect(forward.emailIndex["dad@example.com"] == "Dad")
    }

    @Test
    @MainActor
    func s2SharedHandleGetsStableHandleIdentityNotAContact() {
        let indexes = buildIndexes(order: [Self.mom, Self.dad])
        let resolver = ContactDisplayResolver(
            phoneIndex: indexes.phoneIndex,
            emailIndex: indexes.emailIndex,
            contactIdentifierIndex: indexes.contactIdentifierIndex,
            isReady: true
        )

        #expect(resolver.canonicalContactKey(for: "+1 (914) 555-0100") == "handle:9145550100")
        #expect(resolver.canonicalContactKey(for: "9145550111") == "contact:MOM-1")
    }

    @Test
    @MainActor
    func noCardPhoneVariantsShareOneHandleMergeKey() {
        let resolver = ContactDisplayResolver(isReady: true)

        let keys = [
            "+1 (303) 886-7882",
            "(303) 886-7882",
            "13038867882",
            "0013038867882",
        ].map { handle in
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: [handle], excludingYou: true)
            )
        }

        #expect(Set(keys) == Set(["handle:3038867882"]))

        // International notation variants of one number also share a key —
        // and a different country's number never joins them.
        let ukPlus = ThreadMergeGrouping.mergeKey(
            for: resolver.uniqueParticipants(from: ["+447911123456"], excludingYou: true)
        )
        let ukBare = ThreadMergeGrouping.mergeKey(
            for: resolver.uniqueParticipants(from: ["447911123456"], excludingYou: true)
        )
        let usLookalike = ThreadMergeGrouping.mergeKey(
            for: resolver.uniqueParticipants(from: ["(791) 112-3456"], excludingYou: true)
        )
        #expect(ukPlus == "handle:447911123456")
        #expect(ukBare == ukPlus)
        #expect(usLookalike == "handle:7911123456")
        #expect(usLookalike != ukPlus)
    }

    @Test
    @MainActor
    func multiPartyAndContactBackedThreadsGateCorrectly() {
        let resolver = ContactDisplayResolver(
            phoneIndex: ["9145550623": "Jane Doe"],
            contactIdentifierIndex: ["9145550623": "JANE-1"],
            isReady: true
        )

        // 1:1 with a card → contact key.
        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["+1 (914) 555-0623"], excludingYou: true)
            ) == "contact:JANE-1"
        )

        // Group thread → never merges.
        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["+1 (914) 555-0623", "someone@example.com"], excludingYou: true)
            ) == nil
        )

        // Nothing but "you" → never merges.
        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["You"], excludingYou: true)
            ) == nil
        )
    }

    @Test
    @MainActor
    func bareNamesAndShortCodesNeverMergeByLookalikeText() {
        let resolver = ContactDisplayResolver(isReady: true)

        // Two archives whose participant is the literal string "Sam" may be
        // two different people — a name is not an identity.
        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["Sam"], excludingYou: true)
            ) == nil
        )

        // Short codes stay conservative too: below the 7-digit floor they
        // pass through rather than merge.
        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["88753"], excludingYou: true)
            ) == nil
        )
    }

    @Test
    @MainActor
    func deniedContactsDegradesToHandleIdentityEverywhere() {
        // Denied/disabled Contacts is exactly an empty-index resolver: no
        // contact: keys can exist, every handle gets deterministic
        // handle-level identity, emails merge only on exact address.
        let resolver = ContactDisplayResolver(isReady: true)

        let keys = [
            resolver.canonicalContactKey(for: "+1 (914) 555-0623"),
            resolver.canonicalContactKey(for: "jane@example.com"),
            resolver.canonicalContactKey(for: "  JANE@EXAMPLE.COM "),
        ]
        #expect(keys.allSatisfy { $0.hasPrefix("handle:") })
        #expect(keys[1] == keys[2])

        #expect(
            ThreadMergeGrouping.mergeKey(
                for: resolver.uniqueParticipants(from: ["jane@example.com"], excludingYou: true)
            ) == "handle:jane@example.com"
        )
    }
}
