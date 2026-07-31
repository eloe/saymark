import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Push-to-talk: hold to dictate, release to finish. Default ⌃⇧Space;
    /// user-rebindable via the Recorder in Settings. Backed by Carbon
    /// `RegisterEventHotKey` — needs no Accessibility permission. Avoid the
    /// Control–Option VoiceOver modifier in the out-of-box shortcut.
    static let dictate = Self("dictate", initial: .init(.space, modifiers: [.control, .shift]))
}
