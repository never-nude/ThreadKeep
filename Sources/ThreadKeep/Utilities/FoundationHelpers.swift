import Foundation

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var slugified: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        let normalized = lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "&", with: " and ")
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)

        let pieces = normalized
            .components(separatedBy: allowed.inverted)
            .map(\.trimmed)
            .filter { !$0.isEmpty }

        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? "thread" : slug
    }
}

extension Date {
    func isOnSameDay(as other: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(self, inSameDayAs: other)
    }
}

enum StableHash {
    static func fnv1a64Hex(_ string: String) -> String {
        let offsetBasis: UInt64 = 14_695_981_039_346_656_037
        let prime: UInt64 = 1_099_511_628_211

        var hash = offsetBasis
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return String(hash, radix: 16)
    }
}
