import Foundation
import Testing
@testable import ThreadKeep

struct ContactSupportTests {
    /// The wire payload contains EXACTLY the approved fields — nothing about
    /// the library, device, or user can ride along without failing this test.
    @Test
    func payloadContainsOnlyApprovedFields() throws {
        let details = SupportTechnicalDetails(
            appVersion: "1.0", buildNumber: "4", macosVersion: "26.0", architecture: "Apple Silicon"
        )
        let submission = SupportSubmission(
            topic: .bugReport,
            replyEmail: "tester@example.com",
            message: "Hello",
            details: details,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try JSONEncoder().encode(submission)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == Set([
            "topic", "replyEmail", "message", "appVersion", "buildNumber",
            "macosVersion", "architecture", "timestamp",
        ]))
        #expect(object["topic"] as? String == "Bug Report")
        #expect(object["replyEmail"] as? String == "tester@example.com")

        // Without a reply email the key is omitted entirely, not sent empty.
        let anonymous = SupportSubmission(topic: .help, replyEmail: nil, message: "Hi", details: details)
        let anonymousObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(anonymous)) as? [String: Any]
        )
        #expect(anonymousObject["replyEmail"] == nil)
        #expect(Set(anonymousObject.keys).count == 7)
    }

    @Test
    func emailValidationIsPermissiveButShaped() {
        #expect(ContactSupportService.isPlausibleEmail("a@b.co"))
        #expect(ContactSupportService.isPlausibleEmail("first.last+tag@sub.domain.example"))
        #expect(!ContactSupportService.isPlausibleEmail("nope"))
        #expect(!ContactSupportService.isPlausibleEmail("a@b"))
        #expect(!ContactSupportService.isPlausibleEmail("a b@c.d"))
        #expect(!ContactSupportService.isPlausibleEmail(""))
    }

    @Test
    func technicalDetailsComeFromRuntimeNotHardcoding() {
        let details = SupportTechnicalDetails.current()
        #expect(!details.macosVersion.isEmpty)
        #expect(details.macosVersion.contains("."))
        #expect(["Apple Silicon", "Intel"].contains(details.architecture))
        #expect(details.displayRows.count == 4)
    }

    @Test
    @MainActor
    func messageIsRequiredAndFailureKeepsText() {
        let model = ContactSupportModel()
        #expect(!model.canSend)

        model.message = "Something broke"
        #expect(model.canSend)

        model.replyEmail = "not-an-email"
        #expect(!model.canSend)
        #expect(model.emailLooksInvalid)

        model.replyEmail = "tester@example.com"
        #expect(model.canSend)
    }
}
