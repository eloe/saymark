import Foundation

/// Derives dictionary corrections from a heard transcript and the user's edited
/// version. An LCS word-diff finds the replaced spans; each becomes an
/// `alias (heard) → term (corrected)` pair, so correcting a word once teaches
/// both the post-transcription replacement and the Accurate+ biasing.
public enum VocabularyLearning {
    /// Replaced spans as (heard, term) pairs. Pure insertions/deletions yield no
    /// pair — there is nothing to alias. Case-insensitive matching on the LCS.
    public static func corrections(heard: String, corrected: String) -> [(heard: String, term: String)] {
        let a = tokens(heard)
        let b = tokens(corrected)
        guard !a.isEmpty, !b.isEmpty else { return [] }
        let lcs = lcsMatrix(a, b)

        var pairs: [(String, String)] = []
        var heardBuf: [String] = []
        var termBuf: [String] = []
        func flush() {
            if !heardBuf.isEmpty, !termBuf.isEmpty {
                pairs.append((heardBuf.reversed().joined(separator: " "),
                              termBuf.reversed().joined(separator: " ")))
            }
            heardBuf.removeAll()
            termBuf.removeAll()
        }

        var i = a.count
        var j = b.count
        while i > 0, j > 0 {
            if a[i - 1].lowercased() == b[j - 1].lowercased() {
                flush(); i -= 1; j -= 1
            } else if lcs[i - 1][j] >= lcs[i][j - 1] {
                heardBuf.append(a[i - 1]); i -= 1
            } else {
                termBuf.append(b[j - 1]); j -= 1
            }
        }
        while i > 0 { heardBuf.append(a[i - 1]); i -= 1 }
        while j > 0 { termBuf.append(b[j - 1]); j -= 1 }
        flush()
        return pairs.reversed()
    }

    private static func tokens(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func lcsMatrix(_ a: [String], _ b: [String]) -> [[Int]] {
        var m = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        var i = 1
        while i <= a.count {
            var j = 1
            while j <= b.count {
                m[i][j] = a[i - 1].lowercased() == b[j - 1].lowercased()
                    ? m[i - 1][j - 1] + 1
                    : max(m[i - 1][j], m[i][j - 1])
                j += 1
            }
            i += 1
        }
        return m
    }
}
