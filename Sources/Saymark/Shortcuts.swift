import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to dictate, release to finish. Default ⌃⇧Space;
    /// user-rebindable via the Recorder in Settings. Backed by Carbon
    /// `RegisterEventHotKey` — needs no Accessibility permission. Avoid the
    /// Control–Option VoiceOver modifier in the out-of-box shortcut.
    static let dictate = Self("dictate", initial: DictationShortcutDefaults.recommended)
}

enum DictationShortcutDefaults {
    static let legacyVoiceOverConflict = KeyboardShortcuts.Shortcut(
        .space,
        modifiers: [.control, .option]
    )
    static let recommended = KeyboardShortcuts.Shortcut(
        .space,
        modifiers: [.control, .shift]
    )
    private static let migrationKey = "shortcut.migrated_legacy_voiceover_modifier.v1"

    static func shouldMigrate(
        current: KeyboardShortcuts.Shortcut?,
        migrationCompleted: Bool
    ) -> Bool {
        !migrationCompleted && current == legacyVoiceOverConflict
    }

    @MainActor
    static func migrateLegacyVoiceOverConflict(defaults: UserDefaults = .standard) {
        let completed = defaults.bool(forKey: migrationKey)
        let current = KeyboardShortcuts.getShortcut(for: .dictate)
        if shouldMigrate(current: current, migrationCompleted: completed) {
            KeyboardShortcuts.setShortcut(recommended, for: .dictate)
        }
        defaults.set(true, forKey: migrationKey)
    }
}
