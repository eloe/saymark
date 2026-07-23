import Foundation

/// Content-free comparison between the streaming draft and final refinement.
/// Diagnostics log only these counts/distances, never either transcript.
struct TranscriptDivergence: Equatable, Sendable {
    let draftWordCount: Int
    let finalWordCount: Int
    let wordEditDistance: Int
    let normalizedWordDistance: Double

    init(draft: String, final: String) {
        let draftWords = Self.words(draft)
        let finalWords = Self.words(final)
        let distance = Self.editDistance(draftWords, finalWords)
        draftWordCount = draftWords.count
        finalWordCount = finalWords.count
        wordEditDistance = distance
        let denominator = max(draftWords.count, finalWords.count)
        normalizedWordDistance = denominator == 0 ? 0 : Double(distance) / Double(denominator)
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func editDistance(_ lhs: [String], _ rhs: [String]) -> Int {
        if lhs.isEmpty { return rhs.count }
        if rhs.isEmpty { return lhs.count }
        var previous = Array(0 ... rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: rhs.count)
            for (j, right) in rhs.enumerated() {
                current[j + 1] = min(
                    current[j] + 1,
                    previous[j + 1] + 1,
                    previous[j] + (left == right ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[rhs.count]
    }
}
