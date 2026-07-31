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
        case copiedTargetChanged // intended field/selection no longer owns focus
        case deliveryUnconfirmed // event posted, but intended field did not acknowledge it
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
    public static func paste(_ text: String, targetLease: FocusedInsertionLease? = nil) -> Result {
        if let targetLease, !targetLease.isCurrent {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return .copiedTargetChanged
        }
        return paste(
            text,
            pasteboard: .general,
            secureInputActive: secureInputActive,
            postPaste: postPasteShortcut,
            targetIsCurrent: { targetLease?.isCurrent ?? true },
            restoreDelay: 0.12,
            onRestore: nil
        )
    }

    /// Paste into a leased field and report success only after Accessibility
    /// observes the exact caret movement caused by the inserted UTF-16 payload.
    /// The transcript remains on the clipboard on timeout or target loss.
    @MainActor
    public static func pasteAcknowledged(
        _ text: String,
        targetLease: FocusedInsertionLease,
        timeout: TimeInterval = 0.75
    ) async -> Result {
        await pasteAcknowledged(
            text,
            pasteboard: .general,
            secureInputActive: secureInputActive,
            postPaste: postPasteShortcut,
            targetIsCurrent: { targetLease.isCurrent },
            targetStillPresent: { targetLease.stillTargetsOriginalElement },
            deliveryStillAllowed: { !secureInputActive },
            targetAcknowledged: { targetLease.acknowledgesInsertion(text) },
            timeout: timeout
        )
    }

    @_spi(Testing)
    @MainActor
    public static func pasteAcknowledgedForTesting(
        _ text: String,
        pasteboard: NSPasteboard,
        secureInputActive: Bool = false,
        timeout: TimeInterval = 0.05,
        postPaste: @escaping () -> Bool,
        targetIsCurrent: @escaping () -> Bool,
        targetStillPresent: @escaping () -> Bool,
        deliveryStillAllowed: @escaping () -> Bool = { true },
        targetAcknowledged: @escaping () -> Bool
    ) async -> Result {
        await pasteAcknowledged(
            text,
            pasteboard: pasteboard,
            secureInputActive: secureInputActive,
            postPaste: postPaste,
            targetIsCurrent: targetIsCurrent,
            targetStillPresent: targetStillPresent,
            deliveryStillAllowed: deliveryStillAllowed,
            targetAcknowledged: targetAcknowledged,
            timeout: timeout
        )
    }

    @MainActor
    private static func pasteAcknowledged(
        _ text: String,
        pasteboard pb: NSPasteboard,
        secureInputActive: Bool,
        postPaste: () -> Bool,
        targetIsCurrent: () -> Bool,
        targetStillPresent: () -> Bool,
        deliveryStillAllowed: () -> Bool,
        targetAcknowledged: () -> Bool,
        timeout: TimeInterval
    ) async -> Result {
        guard !text.isEmpty else { return .failed }
        if secureInputActive {
            pb.clearContents()
            pb.setString(text, forType: .string)
            return .copiedSecureInput
        }

        let saved = snapshot(pb)
        pb.clearContents()
        pb.setString(text, forType: .string)
        let mine = pb.changeCount
        guard targetIsCurrent() else { return .copiedTargetChanged }
        guard postPaste() else { return .failed }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            guard !Task.isCancelled else { return .deliveryUnconfirmed }
            guard pb.changeCount == mine, deliveryStillAllowed() else {
                return .deliveryUnconfirmed
            }
            if targetAcknowledged() {
                guard pb.changeCount == mine else { return .deliveryUnconfirmed }
                pb.clearContents()
                if let saved, !saved.isEmpty { pb.writeObjects(saved) }
                return .pasted
            }
            guard targetStillPresent() else { return .deliveryUnconfirmed }
            do {
                try await Task.sleep(nanoseconds: 20_000_000)
            } catch {
                return .deliveryUnconfirmed
            }
        }
        return .deliveryUnconfirmed
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
        targetIsCurrent: @escaping () -> Bool = { true },
        onRestore: @escaping (RestoreResult) -> Void = { _ in }
    ) -> Result {
        paste(
            text,
            pasteboard: pasteboard,
            secureInputActive: secureInputActive,
            postPaste: postPaste,
            targetIsCurrent: targetIsCurrent,
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
        targetIsCurrent: () -> Bool,
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
        guard targetIsCurrent() else { return .copiedTargetChanged }
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

    private static let nonPersistentPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]

    /// Deep-copy the current pasteboard items so we can put them back after paste.
    /// A pasteboard carrying a concealed or transient marker belongs to its
    /// producer. Suppress the complete snapshot because sibling items may be
    /// alternate representations of the same non-persistent copy operation.
    private static func snapshot(_ pb: NSPasteboard) -> [NSPasteboardItem]? {
        guard let items = pb.pasteboardItems,
              items.allSatisfy({
                  nonPersistentPasteboardTypes.isDisjoint(with: $0.types)
              })
        else { return nil }
        return items.compactMap { item in
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
