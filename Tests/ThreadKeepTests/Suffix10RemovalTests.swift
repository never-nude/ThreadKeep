import Foundation
import Testing
@testable import ThreadKeep

/// Mutation tests for strict phone equivalence. The suffix-10 fallback merged
/// two different people (S1); these tests pin the EXACT key sets so any
/// fuzzier key — reintroduced anywhere — fails loudly here.
struct Suffix10RemovalTests {
    @Test
    func strictKeysPinExactCanonicalForms() {
        // Every case yields exactly ONE key. A second key means someone
        // reintroduced a fuzzy fallback — that is a false-merge vector.
        let expectations: [(handle: String, key: String)] = [
            ("+19145550623", "9145550623"),
            ("(914) 555-0623", "9145550623"),
            ("19145550623", "9145550623"),
            ("0019145550623", "9145550623"),
            ("+447911123456", "447911123456"),
            ("00447911123456", "447911123456"),
            ("7911123456", "7911123456"),
        ]

        for expectation in expectations {
            #expect(
                ContactDisplayResolver.phoneLookupKeys(for: expectation.handle) == [expectation.key],
                "keys for \(expectation.handle)"
            )
        }
    }

    @Test
    func s1UKCardCannotCaptureUSHandle() {
        // The reproduction of the false merge: a UK card whose last 10 digits
        // equal a US-style handle. Under suffix-10 these collided; strict
        // equivalence must keep them fully disjoint.
        let ukCardKeys = Set(ContactDisplayResolver.phoneLookupKeys(for: "+44 7911 123456"))
        let usHandleKeys = Set(ContactDisplayResolver.phoneLookupKeys(for: "(791) 112-3456"))
        #expect(ukCardKeys.isDisjoint(with: usHandleKeys))
    }

    @Test
    @MainActor
    func s1USHandleResolvesToHandleIdentityNotUKContact() {
        // Indexes as the new builder produces them for Dave's UK card.
        let resolver = ContactDisplayResolver(
            phoneIndex: ["447911123456": "Dave (UK)"],
            contactIdentifierIndex: ["447911123456": "DAVE-1"],
            isReady: true
        )

        #expect(resolver.canonicalContactKey(for: "+447911123456") == "contact:DAVE-1")
        #expect(resolver.canonicalContactKey(for: "(791) 112-3456") == "handle:7911123456")

        let participants = resolver.uniqueParticipants(
            from: ["Dave (UK) (+447911123456)", "(791) 112-3456"],
            excludingYou: true
        )
        #expect(participants.count == 2)
    }

    @Test
    func nanpReductionRequiresLeadingOne() {
        #expect(ContactDisplayResolver.phoneLookupKeys(for: "29145550623") == ["29145550623"])
        #expect(ContactDisplayResolver.phoneLookupKeys(for: "+7 911 123 45 67") == ["79111234567"])
    }

    @Test
    func doubleZeroStripAlwaysKeepsCountryCode() {
        // 00-strip fires only when ≥11 digits remain, so the result still
        // carries its country code. A 00-form whose remainder is 10 digits
        // stays untouched — it must never equal a bare 10-digit handle from
        // another country (e.g. a Danish 0045… vs a US 45x-area number).
        #expect(ContactDisplayResolver.phoneLookupKeys(for: "004505550123") == ["004505550123"])
        #expect(
            ContactDisplayResolver.phoneLookupKeys(for: "004505550123")
                != ContactDisplayResolver.phoneLookupKeys(for: "4505550123")
        )
    }

    @Test
    @MainActor
    func usVariantsStillResolveToSameContact() {
        let resolver = ContactDisplayResolver(
            phoneIndex: ["9145550623": "Jane Doe"],
            contactIdentifierIndex: ["9145550623": "JANE-1"],
            isReady: true
        )

        let keys = [
            resolver.canonicalContactKey(for: "+1 (914) 555-0623"),
            resolver.canonicalContactKey(for: "9145550623"),
            resolver.canonicalContactKey(for: "19145550623"),
        ]
        #expect(Set(keys) == Set(["contact:JANE-1"]))
    }

    @Test
    func auditFlagsSuffixDependentResolutionsOnly() {
        // S1 fixture: the US handle resolved to Dave ONLY via suffix-10.
        let s1 = Suffix10Audit.run(
            threads: [["(791) 112-3456"], ["+447911123456"]],
            contacts: [.init(identifier: "DAVE-1", phoneNumbers: ["+44 7911 123456"])]
        )
        #expect(s1.handlesAudited == 2)
        #expect(s1.suffixDependentHandles == 1)
        #expect(s1.suffixDependentThreads == 1)
        #expect(s1.affectedThreadIndexes == [0])

        // Benign US notation variants resolve identically under both schemes.
        let benign = Suffix10Audit.run(
            threads: [["+1 (914) 555-0623"], ["9145550623"]],
            contacts: [.init(identifier: "JANE-1", phoneNumbers: ["(914) 555-0623"])]
        )
        #expect(benign.suffixDependentHandles == 0)
        #expect(benign.suffixDependentThreads == 0)
    }
}
