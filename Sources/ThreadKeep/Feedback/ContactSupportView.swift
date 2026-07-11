import AppKit
import SwiftUI

/// Form state and submission behavior for the contact window — centralized so
/// every entry point (Help menu, Settings) opens the identical flow.
@MainActor
final class ContactSupportModel: ObservableObject {
    enum Phase: Equatable {
        case editing
        case sending
        case sent
        case failed(String)
    }

    @Published var topic: SupportTopic = .generalFeedback
    @Published var replyEmail = ""
    @Published var message = ""
    @Published private(set) var phase: Phase = .editing

    let technicalDetails = SupportTechnicalDetails.current()
    private let service = ContactSupportService()

    var canSend: Bool {
        guard phase == .editing || isFailed else { return false }
        guard !message.trimmed.isEmpty else { return false }
        let email = replyEmail.trimmed
        return email.isEmpty || ContactSupportService.isPlausibleEmail(email)
    }

    var emailLooksInvalid: Bool {
        let email = replyEmail.trimmed
        return !email.isEmpty && !ContactSupportService.isPlausibleEmail(email)
    }

    var isFailed: Bool {
        if case .failed = phase { return true }
        return false
    }

    func send() {
        guard canSend else { return }
        phase = .sending
        let submission = SupportSubmission(
            topic: topic,
            replyEmail: replyEmail.trimmed.nilIfBlank,
            message: message,
            details: technicalDetails
        )

        Task {
            do {
                try await service.submit(submission)
                // Successful submissions are not kept anywhere in the app.
                message = ""
                replyEmail = ""
                phase = .sent
            } catch SupportSubmissionError.rateLimited {
                phase = .failed("Too many messages in a short time. Please wait a little while and try again.")
            } catch SupportSubmissionError.notConfigured {
                phase = .failed("This build isn’t configured for support messages.")
            } catch {
                // The tester's text stays in the form; nothing is lost.
                phase = .failed("The message couldn’t be sent. Check your internet connection and try again.")
            }
        }
    }

    /// Copies the tester's message plus the visible technical details, so a
    /// failed submission never costs them their writing.
    func copyMessageToPasteboard() {
        var lines = ["Topic: \(topic.rawValue)"]
        if let email = replyEmail.trimmed.nilIfBlank {
            lines.append("Reply email: \(email)")
        }
        lines.append("")
        lines.append(message)
        lines.append("")
        lines.append(contentsOf: technicalDetails.displayRows.map { "\($0.label): \($0.value)" })

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

/// The contact window. No email address appears anywhere in this interface;
/// delivery goes through ThreadKeep's own support endpoint.
struct ContactSupportView: View {
    @StateObject private var model = ContactSupportModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if model.phase == .sent {
                sentContent
            } else {
                formContent
            }
        }
        .frame(width: 480)
        .onChange(of: model.phase) { _, phase in
            // Auto-close shortly after success so the tester lands back in the app.
            if phase == .sent {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                    if model.phase == .sent { dismiss() }
                }
            }
        }
    }

    private var sentContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.green)
            Text("Message sent")
                .font(.title3.bold())
            Text("Thank you for helping improve ThreadKeep.")
                .foregroundStyle(.secondary)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 8)
        }
        .padding(36)
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Contact Support")
                .font(.title2.bold())

            Picker("Topic", selection: $model.topic) {
                ForEach(SupportTopic.allCases) { topic in
                    Text(topic.rawValue).tag(topic)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("Your email (optional, for a reply)", text: $model.replyEmail)
                    .textFieldStyle(.roundedBorder)
                if model.emailLooksInvalid {
                    Text("That doesn’t look like an email address.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Message")
                    .font(.callout.weight(.medium))
                TextEditor(text: $model.message)
                    .font(.body)
                    .frame(minHeight: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color(nsColor: .separatorColor)))
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.technicalDetails.displayRows, id: \.label) { row in
                        HStack {
                            Text(row.label)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(row.value)
                                .font(.system(.body, design: .monospaced))
                        }
                        .font(.caption)
                    }
                    Divider()
                    Text("ThreadKeep will send only the information entered here and the basic technical details shown above. No messages, contacts, attachments, or library content are included.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(4)
            } label: {
                Text("Included with your message")
            }

            if case .failed(let explanation) = model.phase {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(explanation)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Copy Message") { model.copyMessageToPasteboard() }
                        .font(.caption)
                }
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if model.phase == .sending {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 6)
                }
                Button(model.isFailed ? "Try Again" : "Send") { model.send() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSend || model.phase == .sending)
            }
        }
        .padding(20)
    }
}
