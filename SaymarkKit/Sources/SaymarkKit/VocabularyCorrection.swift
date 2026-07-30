import Foundation

/// A user-defined dictionary term and the mishearings that should be rewritten to
/// it. ASR models mangle coined proper nouns that aren't in their language prior
/// (e.g. "Saymark" → "cmarc"), and the on-device Parakeet decode exposes no
/// biasing hook — so we correct the final transcript instead: replace each
/// `alias` with the canonical `term`, verbatim.
public struct VocabularyEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    /// The canonical spelling inserted into the transcript (e.g. "Saymark").
    public var term: String
    /// Mishearings replaced with `term` (e.g. "cmarc", "say mark").
    public var aliases: [String]

    public init(id: UUID = UUID(), term: String, aliases: [String]) {
        self.id = id
        self.term = term
        self.aliases = aliases
    }
}

/// Applies a vocabulary to a finished transcript: whole-word, case-insensitive
/// replacement of each alias with its canonical term. A pure value type so it can
/// run off the main actor (the stop-drain task) — it holds only strings and
/// compiles its patterns lazily, keeping it trivially `Sendable`.
public struct VocabularyCorrector: Sendable {
    private struct Rule: Sendable {
        let pattern: String
        let template: String
    }

    private let rules: [Rule]

    public init(entries: [VocabularyEntry]) {
        // Flatten to (alias, term) pairs, then apply longest alias first so a
        // multi-word alias ("say mark") wins over a shorter overlapping one.
        var pairs: [(alias: String, term: String)] = []
        for entry in entries {
            let term = entry.term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !term.isEmpty else { continue }
            for alias in entry.aliases {
                let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                pairs.append((trimmed, term))
            }
        }
        pairs.sort { $0.alias.count > $1.alias.count }

        rules = pairs.compactMap { pair in
            let words = pair.alias.split(whereSeparator: { $0.isWhitespace })
            guard !words.isEmpty else { return nil }
            let body = words
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: "\\s+")
            // Letter/number lookarounds are a stricter word boundary than \b:
            // "cmarc" matches in "cmarc." but not inside "cmarcs" or "scmarc".
            let pattern = "(?<![\\p{L}\\p{N}])\(body)(?![\\p{L}\\p{N}])"
            return Rule(pattern: pattern,
                        template: NSRegularExpression.escapedTemplate(for: pair.term))
        }
    }

    /// Returns `text` with every configured alias rewritten to its canonical term.
    public func correct(_ text: String) -> String {
        guard !rules.isEmpty, !text.isEmpty else { return text }
        var result = text
        for rule in rules {
            guard let regex = try? NSRegularExpression(
                pattern: rule.pattern, options: [.caseInsensitive]
            ) else { continue }
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result, options: [], range: range, withTemplate: rule.template
            )
        }
        return result
    }
}
