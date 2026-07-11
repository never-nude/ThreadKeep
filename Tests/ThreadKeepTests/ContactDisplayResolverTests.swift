import Foundation
import Testing
@testable import ThreadKeep

struct ContactDisplayResolverTests {
    @Test
    @MainActor
    func canonicalContactKeyUsesContactIdentifierWhenAvailable() {
        let resolver = makeResolver()

        #expect(resolver.canonicalContactKey(for: "jane@example.com") == "contact:ABC-123")
        #expect(resolver.canonicalContactKey(for: "+1 (555) 123-4567") == "contact:ABC-123")
        #expect(resolver.canonicalContactKey(for: "+1 (555) 999-9999") == "contact:DEF-456")
        #expect(resolver.canonicalContactKey(for: "88753") == "handle:88753")
        #expect(resolver.canonicalContactKey(for: " TEST@EXAMPLE.COM ") == "handle:test@example.com")
    }

    @Test
    @MainActor
    func uniqueParticipantsDedupesSharedContactButKeepsDistinctPeopleWithSameName() {
        let resolver = makeResolver()

        let participants = resolver.uniqueParticipants(
            from: [
                "jane@example.com",
                "+1 (555) 123-4567",
                "+1 (555) 999-9999",
                "88753",
                "88753"
            ],
            excludingYou: true
        )

        #expect(participants.count == 3)
        #expect(Set(participants.map(\.canonicalKey)) == Set(["contact:ABC-123", "contact:DEF-456", "handle:88753"]))
        #expect(participants.first(where: { $0.canonicalKey == "contact:ABC-123" })?.handle == "+1 (555) 123-4567")
        #expect(participants.filter { $0.displayName == "Jane Doe" }.count == 2)
    }

    @Test
    @MainActor
    func decoratedVariantsForSameContactRenderAsSinglePhotoParticipant() {
        let resolver = makeResolver()

        let participants = resolver.uniqueParticipants(
            from: [
                "Jane Doe (+1 (555) 123-4567)",
                "Jane Doe (5551234567)"
            ],
            excludingYou: true
        )

        #expect(participants.count == 1)
        #expect(participants.first?.canonicalKey == "contact:ABC-123")
        #expect(participants.first?.displayName == "Jane Doe")
        #expect(participants.first?.hasImage == true)
        #expect(participants.first?.handle == "Jane Doe (+1 (555) 123-4567)")
    }

    @Test
    @MainActor
    func decoratedSameNameDifferentContactsRemainSeparateParticipants() {
        let resolver = makeResolver()

        let participants = resolver.uniqueParticipants(
            from: [
                "Jane Doe (+1 (555) 123-4567)",
                "Jane Doe (+1 (555) 999-9999)"
            ],
            excludingYou: true
        )

        #expect(participants.count == 2)
        #expect(Set(participants.map(\.canonicalKey)) == Set(["contact:ABC-123", "contact:DEF-456"]))
        #expect(participants.filter { $0.displayName == "Jane Doe" }.count == 2)
    }

    @Test
    @MainActor
    func resolvedContactNamePreventsPhoneNumberPrimaryDisplay() {
        let resolver = makeResolver()

        #expect(resolver.resolvedName(for: "+1 (555) 123-4567") == "Jane Doe")
        #expect(resolver.resolvedName(for: "Jane Doe (+1 (555) 123-4567)") == "Jane Doe")
        #expect(resolver.title(rawTitle: "+1 (555) 123-4567", participantNames: ["+1 (555) 123-4567"]) == "Jane Doe")
        #expect(resolver.uniqueParticipants(from: ["+1 (555) 123-4567"]).first?.displayName == "Jane Doe")
    }

    @Test
    @MainActor
    func usPhoneVariantsDeduplicateWithoutContacts() {
        let resolver = ContactDisplayResolver(isReady: true)

        let participants = resolver.uniqueParticipants(
            from: [
                "+1 (303) 886-7882",
                "(303) 886-7882"
            ],
            excludingYou: true
        )

        #expect(participants.count == 1)
        #expect(participants.first?.displayName == "+1 (303) 886-7882")
    }

    @Test
    @MainActor
    func groupTitleUsesResolvedContactNames() {
        let resolver = makeResolver()

        let title = resolver.title(
            rawTitle: "+1 (555) 123-4567, +1 (555) 888-7777",
            participantNames: ["+1 (555) 123-4567", "+1 (555) 888-7777"]
        )

        #expect(title == "Jane Doe, Ryan Miller")
    }

    @Test
    @MainActor
    func contactImageDataIsAvailableThroughDecoratedHandles() {
        let resolver = makeResolver()

        #expect(resolver.hasImage(for: "+1 (555) 123-4567"))
        #expect(resolver.hasImage(for: "Jane Doe (+1 (555) 123-4567)"))
    }

    @Test
    func unknownPhoneNumberDoesNotProduceDigitOnlyAvatarInitials() {
        #expect(MonogramView.initials(for: "52") == nil)
        #expect(MonogramView.initials(for: "+1 (516) 381-2296") == nil)
        #expect(MonogramView.initials(for: "5163812296") == nil)
        #expect(MonogramView.initials(for: "person@example.com") == nil)
        #expect(MonogramView.initials(for: "Ryan Miller") == "RM")
    }
}

@MainActor
// Index keys mirror what the index builders emit: exactly one canonical key
// per number (ContactDisplayResolver.canonicalPhoneKey), lowercased emails.
private func makeResolver() -> ContactDisplayResolver {
    ContactDisplayResolver(
        phoneIndex: [
            "5551234567": "Jane Doe",
            "5559999999": "Jane Doe",
            "5558887777": "Ryan Miller"
        ],
        emailIndex: [
            "jane@example.com": "Jane Doe"
        ],
        contactIdentifierIndex: [
            "5551234567": "ABC-123",
            "jane@example.com": "ABC-123",
            "5559999999": "DEF-456",
            "5558887777": "GHI-789"
        ],
        imageIndex: [
            "5551234567": Data([0x01])
        ],
        isReady: true
    )
}
