import Foundation
import LocalAuthentication

enum LocalDeviceAuthenticationResult: Equatable {
    case authenticated
    case cancelled
    case unavailable(String)
    case failed(String)

    var errorMessage: String? {
        switch self {
        case .authenticated, .cancelled:
            return nil
        case .unavailable(let message), .failed(let message):
            return message
        }
    }
}

enum LocalDeviceAuthenticator {
    static func authenticate(
        reason: String = "ThreadKeep needs your Mac password before it can show saved conversations."
    ) async -> LocalDeviceAuthenticationResult {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"

        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("Turn on a Mac password or Touch ID to protect your ThreadKeep library.")
        }

        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                if success {
                    continuation.resume(returning: .authenticated)
                    return
                }

                if let error = error as? LAError {
                    switch error.code {
                    case .userCancel, .systemCancel, .appCancel:
                        continuation.resume(returning: .cancelled)
                    default:
                        continuation.resume(returning: .failed("ThreadKeep couldn’t confirm your Mac password. Try again to open your library."))
                    }
                } else {
                    continuation.resume(returning: .failed("ThreadKeep couldn’t confirm your Mac password. Try again to open your library."))
                }
            }
        }
    }
}
