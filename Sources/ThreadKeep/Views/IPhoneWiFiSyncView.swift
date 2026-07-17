import AppKit
import SwiftUI

/// Sheet that walks the user through sending their whole library to the
/// ThreadKeep iOS app over Wi-Fi. Purely presentational: every state comes
/// from `ThreadKeepWiFiSyncServer`, which the presenting code starts when the
/// sheet appears and stops when it closes.
struct IPhoneWiFiSyncView: View {
    @ObservedObject var server: ThreadKeepWiFiSyncServer
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 40)
                .padding(.top, 36)

            Divider()

            HStack {
                Spacer()
                Button(closeButtonTitle) {
                    onClose()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(width: 480, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var closeButtonTitle: String {
        switch server.state {
        case .finished, .failed, .stopped:
            return "Close"
        case .waitingForPhone, .pairing, .sending:
            return "Cancel"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch server.state {
        case .stopped, .waitingForPhone:
            waitingContent
        case let .pairing(deviceName, code):
            pairingContent(deviceName: deviceName, code: code)
        case let .sending(sent, total, currentTitle):
            sendingContent(sent: sent, total: total, currentTitle: currentTitle)
        case let .finished(count):
            finishedContent(count: count)
        case let .failed(message):
            failedContent(message: message)
        }
    }

    private var waitingContent: some View {
        VStack(spacing: 18) {
            Image(systemName: "wifi")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("Send to iPhone over Wi-Fi")
                .font(.title2.weight(.semibold))

            Text("On your iPhone, open ThreadKeep and tap “Get conversations from my Mac”. This Mac will appear on the phone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text("Waiting for your iPhone…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    private func pairingContent(deviceName: String, code: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.radiowaves.left.and.right")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("“\(deviceName)” wants to connect")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(spacedOut(code))
                .font(.system(size: 56, weight: .bold, design: .rounded))
                .monospacedDigit()
                .padding(.horizontal, 28)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(nsColor: .quaternarySystemFill))
                )

            Text("Type this code on your iPhone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func sendingContent(sent: Int, total: Int, currentTitle: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.accentColor)

            Text("Sending your conversations")
                .font(.title3.weight(.semibold))

            ProgressView(value: Double(sent), total: Double(max(total, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 300)

            Text("Sending \(sent) of \(total) — \(currentTitle)…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
    }

    private func finishedContent(count: Int) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("Sent \(count) conversation\(count == 1 ? "" : "s") to your iPhone. 🎉")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("You can close this window. Your conversations are now on your iPhone.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func failedContent(message: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.yellow)

            Text("Something went wrong")
                .font(.title3.weight(.semibold))

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Try Again") {
                server.restart()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.top, 4)
        }
    }

    /// "0427" → "0 4 2 7" so the big code reads clearly across the room.
    private func spacedOut(_ code: String) -> String {
        code.map(String.init).joined(separator: " ")
    }
}
