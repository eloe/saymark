// Test-only native macOS reference harness for Live Insertion evidence gates.
//
// This program creates and mutates only controls owned by this process. It is
// intentionally not linked into SaymarkKit or the app target. Do not reuse its
// AX helpers in production code: it exists to falsify the assumptions that
// would be required before any future cross-application live insertion.

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

private func axName(_ error: AXError) -> String {
    switch error {
    case .success: return "kAXErrorSuccess"
    case .failure: return "kAXErrorFailure"
    case .illegalArgument: return "kAXErrorIllegalArgument"
    case .invalidUIElement: return "kAXErrorInvalidUIElement"
    case .invalidUIElementObserver: return "kAXErrorInvalidUIElementObserver"
    case .cannotComplete: return "kAXErrorCannotComplete"
    case .attributeUnsupported: return "kAXErrorAttributeUnsupported"
    case .actionUnsupported: return "kAXErrorActionUnsupported"
    case .notificationUnsupported: return "kAXErrorNotificationUnsupported"
    case .notImplemented: return "kAXErrorNotImplemented"
    case .notificationAlreadyRegistered: return "kAXErrorNotificationAlreadyRegistered"
    case .notificationNotRegistered: return "kAXErrorNotificationNotRegistered"
    case .apiDisabled: return "kAXErrorAPIDisabled"
    case .noValue: return "kAXErrorNoValue"
    case .parameterizedAttributeUnsupported: return "kAXErrorParameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "kAXErrorNotEnoughPrecision"
    @unknown default: return "kAXErrorUnknown(\(error.rawValue))"
    }
}

private func elapsedMilliseconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
}

private func sameRange(_ lhs: CFRange?, _ rhs: CFRange?) -> Bool {
    switch (lhs, rhs) {
    case let (.some(lhs), .some(rhs)):
        return lhs.location == rhs.location && lhs.length == rhs.length
    case (.none, .none):
        return true
    default:
        return false
    }
}

private final class ReferenceTextView: NSTextView {
    private(set) var directUserSubstitutions = 0

    func substituteAsLocalUser(_ range: NSRange, with replacement: String) {
        // This is a test-only adapter. It models a same-range user edit without
        // involving an input injector or another application.
        textStorage?.replaceCharacters(in: range, with: replacement)
        directUserSubstitutions += 1
    }
}

private final class HungReferenceTextView: NSTextView {
    override func accessibilityValue() -> String? {
        // Deliberately blocks this *self-owned* control's AX value request so
        // the harness can observe what the public messaging timeout does.
        Thread.sleep(forTimeInterval: 0.500)
        return super.accessibilityValue()
    }
}

private final class ProbeRecorder {
    private let lock = NSLock()
    private var entries: [String] = []

    func record(_ value: String) {
        lock.lock()
        entries.append(value)
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private func observerCallback(
    _: AXObserver,
    _: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let recorder = Unmanaged<ProbeRecorder>.fromOpaque(refcon).takeUnretainedValue()
    recorder.record(notification as String)
}

/// Starts AXObserver on a dedicated CFRunLoop thread. The source is retained
/// and added before the test action; unlike a main-thread-only observer, this
/// establishes the run-loop wiring required by the design.
private final class DedicatedObserverProbe {
    private let pid: pid_t
    private let element: AXUIElement
    private let recorder: ProbeRecorder
    private let ready = DispatchSemaphore(value: 0)
    private let stopped = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var observer: AXObserver?
    private var runLoop: CFRunLoop?
    private var setup: [String] = []
    private var isStopping = false

    init(pid: pid_t, element: AXUIElement, recorder: ProbeRecorder) {
        self.pid = pid
        self.element = element
        self.recorder = recorder
    }

    func start() -> [String] {
        let worker = Thread { [weak self] in self?.run() }
        worker.name = "LiveInsertionEvidence.AXObserver"
        worker.qualityOfService = .userInitiated
        worker.start()
        _ = ready.wait(timeout: .now() + 2)
        lock.lock()
        defer { lock.unlock() }
        return setup
    }

    func stop() {
        lock.lock()
        isStopping = true
        let loop = runLoop
        lock.unlock()
        if let loop { CFRunLoopStop(loop) }
        _ = stopped.wait(timeout: .now() + 2)
    }

    private func appendSetup(_ line: String) {
        lock.lock()
        setup.append(line)
        lock.unlock()
    }

    private func run() {
        var created: AXObserver?
        let create = AXObserverCreate(pid, observerCallback, &created)
        appendSetup("observer.create=\(axName(create))")
        guard create == .success, let created else {
            ready.signal()
            stopped.signal()
            return
        }

        let opaque = Unmanaged.passUnretained(recorder).toOpaque()
        let selected = AXObserverAddNotification(
            created,
            element,
            kAXSelectedTextChangedNotification as CFString,
            opaque
        )
        let value = AXObserverAddNotification(
            created,
            element,
            kAXValueChangedNotification as CFString,
            opaque
        )
        appendSetup("observer.add.selected=\(axName(selected))")
        appendSetup("observer.add.value=\(axName(value))")

        let source = AXObserverGetRunLoopSource(created)
        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, source, .defaultMode)
        lock.lock()
        observer = created // retain until after the source is removed
        runLoop = loop
        lock.unlock()
        appendSetup("observer.source.added=true")
        ready.signal()

        while true {
            lock.lock()
            let stopping = isStopping
            lock.unlock()
            if stopping { break }
            CFRunLoopRunInMode(.defaultMode, 0.050, true)
        }

        CFRunLoopRemoveSource(loop, source, .defaultMode)
        lock.lock()
        observer = nil
        runLoop = nil
        lock.unlock()
        stopped.signal()
    }
}

private final class SafeMutationAdapter {
    private(set) var attemptedAXWrites = 0
    private(set) var admittedOperations = 0
    private(set) var rejectedOperations = 0
    private(set) var residualOperations = 0
    private var operationInFlight = false

    /// This adapter deliberately has no AXUIElementSetAttributeValue call. It
    /// checks the intended admission state, then records the outcome.
    func attempt(secureRole: Bool, secureInput: Bool) {
        attemptedAXWrites += 0
        guard !secureRole, !secureInput, !operationInFlight else {
            rejectedOperations += 1
            return
        }
        operationInFlight = true
        admittedOperations += 1
        operationInFlight = false
    }

    func startBeforeSecureTransition() {
        guard !operationInFlight else { return }
        operationInFlight = true
        admittedOperations += 1
    }

    func secureTransitionArrivedWhileOperationWasInFlight() {
        if operationInFlight { residualOperations += 1 }
    }

    func finishInFlightOperation() { operationInFlight = false }
}

private final class NativeReferenceHarness: NSObject {
    private let normal = ReferenceTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 90))
    private let secure = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 520, height: 28))
    private let hung = HungReferenceTextView(frame: NSRect(x: 0, y: 0, width: 520, height: 60))
    private var window: NSWindow?
    private var results: [String] = []

    func start() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        normal.string = "prefix OWNED suffix"
        normal.isRichText = false
        normal.isEditable = true
        normal.isSelectable = true
        secure.stringValue = "secret"
        hung.string = "slow value"

        let stack = NSStackView(views: [normal, secure, hung])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 250),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "Saymark Live Insertion Native Reference Harness (test only)"
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.makeFirstResponder(normal)
        self.window = window

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.300) { [weak self] in
            self?.execute()
        }
        app.run()
    }

    private func emit(_ line: String) { results.append(line) }

    private func focusedElement() -> AXUIElement? {
        let application = AXUIElementCreateApplication(getpid())
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        )
        emit("focus.read=\(axName(error))")
        return raw as! AXUIElement?
    }

    private func setSelection(_ element: AXUIElement, _ range: CFRange) -> AXError {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return .failure }
        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            value
        )
    }

    private func selection(_ element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &raw
        ) == .success,
        let value = raw as! AXValue?,
        AXValueGetType(value) == .cfRange
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private func rangedTail(_ element: AXUIElement, _ range: CFRange) -> (AXError, String?) {
        var mutable = range
        guard let value = AXValueCreate(.cfRange, &mutable) else { return (.failure, nil) }
        var raw: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            value,
            &raw
        )
        // Do not print observed text. It is compared transiently only.
        return (error, raw as? String)
    }

    private func roleDescription(_ element: AXUIElement) -> String {
        var role: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        return "\(axName(result)):\((role as? String) ?? "nil")"
    }

    private func execute() {
        emit("harness=self-owned-native-control")
        emit("pid=\(getpid())")
        emit("accessibility.trusted=\(AXIsProcessTrusted())")
        emit("secure-event-input.initial=\(IsSecureEventInputEnabled())")

        guard let normalElement = focusedElement() else {
            emit("fatal=no-focused-normal-element")
            finish()
            return
        }
        emit("normal.role=\(roleDescription(normalElement))")
        runAcknowledgementAndOwnershipProbe(normalElement)
        runSecureMatrix()
        runTimeoutProbe()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.350) { [weak self] in
            self?.finish()
        }
    }

    private func runAcknowledgementAndOwnershipProbe(_ element: AXUIElement) {
        let recorder = ProbeRecorder()
        let observer = DedicatedObserverProbe(pid: getpid(), element: element, recorder: recorder)
        for line in observer.start() { emit(line) }

        // B-02: a ranged read begins from a collapsed, unrelated caret and is
        // followed by a byte-for-byte same-offset substitution. There is no
        // AX selection setter in either verification step.
        let tailRange = CFRange(location: 7, length: 5)
        let sentinel = CFRange(location: 1, length: 0)
        emit("b02.sentinel.set=\(axName(setSelection(element, sentinel)))")
        let before = selection(element)
        let first = rangedTail(element, tailRange)
        let afterFirst = selection(element)
        let firstMatches = first.1 == "OWNED"
        emit("b02.read.initial=\(axName(first.0))")
        emit("b02.selection.unchanged.after-read=\(sameRange(before, afterFirst))")
        emit("b02.initial-tail-match=\(firstMatches)")

        normal.substituteAsLocalUser(NSRange(location: 7, length: 5), with: "OTHER")
        let beforeSecond = selection(element)
        let second = rangedTail(element, tailRange)
        let afterSecond = selection(element)
        let substitutionDetected = second.1 != "OWNED"
        emit("b02.same-offset.same-length.local-substitution-count=\(normal.directUserSubstitutions)")
        emit("b02.read.after-substitution=\(axName(second.0))")
        emit("b02.substitution-detected=\(substitutionDetected)")
        emit("b02.selection.unchanged.after-mismatch-read=\(sameRange(beforeSecond, afterSecond))")

        // B-01: after B-02's proof, restore only the self-owned fixture and
        // exercise the public AX setters. The observer payload contains no
        // public origin or transaction acknowledgement; the harness records
        // ordering/coalescing but must report that limitation rather than infer
        // acknowledgement from a transport success.
        normal.string = "prefix OWNED suffix"
        let select = setSelection(element, tailRange)
        let replace = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            "MUTED" as CFString
        )
        emit("b01.public-select-transport=\(axName(select))")
        emit("b01.public-replace-transport=\(axName(replace))")
        emit("b01.public-origin-field=false")
        emit("b01.public-ack-token-field=false")
        emit("b01.observer.notifications.pending=true")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.180) { [weak self] in
            guard let self else { return }
            let notes = recorder.snapshot()
            self.emit("b01.observer.notification-count=\(notes.count)")
            self.emit("b01.observer.notification-order=\(notes.joined(separator: ","))")
            self.emit("b01.acknowledgement-usable=false")
            observer.stop()
        }
    }

    private func runSecureMatrix() {
        let adapter = SafeMutationAdapter()
        adapter.attempt(secureRole: false, secureInput: false)
        adapter.attempt(secureRole: true, secureInput: false)
        adapter.attempt(secureRole: false, secureInput: true)
        adapter.attempt(secureRole: true, secureInput: true)
        adapter.startBeforeSecureTransition()
        adapter.secureTransitionArrivedWhileOperationWasInFlight()
        adapter.finishInFlightOperation()

        window?.makeFirstResponder(secure)
        let secureEvent = IsSecureEventInputEnabled()
        guard let secureElement = focusedElement() else {
            emit("b04.secure.focused-element=false")
            return
        }
        emit("b04.secure.focused-element=true")
        emit("b04.secure.role=\(roleDescription(secureElement))")
        emit("b04.secure-event-input.with-secure-control=\(secureEvent)")
        emit("b04.matrix.admitted-safe-adapter=\(adapter.admittedOperations)")
        emit("b04.matrix.rejected-safe-adapter=\(adapter.rejectedOperations)")
        emit("b04.inflight-residual-safe-adapter=\(adapter.residualOperations)")
        emit("b04.protected-field.ax-write-attempts=\(adapter.attemptedAXWrites)")
        emit("b04.native-protected-write-tested=false")
        emit("b04.acknowledgement=blocked-until-residual-behaviour-proven")
        window?.makeFirstResponder(normal)
    }

    private func runTimeoutProbe() {
        guard let normalElement = focusedElement() else {
            emit("b05.normal.focused-element=false")
            return
        }
        let timeoutSet = AXUIElementSetMessagingTimeout(normalElement, 0.100)
        var normalValue: CFTypeRef?
        let normalElapsed = elapsedMilliseconds {
            _ = AXUIElementCopyAttributeValue(normalElement, kAXValueAttribute as CFString, &normalValue)
        }
        emit("b05.timeout.set.normal=\(axName(timeoutSet))")
        emit(String(format: "b05.normal-read.elapsed-ms=%.2f", normalElapsed))

        // The hanging test is intentionally limited to this process. Whether a
        // self-target exercises the same timeout path as another app is itself
        // an evidence limitation and cannot certify the coordinator.
        window?.makeFirstResponder(hung)
        guard let hungElement = focusedElement() else {
            emit("b05.hung.focused-element=false")
            return
        }
        let hungTimeoutSet = AXUIElementSetMessagingTimeout(hungElement, 0.100)
        let group = DispatchGroup()
        let recorder = ProbeRecorder()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            let wasMain = Thread.isMainThread
            var raw: CFTypeRef?
            let start = DispatchTime.now().uptimeNanoseconds
            let error = AXUIElementCopyAttributeValue(hungElement, kAXValueAttribute as CFString, &raw)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            recorder.record("error=\(axName(error));elapsed=\(String(format: "%.2f", elapsed));off-main=\(!wasMain)")
            group.leave()
        }
        let completed = group.wait(timeout: .now() + 1.0) == .success
        emit("b05.timeout.set.hung=\(axName(hungTimeoutSet))")
        emit("b05.hung-read.completed-within-1000ms=\(completed)")
        for line in recorder.snapshot() { emit("b05.hung-read.\(line)") }
        emit("b05.self-owned-hang-certifies-cross-app-timeout=false")
        emit("b05.coordinator-fail-closed-evidence=false")
        window?.makeFirstResponder(normal)
    }

    private func finish() {
        print("LIVE_INSERTION_EVIDENCE_BEGIN")
        for result in results { print(result) }
        print("LIVE_INSERTION_EVIDENCE_END")
        NSApp.terminate(nil)
    }
}

private let harness = NativeReferenceHarness()
harness.start()
