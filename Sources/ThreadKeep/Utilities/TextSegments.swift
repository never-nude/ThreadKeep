import Foundation

struct LinkDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func urls(in text: String) -> [URL] {
        let nsText = text as NSString
        let matches = detector?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)) ?? []
        return matches.compactMap(\.url)
    }

    static func ranges(in text: String) -> [NSRange] {
        let nsText = text as NSString
        return detector?.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length)).map(\.range) ?? []
    }
}

struct HighlightedTextSegment: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let isLink: Bool
    let isHighlighted: Bool
}

enum TextSegmentBuilder {
    static func segments(for text: String, query: String) -> [HighlightedTextSegment] {
        guard !text.isEmpty else { return [] }

        let linkRanges = LinkDetector.ranges(in: text)
        let highlightRanges = highlightRanges(in: text, query: query)
        let nsText = text as NSString
        let length = nsText.length
        var boundaries: Set<Int> = [0, length]

        for range in linkRanges + highlightRanges {
            boundaries.insert(range.location)
            boundaries.insert(range.location + range.length)
        }

        let sortedBoundaries = boundaries.sorted()
        var segments: [HighlightedTextSegment] = []

        for index in 0 ..< max(0, sortedBoundaries.count - 1) {
            let start = sortedBoundaries[index]
            let end = sortedBoundaries[index + 1]
            guard end > start else { continue }

            let range = NSRange(location: start, length: end - start)
            let piece = nsText.substring(with: range)
            let isLink = linkRanges.contains(where: { NSIntersectionRange($0, range).length == range.length })
            let isHighlighted = highlightRanges.contains(where: { NSIntersectionRange($0, range).length == range.length })

            if let last = segments.last, last.isLink == isLink, last.isHighlighted == isHighlighted {
                segments[segments.count - 1] = HighlightedTextSegment(
                    text: last.text + piece,
                    isLink: isLink,
                    isHighlighted: isHighlighted
                )
            } else {
                segments.append(
                    HighlightedTextSegment(
                        text: piece,
                        isLink: isLink,
                        isHighlighted: isHighlighted
                    )
                )
            }
        }

        return segments
    }

    private static func highlightRanges(in text: String, query: String) -> [NSRange] {
        let tokens = query
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmed }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { return [] }

        let nsText = text as NSString
        var ranges: [NSRange] = []

        for token in tokens {
            var searchRange = NSRange(location: 0, length: nsText.length)

            while true {
                let found = nsText.range(of: token, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                if found.location == NSNotFound {
                    break
                }
                ranges.append(found)

                let nextLocation = found.location + max(found.length, 1)
                if nextLocation >= nsText.length {
                    break
                }
                searchRange = NSRange(location: nextLocation, length: nsText.length - nextLocation)
            }
        }

        return ranges
    }
}
