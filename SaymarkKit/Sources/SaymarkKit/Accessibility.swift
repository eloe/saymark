import AppKit
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
    private static let maximumReceiptUTF16 = 64
    private let element: AXUIElement
    private let processID: pid_t
    private let selectedRange: CFRange

    public static func capture() -> FocusedInsertionLease? {
        guard let element = focusedElement(),
              let selectedRange = selectionRange(of: element)
        else { return nil }
        var processID: pid_t = 0
        guard AXUIElementGetPid(element, &processID) == .success,
              AXUIElementSetMessagingTimeout(element, 0.05) == .success
        else { return nil }
        return FocusedInsertionLease(
            element: element,
            processID: processID,
            selectedRange: selectedRange
        )
    }

    public var isCurrent: Bool {
        guard let current = currentElement() else { return false }
        guard let currentRange = Self.selectionRange(of: current) else { return false }
        return currentRange.location == selectedRange.location
            && currentRange.length == selectedRange.length
    }

    /// True only after the original selection has collapsed to the caret
    /// position produced by inserting exactly `utf16Length` code units.
    public func acknowledgesInsertion(_ insertedText: String) -> Bool {
        guard let current = currentElement(),
              let currentRange = Self.selectionRange(of: current)
        else { return false }
        let expectedProbe = Self.receiptProbe(for: insertedText)
        let insertedRange = CFRange(
            location: selectedRange.location,
            length: expectedProbe.utf16.count
        )
        guard let observedText = Self.string(in: insertedRange, of: current) else { return false }
        return Self.receiptMatches(
            originalRange: selectedRange,
            insertedText: insertedText,
            currentRange: currentRange,
            observedText: observedText
        )
    }

    /// A caret at the exact final offset proves the target consumed the full
    /// payload. Reading a matching bounded prefix distinguishes that paste from
    /// unrelated caret motion without inspecting an arbitrary amount of the
    /// user's field content.
    private static func receiptProbe(for insertedText: String) -> String {
        let utf16 = insertedText.utf16
        var utf16End = utf16.index(
            utf16.startIndex,
            offsetBy: min(maximumReceiptUTF16, utf16.count)
        )
        while String.Index(utf16End, within: insertedText) == nil {
            utf16End = utf16.index(before: utf16End)
        }
        let end = String.Index(utf16End, within: insertedText) ?? insertedText.startIndex
        return String(insertedText[..<end])
    }

    @_spi(Testing)
    public static func receiptMatches(
        originalRange: CFRange,
        insertedText: String,
        currentRange: CFRange,
        observedText: String
    ) -> Bool {
        currentRange.location == originalRange.location + insertedText.utf16.count
            && currentRange.length == 0
            && observedText == receiptProbe(for: insertedText)
    }

    public var stillTargetsOriginalElement: Bool { currentElement() != nil }

    private func currentElement() -> AXUIElement? {
        guard let current = Self.focusedElement() else { return nil }
        var currentProcessID: pid_t = 0
        guard AXUIElementGetPid(current, &currentProcessID) == .success,
              currentProcessID == processID,
              CFEqual(element, current)
        else { return nil }
        return current
    }

    private static func focusedElement() -> AXUIElement? {
        resolveFocusedElement(
            systemLookup: {
                focusedElement(in: AXUIElementCreateSystemWide())
            },
            frontmostProcessID: {
                NSWorkspace.shared.frontmostApplication?.processIdentifier
            },
            applicationLookup: { processID in
                return focusedElement(in: AXUIElementCreateApplication(processID))
            },
            elementProcessID: { element in
                var processID: pid_t = 0
                guard AXUIElementGetPid(element, &processID) == .success else { return nil }
                return processID
            }
        )
    }

    static func resolveFocusedElement<Element, ProcessID: Equatable>(
        systemLookup: () -> Element?,
        frontmostProcessID: () -> ProcessID?,
        applicationLookup: (ProcessID) -> Element?,
        elementProcessID: (Element) -> ProcessID?
    ) -> Element? {
        if let systemElement = systemLookup() { return systemElement }
        guard let expectedProcessID = frontmostProcessID(),
              let applicationElement = applicationLookup(expectedProcessID),
              elementProcessID(applicationElement) == expectedProcessID,
              frontmostProcessID() == expectedProcessID
        else { return nil }
        return applicationElement
    }

    private static func focusedElement(in container: AXUIElement) -> AXUIElement? {
        guard AXUIElementSetMessagingTimeout(container, 0.05) == .success else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            container,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        let element = unsafeBitCast(value, to: AXUIElement.self)
        // A newly fetched application element otherwise inherits the system AX
        // timeout. Apply our bound before any selection or content IPC.
        guard AXUIElementSetMessagingTimeout(element, 0.05) == .success else { return nil }
        return element
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

    private static func string(in range: CFRange, of element: AXUIElement) -> String? {
        var mutableRange = range
        guard let parameter = AXValueCreate(.cfRange, &mutableRange) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            parameter,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == CFStringGetTypeID()
        else { return nil }
        return value as? String
    }
}
