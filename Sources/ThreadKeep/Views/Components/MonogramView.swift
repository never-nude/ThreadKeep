import SwiftUI

/// A colored circle with 1–2 initials. The background color is derived from a stable
/// hash of the identifier so the same person always renders the same shade.
struct MonogramView: View {
    let displayName: String
    /// Identifier used to pick the palette color. Pass the raw handle so it stays stable
    /// even if the resolved display name changes (e.g. user edits Contacts).
    let paletteKey: String
    let size: CGFloat

    var body: some View {
        let color = Self.palette[Self.paletteIndex(for: paletteKey)]
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                if let initials = Self.initials(for: displayName) {
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.horizontal, size * 0.1)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
            .accessibilityLabel(Text(displayName))
    }

    nonisolated static func initials(for displayName: String) -> String? {
        guard !looksLikeUnresolvedHandle(displayName) else {
            return nil
        }

        let tokens = displayName
            .split(whereSeparator: { !$0.isLetter })
            .filter { !$0.isEmpty }

        if tokens.isEmpty {
            return nil
        }
        if tokens.count == 1 {
            return String(tokens[0].prefix(1)).uppercased()
        }
        let first = tokens.first!.prefix(1)
        let last = tokens.last!.prefix(1)
        return (String(first) + String(last)).uppercased()
    }

    private nonisolated static func looksLikeUnresolvedHandle(_ value: String) -> Bool {
        let trimmed = value.trimmed
        if trimmed.contains("@") {
            return true
        }
        return trimmed.filter(\.isNumber).count >= 7
    }

    private static func paletteIndex(for key: String) -> Int {
        let hash = StableHash.fnv1a64Hex(key.lowercased())
        let digits = hash.compactMap { UInt64(String($0), radix: 16) ?? nil }
        let sum = digits.reduce(into: UInt64(0)) { $0 = $0 &+ $1 }
        return Int(sum % UInt64(palette.count))
    }

    /// iMessage-ish palette. Hand-picked to read well on both light and dark backgrounds.
    private static let palette: [Color] = [
        Color(red: 0.24, green: 0.55, blue: 0.95),
        Color(red: 0.36, green: 0.73, blue: 0.41),
        Color(red: 0.96, green: 0.56, blue: 0.22),
        Color(red: 0.78, green: 0.36, blue: 0.84),
        Color(red: 0.96, green: 0.36, blue: 0.42),
        Color(red: 0.22, green: 0.68, blue: 0.78),
        Color(red: 0.85, green: 0.68, blue: 0.17),
        Color(red: 0.45, green: 0.45, blue: 0.92),
        Color(red: 0.92, green: 0.42, blue: 0.63),
        Color(red: 0.38, green: 0.60, blue: 0.37)
    ]
}
