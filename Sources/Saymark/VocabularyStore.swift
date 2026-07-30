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
    static let defaultsKey = "saymark.vocabulary"

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

    nonisolated static func load() -> [VocabularyEntry]? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode([VocabularyEntry].self, from: data)
    }

    nonisolated static func save(_ entries: [VocabularyEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
