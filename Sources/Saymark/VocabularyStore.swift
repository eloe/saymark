import Foundation
import Observation
import SaymarkKit

/// The user's custom dictionary — canonical terms plus the mishearings that get
/// rewritten to them after transcription. Persisted as JSON in `UserDefaults`.
///
/// The menu-bar/Settings UI edits `shared` on the main actor; the stop-drain task
/// reads a fresh snapshot off the main actor via `currentCorrector()`. Both go
/// through `UserDefaults`, so an edit is picked up on the next dictation.
@MainActor
@Observable
final class VocabularyStore {
    static let shared = VocabularyStore()
    nonisolated static let defaultsKey = "saymark.vocabulary"

    /// Edited by the Settings UI; every mutation is persisted immediately.
    var entries: [VocabularyEntry] {
        didSet { Self.save(entries) }
    }

    init() {
        if let stored = Self.load() {
            entries = stored
        } else {
            // First run: seed the coined product name so "cmarc" & friends become
            // "Saymark", and persist it so the user sees an editable example.
            entries = Self.seed
            Self.save(Self.seed)
        }
    }

    func addEntry() {
        entries.append(VocabularyEntry(term: "", aliases: []))
    }

    /// Teach corrections from an edited transcript: diff heard-vs-corrected and,
    /// for each replaced span, add the corrected text as a term with the heard text
    /// as an alias (creating or extending the matching entry). Returns how many
    /// corrections were learned. Idempotent — re-teaching the same fix is a no-op.
    @discardableResult
    func learn(heard: String, corrected: String) -> Int {
        let corrections = VocabularyLearning.corrections(heard: heard, corrected: corrected)
        for (heardSpan, term) in corrections {
            if let idx = entries.firstIndex(where: {
                $0.term.caseInsensitiveCompare(term) == .orderedSame
            }) {
                if !entries[idx].aliases.contains(where: {
                    $0.caseInsensitiveCompare(heardSpan) == .orderedSame
                }) {
                    entries[idx].aliases.append(heardSpan)
                }
            } else {
                entries.append(VocabularyEntry(term: term, aliases: [heardSpan]))
            }
        }
        return corrections.count
    }

    func remove(_ entry: VocabularyEntry) {
        entries.removeAll { $0.id == entry.id }
    }

    func resetToDefaults() {
        entries = Self.seed
    }

    // MARK: - Storage (nonisolated so the stop-drain task can read a snapshot)

    /// The default dictionary shipped on first launch.
    nonisolated static var seed: [VocabularyEntry] {
        [VocabularyEntry(
            term: "Saymark",
            aliases: [
                "cmarc", "c mark", "cmark",
                "say mark", "sey mark", "see mark", "sea mark",
                "seymark", "say marc", "sey marc",
            ]
        )]
    }

    /// A thread-safe snapshot for use off the main actor (final-transcript rewrite).
    nonisolated static func currentCorrector() -> VocabularyCorrector {
        VocabularyCorrector(entries: load() ?? seed)
    }

    /// System-prompt string that primes Qwen3-ASR (Accurate+) to recognize the
    /// user's coined terms — native biasing, far better than post-hoc replacement.
    /// Empty when there are no terms (no biasing).
    nonisolated static func currentBiasingContext() -> String {
        let terms = (load() ?? seed)
            .map { $0.term.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        // Keep this MINIMAL and declarative. Imperative/instructional wording gets
        // echoed by Qwen3-ASR into the transcript, and long lists over-anchor. A
        // short noun phrase biases without leaking. Over-anchoring is best reduced
        // by listing the user's real terms, not by prompt wording.
        return "Possible names: \(terms.joined(separator: ", "))."
    }

    nonisolated static func load() -> [VocabularyEntry]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode([VocabularyEntry].self, from: data)
    }

    nonisolated static func save(_ entries: [VocabularyEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
