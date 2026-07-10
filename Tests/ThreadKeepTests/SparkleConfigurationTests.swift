import Foundation
import Testing

/// Validates the Sparkle updater configuration in ThreadKeepInfo.plist without
/// touching the network. Reads the plist straight from the repo (it is both
/// embedded into the binary and copied into the app bundle at package time, so
/// the file on disk is the single source of truth).
struct SparkleConfigurationTests {
    private static let placeholderKey = "PLACEHOLDER-SPARKLE-EDDSA-PUBLIC-KEY"

    private func infoPlist() throws -> [String: Any] {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // ThreadKeepTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/ThreadKeep/Support/ThreadKeepInfo.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    @Test
    func feedURLIsWellFormedAndPinnedToThreadkeepXYZ() throws {
        let feedString = try #require(infoPlist()["SUFeedURL"] as? String)
        let feedURL = try #require(URL(string: feedString))
        #expect(feedURL.scheme == "https")
        #expect(feedURL.host == "threadkeep.xyz")
        #expect(feedURL.path == "/appcast.xml")
    }

    @Test
    func publicEDKeyIsPresentAndPlausible() throws {
        let key = try #require(infoPlist()["SUPublicEDKey"] as? String)
        #expect(!key.isEmpty)
        // Until the cert machine generates the real pair, the placeholder is
        // allowed. Once replaced, the value must be a base64-encoded 32-byte
        // Ed25519 public key — this catches paste truncation on release day.
        if key != Self.placeholderKey {
            let decoded = Data(base64Encoded: key)
            #expect(decoded?.count == 32, "SUPublicEDKey is not a base64 32-byte Ed25519 key")
        }
    }

    @Test
    func automaticChecksKeyIsAbsentSoConsentGatesAllNetworking() throws {
        // Deliberate posture: Sparkle must ask the user before any scheduled
        // check. Setting SUEnableAutomaticChecks (either way) suppresses that
        // consent prompt, so the key must stay out of the plist entirely.
        #expect(try infoPlist()["SUEnableAutomaticChecks"] == nil)
    }

    @Test
    func bundleVersionIsAPositiveIntegerForSparkleComparisons() throws {
        let version = try #require(infoPlist()["CFBundleVersion"] as? String)
        let numeric = try #require(Int(version))
        #expect(numeric >= 2)
    }
}
