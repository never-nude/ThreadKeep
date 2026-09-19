import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Canonical download links shared across the app. Both point at
/// threadkeep.xyz so the destination can change server-side (TestFlight
/// today, the App Store tomorrow) without shipping an app update.
enum ThreadKeepAppLinks {
    static let iPhoneAppURL = URL(string: "https://threadkeep.xyz/iphone")!
    static let macAppSiteURL = URL(string: "https://threadkeep.xyz")!
}

/// A scannable QR code for the iPhone app: point the phone's camera at the
/// Mac's screen and the download link opens on the phone.
struct IPhoneAppQRView: View {
    var body: some View {
        VStack(spacing: 10) {
            if let image = Self.qrImage(for: ThreadKeepAppLinks.iPhoneAppURL.absoluteString) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: 140, height: 140)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Text("Point your iPhone's camera at this code to get ThreadKeep for iPhone.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 200)
        }
        .padding(16)
    }

    static func qrImage(for string: String, scale: CGFloat = 8) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let output = filter.outputImage else {
            return nil
        }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
