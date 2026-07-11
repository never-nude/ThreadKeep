import Foundation

/// What a tester can write in about.
enum SupportTopic: String, CaseIterable, Identifiable {
    case generalFeedback = "General Feedback"
    case bugReport = "Bug Report"
    case featureRequest = "Feature Request"
    case help = "Help Using ThreadKeep"

    var id: String { rawValue }
}

/// The technical details shown to the tester before sending — read from the
/// running app and OS, never hard-coded, and exactly what gets submitted.
struct SupportTechnicalDetails {
    let appVersion: String
    let buildNumber: String
    let macosVersion: String
    let architecture: String

    static func current() -> SupportTechnicalDetails {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var osString = "\(os.majorVersion).\(os.minorVersion)"
        if os.patchVersion > 0 {
            osString += ".\(os.patchVersion)"
        }

        var systemInfo = utsname()
        uname(&systemInfo)
        let machine = withUnsafeBytes(of: &systemInfo.machine) { buffer -> String in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let architecture: String
        switch machine {
        case "arm64": architecture = "Apple Silicon"
        case "x86_64": architecture = "Intel"
        default: architecture = machine
        }

        return SupportTechnicalDetails(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "unknown",
            buildNumber: info["CFBundleVersion"] as? String ?? "unknown",
            macosVersion: osString,
            architecture: architecture
        )
    }

    var displayRows: [(label: String, value: String)] {
        [
            ("ThreadKeep version", appVersion),
            ("Build number", buildNumber),
            ("macOS version", macosVersion),
            ("Mac architecture", architecture),
        ]
    }
}

/// The complete submission. These eight fields are the ONLY things the app
/// ever sends — the CodingKeys below are the wire format, and the
/// payload-exactness test pins them so nothing can be added silently.
struct SupportSubmission: Encodable {
    let topic: String
    let replyEmail: String?
    let message: String
    let appVersion: String
    let buildNumber: String
    let macosVersion: String
    let architecture: String
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case topic, replyEmail, message, appVersion, buildNumber, macosVersion, architecture, timestamp
    }

    init(topic: SupportTopic, replyEmail: String?, message: String, details: SupportTechnicalDetails, now: Date = Date()) {
        self.topic = topic.rawValue
        self.replyEmail = replyEmail?.trimmed.nilIfBlank
        self.message = message.trimmed
        self.appVersion = details.appVersion
        self.buildNumber = details.buildNumber
        self.macosVersion = details.macosVersion
        self.architecture = details.architecture
        self.timestamp = ISO8601DateFormatter().string(from: now)
    }
}

enum SupportSubmissionError: Error {
    case notConfigured
    case rateLimited
    case rejected
    case network
}

/// Small, isolated networking: one POST to the first-party support endpoint
/// (configured in Info.plist as TKSupportEndpoint — a URL, not a secret).
/// No analytics, no identifiers, no retries behind the tester's back.
struct ContactSupportService {
    /// Permissive email shape check — mirrors the server: something@something.tld.
    static func isPlausibleEmail(_ value: String) -> Bool {
        let trimmed = value.trimmed
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }

    static var endpointURL: URL? {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "TKSupportEndpoint") as? String else {
            return nil
        }
        return URL(string: raw)
    }

    func submit(_ submission: SupportSubmission) async throws {
        guard let url = Self.endpointURL, url.scheme == "https" else {
            throw SupportSubmissionError.notConfigured
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = try JSONEncoder().encode(submission)

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw SupportSubmissionError.network
        }

        guard let http = response as? HTTPURLResponse else {
            throw SupportSubmissionError.network
        }
        switch http.statusCode {
        case 200:
            return
        case 429:
            throw SupportSubmissionError.rateLimited
        default:
            throw SupportSubmissionError.rejected
        }
    }
}
