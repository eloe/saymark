import ApplicationServices
import Foundation

/// Thin wrapper over the Accessibility trust check. Text injection (typing into
/// other apps) only works once the user grants the app Accessibility access.
public enum Accessibility {
    public static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Trust check that also shows the system prompt deep-linking to
    /// Privacy & Security → Accessibility. Returns the current trust state.
    @discardableResult
    public static func prompt() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}

/// Identity of the accessibility element and selection that owned focus when
/// dictation began. Delivery can fail closed if the user's intent moves.
public struct FocusedInsertionLease {
    private let element: AXUIElement
    private let processID: pid_t
    private let selectedRange: CFRange?

    public static func capture() -> FocusedInsertionLease? {
        guard let element = focusedElement(),
              let selectedRange = selectionRange(of: element)
        else { return nil }
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success else { return nil }
        return FocusedInsertionLease(
            element: element,
            processID: processID,
            selectedRange: selectedRange
        )
    }

    public var isCurrent: Bool {
        guard let current = Self.focusedElement() else { return false }
        var currentProcessID: pid_t = 0
        guard AXUIElementGetPid(current, &currentProcessID) == .success,
              currentProcessID == processID,
              CFEqual(element, current)
        else { return false }
        guard let selectedRange else { return false }
        guard let currentRange = Self.selectionRange(of: current) else { return false }
        return currentRange.location == selectedRange.location
            && currentRange.length == selectedRange.length
    }

    private static func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            system,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func selectionRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(axValue, .cfRange, &range) ? range : nil
    }
}
