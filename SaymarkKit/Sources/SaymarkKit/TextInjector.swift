import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Puts the final transcript into the focused field of the frontmost app.
///
/// Primary path is **paste** (the production standard — Handy, Superwhisper,
/// TypeVox all paste): stash the pasteboard, write the text, synthesize ⌘V, then
/// restore the previous contents. Paste is atomic and reliable across resistant
/// targets (Terminal, Electron, VS Code) where per-key synthetic events drop.
/// Per-character Unicode typing is kept as an opt-in fallback (`type`).
///
/// Both paths post synthetic events, so both need Accessibility trust and both
/// are blocked by **secure input** (password fields / secure-keyboard terminals).
/// We detect that and refuse gracefully rather than silently dropping text.
public enum TextInjector {
    public enum Result: Sendable, Equatable {
        case pasted              // ⌘V sent into the field; clipboard restored
        case copiedSecureInput   // secure input on → left on the clipboard for manual ⌘V
        case failed              // couldn't synthesize the events
    }

    /// Observable result of the delayed clipboard-restoration policy. This is
    /// SPI for deterministic tests; production callers use `paste(_:)`.
    @_spi(Testing)
    public enum RestoreResult: Sendable, Equatable {
        case restoredOriginal
        case preservedNewerClipboard
    }

    /// True when some process has secure event input enabled — synthetic key
    /// events (including ⌘V) are dropped while it is. Anti-keylogger by design;
    /// there is no supported bypass, so callers should surface it, not retry.
    public static var secureInputActive: Bool { IsSecureEventInputEnabled() }

    /// Insert `text` by pasting. Requires Accessibility trust to post ⌘V. On
    /// secure input the text is left on the clipboard (not pasted) so it isn't
    /// lost. Call on the main thread (pasteboard + a short async restore).
    @discardableResult
    public static func paste(_ text: String) -> Result {
        paste(
            text,
            pasteboard: .general,
            secureInputActive: secureInputActive,
            postPaste: postPasteShortcut,
            restoreDelay: 0.12,
            onRestore: nil
        )
    }

    /// Deterministic seam for UI and policy tests. It runs the exact production
    /// snapshot/write/change-count/restore implementation while substituting
    /// only the two macOS boundaries that cannot be controlled in automation:
    /// secure-input state and delivery of the synthetic ⌘V event.
    @_spi(Testing)
    @discardableResult
    public static func pasteForTesting(
        _ text: String,
        pasteboard: NSPasteboard = .general,
        secureInputActive: Bool = false,
        restoreDelay: TimeInterval = 0.01,
        postPaste: @escaping () -> Bool,
        onRestore: @escaping (RestoreResult) -> Void = { _ in }
    ) -> Result {
        paste(
            text,
            pasteboard: pasteboard,
            secureInputActive: secureInputActive,
            postPaste: postPaste,
            restoreDelay: restoreDelay,
            onRestore: { result in
                switch result {
                case .restoredOriginal: onRestore(.restoredOriginal)
                case .preservedNewerClipboard: onRestore(.preservedNewerClipboard)
                }
            }
        )
    }

    private static func paste(
        _ text: String,
        pasteboard pb: NSPasteboard,
        secureInputActive: Bool,
        postPaste: () -> Bool,
        restoreDelay: TimeInterval,
        onRestore: ((RestoreResultShim) -> Void)?
    ) -> Result {
        guard !text.isEmpty else { return .failed }

        // Secure input → ⌘V won't reach the field. Leave the text on the clipboard.
        if secureInputActive {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .copiedSecureInput
        }

        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let mine = pb.changeCount
        guard postPaste() else { return .failed }

        // Restore once the target has read the pasteboard — but only if nothing
        // else wrote to it since (guard with changeCount so we never clobber a
        // copy the user made in between).
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            guard pb.changeCount == mine else {
                onRestore?(.preservedNewerClipboard)
                return
            }
            pb.clearContents()
            if let saved, !saved.isEmpty { pb.writeObjects(saved) }
            onRestore?(.restoredOriginal)
        }
        return .pasted
    }

    /// Internal spelling keeps the production implementation free of a public
    /// test-only type when compiling non-Debug distributions.
    private enum RestoreResultShim {
        case restoredOriginal
        case preservedNewerClipboard
    }

    /// Deep-copy the current pasteboard items so we can put them back after paste.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        pb.pasteboardItems?.compactMap { item in
            let copy = NSPasteboardItem()
            var any = false
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type); any = true }
            }
            return any ? copy : nil
        }
    }

    /// Synthesize ⌘V via a private event source (so it doesn't inherit any
    /// physical modifiers still held from the hotkey).
    private static func postPasteShortcut() -> Bool {
        let v = CGKeyCode(kVK_ANSI_V)
        let source = CGEventSource(stateID: .privateState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    /// Correct text already in the field: delete the last `count` characters, then
    /// paste `replacement`. The caller must have restored focus to the target app
    /// first (e.g. after an inline HUD edit stole key focus). Secure input → the
    /// replacement is left on the clipboard instead.
    @discardableResult
    public static func replaceLast(_ count: Int, with replacement: String) -> Result {
        guard !secureInputActive else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(replacement, forType: .string)
            return .copiedSecureInput
        }
        backspace(count)
        return paste(replacement)
    }

    /// Synthesize `count` backspaces via the private event source.
    private static func backspace(_ count: Int) {
        guard count > 0 else { return }
        let key = CGKeyCode(kVK_Delete)
        let source = CGEventSource(stateID: .privateState)
        for _ in 0 ..< count {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
            else { continue }
            down.flags = []
            up.flags = []
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    /// Per-character Unicode typing — the fragile fallback, kept for an opt-in
    /// "Type" insert mode. Carries the Unicode payload directly (no keycode
    /// mapping), but some apps drop fast synthetic key events. Blocked by secure
    /// input like paste.
    public static func type(_ text: String) {
        guard !text.isEmpty, !secureInputActive else { return }
        let source = CGEventSource(stateID: .privateState)
        for character in text {
            post(character, source: source)
        }
    }

    private static func post(_ character: Character, source: CGEventSource?) {
        let utf16 = Array(String(character).utf16)
        guard !utf16.isEmpty,
              let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else { return }

        down.flags = []                                  // clear ambient modifiers
        up.flags = []
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
