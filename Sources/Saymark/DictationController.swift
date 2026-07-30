import AppKit
import Foundation
import KeyboardShortcuts
import SaymarkKit
import Observation
import PostHog

/// Keeps optional history strictly before, and non-authoritative to, the one
/// user-visible insertion. Delivery is invoked exactly once whether history
/// records successfully, times out, or returns no record.
enum FinalDeliveryCoordinator {
    @MainActor
    static func deliver(
        recordBeforeDelivery: () async -> HistoryRecord?,
        insertExactlyOnce: () -> HistoryDeliveryState,
        markDelivery: (HistoryRecord?, HistoryDeliveryState) -> Void
    ) async -> (record: HistoryRecord?, outcome: HistoryDeliveryState) {
        let record = await recordBeforeDelivery()
        let outcome = insertExactlyOnce()
        markDelivery(record, outcome)
        return (record, outcome)
    }
}

/// Coalesces model-preparation requests without allowing model loading to take
/// ownership of an active utterance's lifecycle state.
struct DeferredModelPreparation {
    private(set) var pendingMode: DictationMode?

    mutating func request(_ mode: DictationMode, canStartNow: Bool) -> DictationMode? {
        guard canStartNow else {
            pendingMode = mode
            return nil
        }
        pendingMode = nil
        return mode
    }

    mutating func takePending(canStartNow: Bool) -> DictationMode? {
        guard canStartNow, let pendingMode else { return nil }
        self.pendingMode = nil
        return pendingMode
    }
}

/// The application HUD has exactly one live transcript source: ordered,
/// correction-complete updates. Raw ASR updates remain available to onboarding
/// and benchmarks through `DictationSession`, but cannot race the app HUD.
@MainActor
final class CorrectedHUDObserver {
    typealias Handler = @Sendable (CorrectedTranscript, CorrectedTranscript) -> Void
    typealias Observe = (@escaping Handler) -> (() -> Void)
    private var cancel: (() -> Void)?

    init(observe: Observe, receive: @escaping Handler) {
        cancel = observe { confirmed, partial in receive(confirmed, partial) }
    }

    deinit { cancel?() }
}

/// Thin SwiftUI-facing wrapper around `SaymarkKit.DictationSession`: maps the
/// shared pipeline to an `@Observable` menu-bar state, wires the Carbon hotkey
/// to start/stop, and injects the final transcript into the focused field.
///
/// All the heavy lifting (mic, STT, 160 ms feed, warm-up) lives in SaymarkKit and
/// is shared verbatim with `saymark-cli`.
@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case loadingModels
        case idle
        case recording
        case transcribing
        case transcribed(String)
        case error(String)
    }

    private(set) var state: State = .loadingModels

    private let session: DictationSession
    private let hud = HUDController()
    @ObservationIgnored private var hudTranscriptObserver: CorrectedHUDObserver?

    /// The shared, already-warmed pipeline — exposed so onboarding's try-it step
    /// reuses it instead of spinning up a second `DictationSession`.
    var dictationSession: DictationSession { session }
    @ObservationIgnored private var promptedAccessibility = false
    @ObservationIgnored private var isPreparing = false
    @ObservationIgnored private var deferredPreparation = DeferredModelPreparation()
    @ObservationIgnored private var historyEnabledAtStart = false
    #if DEBUG
    @ObservationIgnored private var dailyDriverUITestConfiguration: DailyDriverUITestConfiguration?
    #endif

    init() {
        // Resolve the main-actor singleton here, then let the session read its
        // thread-safe, nonisolated store snapshot from capture/metering queues.
        let vocabulary = VocabularySettingsModel.shared
        session = DictationSession(correctionSnapshotProvider: { vocabulary.snapshot })
    }

    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "⌃⌥Space"
    }

    /// Typing into other apps needs Accessibility (the hotkey itself does not).
    var needsAccessibilityToType: Bool { !Accessibility.isTrusted }

    var statusLine: String {
        switch state {
        case .loadingModels: return "Loading models…"
        case .idle:
            return TriggerMode.current == .hold
                ? "Idle — hold \(shortcutLabel)"
                : "Idle — press \(shortcutLabel) to start"
        case .recording: return "Listening…"
        case .transcribing: return "Transcribing…"
        // The HUD owns the short-lived final display. Never mirror dictated text
        // into a persistent menu/status accessibility value.
        case .transcribed: return "Ready"
        case let .error(m): return "Error: \(m)"
        }
    }

    /// Compact status for the menu popover.
    var shortStatus: String {
        switch state {
        case .loadingModels: return "Loading…"
        case .idle, .transcribed: return "Ready"
        case .recording: return "Listening"
        case .transcribing: return "Transcribing"
        case let .error(m): return m
        }
    }

    /// True while a dictation is in flight (drives the popover pulse dot).
    var isActive: Bool {
        state == .recording || state == .transcribing
    }

    func bootstrap() {
        let accessibilityTrusted = Accessibility.isTrusted
        SaymarkDiagnostics.log(.info, "dictation.controller_bootstrap", fields: [
            "model_mode": ModelSetting.current.rawValue,
            "trigger_mode": TriggerMode.current.rawValue,
            "insert_mode": InsertMode.current.rawValue,
            "accessibility_trusted": accessibilityTrusted,
        ])
        hudTranscriptObserver = CorrectedHUDObserver(
            observe: { [session] handler in
                let subscription = session.observeCorrectedUpdates(handler)
                return { subscription.cancel() }
            },
            receive: { [weak self] confirmed, partial in
                self?.echoCorrected(confirmed, partial)
            }
        )
        installHotkeyHandlers()
        session.requestMicrophonePermission()            // surface the mic prompt early
        if InsertMode.current == .inField, !accessibilityTrusted {
            promptedAccessibility = true
            Accessibility.prompt()
        }
        requestPreparation(mode: ModelSetting.current)   // load only the current mode's models
    }

    func requestAccessibility() { Accessibility.prompt() }

    private func installHotkeyHandlers() {
        KeyboardShortcuts.onKeyDown(for: .dictate) { [weak self] in self?.hotkeyDown() }
        KeyboardShortcuts.onKeyUp(for: .dictate) { [weak self] in self?.hotkeyUp() }
    }

    /// Re-load when the Model setting changes (popover) — pulls in the newly
    /// selected mode's models so the next dictation starts instantly.
    func prepareCurrentMode() { requestPreparation(mode: ModelSetting.current) }

    /// Lazily load (download on first run) only the models `mode` needs, surfacing
    /// a loading state. Requests made during capture/finalization or another load
    /// are coalesced to the newest mode and resumed after teardown.
    private func requestPreparation(mode: DictationMode) {
        let canStartNow = !isPreparing && !utteranceIsActive
        guard let mode = deferredPreparation.request(mode, canStartNow: canStartNow) else {
            SaymarkDiagnostics.log(.debug, "models.ui_prepare_deferred", fields: [
                "reason": isPreparing ? "already_preparing" : "dictation_in_flight",
                "mode": mode.rawValue,
            ])
            return
        }
        prepareImmediately(mode: mode)
    }

    private var utteranceIsActive: Bool {
        state == .recording || state == .transcribing
    }

    private func prepareImmediately(mode: DictationMode) {
        guard !session.isReady(mode) else {
            // Already warmed (e.g. onboarding loaded the selected plan into the
            // shared session before bootstrap ran) — just go idle.
            if case .loadingModels = state { state = .idle }
            SaymarkDiagnostics.log(.debug, "models.ui_ready", fields: ["mode": mode.rawValue, "reused": true])
            return
        }
        isPreparing = true
        state = .loadingModels
        Task { @MainActor in
            do {
                try await session.load(mode: mode)
                if case .loadingModels = state { state = .idle }
                SaymarkDiagnostics.log(.info, "models.ui_ready", fields: ["mode": mode.rawValue, "reused": false])
            } catch {
                SaymarkDiagnostics.log(.error, "models.ui_failed", fields: [
                    "mode": mode.rawValue,
                    "error_type": String(reflecting: type(of: error)),
                ])
                let failedModeIsStillDesired =
                    ModelSetting.current == mode &&
                    deferredPreparation.pendingMode == nil
                if case .loadingModels = state, failedModeIsStillDesired {
                    state = .error("model load: \(error.localizedDescription)")
                }
            }
            isPreparing = false
            resumeDeferredPreparationIfPossible()
        }
    }

    private func resumeDeferredPreparationIfPossible() {
        guard let mode = deferredPreparation.takePending(
            canStartNow: !isPreparing && !utteranceIsActive
        ) else { return }
        requestPreparation(mode: mode)
    }

    /// Hotkey press: hold-mode starts; toggle-mode flips start/stop. Gated by the
    /// master enable.
    private func hotkeyDown() {
        #if DEBUG
        if RuntimeEnvironment.isDailyDriverUITesting {
            dailyDriverUITestHotkeyDown()
            return
        }
        #endif
        guard DictationEnabled.value else {
            SaymarkDiagnostics.log(.trace, "hotkey.ignored", fields: ["reason": "dictation_disabled"])
            return
        }
        switch TriggerMode.current {
        case .hold:   beginRecording()
        case .toggle: if state == .recording { endRecording() } else { beginRecording() }
        }
    }

    /// Hotkey release only ends dictation in hold mode (toggle ignores release).
    private func hotkeyUp() {
        #if DEBUG
        if RuntimeEnvironment.isDailyDriverUITesting {
            dailyDriverUITestHotkeyUp()
            return
        }
        #endif
        if TriggerMode.current == .hold { endRecording() }
    }

    private func beginRecording() {
        let gestureStarted = ProcessInfo.processInfo.systemUptime
        guard state != .recording, state != .transcribing else {
            SaymarkDiagnostics.log(.trace, "hotkey.ignored", fields: ["reason": "dictation_in_flight"])
            return
        }
        guard !isPreparing else {
            SaymarkDiagnostics.log(.debug, "dictation.start_deferred", fields: ["reason": "models_preparing"])
            return
        }
        let modelMode = ModelSetting.current
        // Models for this mode not loaded yet (e.g. just switched) — kick the load
        // and skip this press; the next one records once ready.
        guard session.isReady(modelMode) else {
            SaymarkDiagnostics.log(.debug, "dictation.start_deferred", fields: ["reason": "models_not_ready", "mode": modelMode.rawValue])
            requestPreparation(mode: modelMode)
            return
        }
        let insert = InsertMode.current
        // History is explicit opt-in at the beginning of the utterance. A later
        // settings change must not retroactively retain speech that began Off.
        let history = RecentDictationsController.shared
        historyEnabledAtStart = history.isStartupComplete
            && history.isHistoryAvailable
            && history.activeRetention != .off
            && insert != .hudOnly
        let toggle = TriggerMode.current == .toggle
        // Give visual feedback before AVAudioEngine setup. Capture startup takes
        // around 100 ms on this Mac; the HUD should never wait behind it.
        hud.begin(presentation: insert == .hudOnly, lang: "EN",
                  shortcutLabel: shortcutLabel,
                  interactive: toggle, onStop: { [weak self] in self?.endRecording() })
        SaymarkDiagnostics.log(.debug, "dictation.hud_presented", fields: [
            "latency_ms": (ProcessInfo.processInfo.systemUptime - gestureStarted) * 1_000,
            "model_mode": modelMode.rawValue,
        ])
        do {
            // The live two-tier view stays in the HUD; the field receives one paste
            // on release (Variant B — paste is atomic, so no live-into-field typing).
            try session.start(mode: modelMode)
            SaymarkDiagnostics.log(.info, "dictation.ui_started", sessionID: session.activeSessionID, fields: [
                "model_mode": modelMode.rawValue,
                "trigger_mode": TriggerMode.current.rawValue,
                "insert_mode": insert.rawValue,
            ])
            state = .recording
            PostHogSDK.shared.capture("dictation_started", properties: [
                "model_mode": modelMode.rawValue,
                "trigger_mode": TriggerMode.current.rawValue,
                "insert_mode": insert.rawValue,
            ])
        } catch {
            SaymarkDiagnostics.log(.error, "dictation.ui_start_failed", sessionID: session.activeSessionID, fields: [
                "model_mode": modelMode.rawValue,
                "error_type": String(reflecting: type(of: error)),
            ])
            state = .error(error.localizedDescription)
            PostHogSDK.shared.capture("dictation_failed", properties: [
                "error_type": String(reflecting: type(of: error)),
                "model_mode": modelMode.rawValue,
            ])
            hud.error("Open Privacy in Settings →")
        }
    }

    private nonisolated func echoCorrected(_ confirmed: CorrectedTranscript, _ partial: CorrectedTranscript) {
        Task { @MainActor in
            self.hud.update(confirmed: confirmed.renderedText, partial: partial.renderedText,
                            rawConfirmed: confirmed.rawText, rawPartial: partial.rawText,
                            correctionStatus: partial.correctionStatus.rawValue,
                            correctionRevision: partial.snapshotRevision)
        }
    }

    private func endRecording() {
        guard state == .recording else { return }
        state = .transcribing
        hud.processing()
        let modelModeAtStop = ModelSetting.current.rawValue
        let insertModeAtStop = InsertMode.current.rawValue
        let historyWasEnabledAtStart = historyEnabledAtStart
        let diagnosticSessionID = session.activeSessionID
        let stopStarted = ProcessInfo.processInfo.systemUptime
        SaymarkDiagnostics.log(.info, "dictation.ui_stop_requested", sessionID: diagnosticSessionID)
        // Drain off the main thread so a slow finish never freezes the UI, then
        // paste the final on the main thread (pasteboard + ⌘V).
        Task.detached(priority: .userInitiated) { [weak self, session] in
            let final = session.stop()
            let corrected = session.latestCorrectedTranscript
            await self?.completeFinal(
                final,
                corrected: corrected,
                diagnosticSessionID: diagnosticSessionID,
                modelModeAtStop: modelModeAtStop,
                insertModeAtStop: insertModeAtStop,
                stopStarted: stopStarted,
                historyWasEnabledAtStart: historyWasEnabledAtStart
            )
        }
    }

    private func completeFinal(
        _ final: String,
        corrected: CorrectedTranscript,
        diagnosticSessionID: String?,
        modelModeAtStop: String,
        insertModeAtStop: String,
        stopStarted: TimeInterval,
        historyWasEnabledAtStart: Bool
    ) async {
        if final.isEmpty {
            hud.error(
                title: String(localized: "No speech detected"),
                detail: String(localized: "Try again and speak a little longer")
            )
        } else {
            if InsertMode.current == .inField {
                let delivery = await FinalDeliveryCoordinator.deliver {
                    await RecentDictationsController.shared.recordFinal(
                        final,
                        enabledAtStart: historyWasEnabledAtStart,
                        secureInputActive: TextInjector.secureInputActive,
                        isHUDOnly: false
                    )
                } insertExactlyOnce: {
                    insertFinal(
                        final,
                        rawText: corrected.rawText,
                        correctionStatus: corrected.correctionStatus.rawValue,
                        correctionRevision: corrected.snapshotRevision,
                        sessionID: diagnosticSessionID
                    )
                } markDelivery: {
                    RecentDictationsController.shared.markDelivery($0, state: $1)
                }
                if delivery.outcome != .inserted, delivery.record != nil {
                    hud.offerRecentDictationsRecovery {
                        RecentDictationsController.shared.present()
                    }
                }
            } else {
                _ = await RecentDictationsController.shared.recordFinal(
                    final,
                    enabledAtStart: historyWasEnabledAtStart,
                    secureInputActive: TextInjector.secureInputActive,
                    isHUDOnly: true
                )
                hud.finish(
                    final,
                    rawText: corrected.rawText,
                    correctionStatus: corrected.correctionStatus.rawValue,
                    correctionRevision: corrected.snapshotRevision
                )
            }
        }
                SaymarkDiagnostics.log(.info, "dictation.ui_completed", sessionID: diagnosticSessionID, fields: [
                    "is_empty": final.isEmpty,
                    "model_mode": modelModeAtStop,
                    "insert_mode": insertModeAtStop,
                    "stop_to_complete_ms": (ProcessInfo.processInfo.systemUptime - stopStarted) * 1_000,
                ])
                PostHogSDK.shared.capture("dictation_completed", properties: [
                    "is_empty": final.isEmpty,
                    "model_mode": modelModeAtStop,
                    "insert_mode": insertModeAtStop,
                ])
        state = .transcribed(final)
        resumeDeferredPreparationIfPossible()
        // Release the controller's final-text-associated state after the HUD's
        // normal completion window. This prevents a completed dictation from
        // surviving indefinitely in the menu-bar controller.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, case .transcribed = self.state else { return }
            self.state = .idle
        }
    }

    /// Paste the final transcript into the focused field (In-field mode). Posting
    /// ⌘V needs Accessibility — if untrusted, prompt once and leave the text on the
    /// clipboard so it's not lost. Secure input (password fields) blocks paste; we
    /// say so in the HUD instead of dropping silently.
    private func insertFinal(
        _ text: String,
        rawText: String? = nil,
        correctionStatus: String? = nil,
        correctionRevision: UInt64? = nil,
        sessionID: String?,
        uiTestCompletion: ((String) -> Void)? = nil
    ) -> HistoryDeliveryState {
        #if DEBUG
        if RuntimeEnvironment.isDailyDriverUITesting {
            switch RuntimeEnvironment.dailyDriverOutcome {
            case "fallback":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                hud.error(
                    title: String(localized: "Copied to clipboard"),
                    detail: String(localized: "Enable Accessibility to paste automatically"),
                    hideAfter: 2.0
                )
                uiTestCompletion?("copied")
                return .copiedAccessibility
            default:
                hud.finish(text, rawText: rawText, correctionStatus: correctionStatus, correctionRevision: correctionRevision)
                uiTestCompletion?("inserted")
                return .inserted
            }
        }
        #endif

        guard Accessibility.isTrusted else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            if !promptedAccessibility { promptedAccessibility = true; Accessibility.prompt() }
            SaymarkDiagnostics.log(.warn, "dictation.insert_copied", sessionID: sessionID, fields: [
                "reason": "accessibility_not_trusted",
            ])
            hud.error(
                title: String(localized: "Copied to clipboard"),
                detail: String(localized: "Enable Accessibility to paste automatically"),
                hideAfter: 5.0
            )
            return .copiedAccessibility
        }
        let started = ProcessInfo.processInfo.systemUptime
        switch TextInjector.paste(text + " ") {
        case .pasted:
            SaymarkDiagnostics.log(.info, "dictation.insert_completed", sessionID: sessionID, fields: [
                "outcome": "pasted",
                "duration_ms": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            ])
            hud.finish(text, rawText: rawText, correctionStatus: correctionStatus, correctionRevision: correctionRevision)
            return .inserted
        case .failed:
            SaymarkDiagnostics.log(.error, "dictation.insert_completed", sessionID: sessionID, fields: [
                "outcome": "failed",
                "duration_ms": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            ])
            hud.error(
                title: String(localized: "Couldn’t paste text"),
                detail: String(localized: "The transcript was copied — press ⌘V")
            )
            return .insertionFailed
        case .copiedSecureInput:
            SaymarkDiagnostics.log(.warn, "dictation.insert_completed", sessionID: sessionID, fields: [
                "outcome": "copied_secure_input",
                "duration_ms": (ProcessInfo.processInfo.systemUptime - started) * 1_000,
            ])
            hud.error(
                title: String(localized: "Field is protected"),
                detail: String(localized: "The transcript was copied — press ⌘V")
            )
            return .insertionFailed
        }
    }

    #if DEBUG
    /// Installs the same Carbon shortcut callbacks used in production, but swaps
    /// microphone/model work for a deterministic transcript and target adapter.
    /// The UI test must still generate the configured global shortcut; calling
    /// this method alone never starts a dictation.
    func prepareDailyDriverUITest(_ configuration: DailyDriverUITestConfiguration) {
        guard RuntimeEnvironment.isDailyDriverUITesting else { return }
        dailyDriverUITestConfiguration = configuration
        state = .idle
        installHotkeyHandlers()
        configuration.onStatus("READY")
    }

    private func dailyDriverUITestHotkeyDown() {
        guard let configuration = dailyDriverUITestConfiguration else { return }
        guard state != .recording, state != .transcribing else {
            configuration.onStatus("KDX")
            return
        }
        configuration.onStatus("KD")
        state = .recording
        hud.begin(presentation: true, lang: "EN", shortcutLabel: shortcutLabel)
        configuration.onStatus(hud.panel != nil && hud.hasAttachedViewTree
            ? "L"
            : "LX")

        guard !configuration.finalText.isEmpty else { return }
        let sentences = configuration.finalText.split(separator: ".", omittingEmptySubsequences: true)
        let confirmed = sentences.prefix(2).map(String.init).joined(separator: ".") + "."
        let partial = sentences.dropFirst(2).map(String.init).joined(separator: ".") + "."
        hud.update(confirmed: confirmed, partial: partial)
        let visible = [hud.model.confirmed, hud.model.partial]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let visibleSentenceCount =
            visible.split(separator: ".", omittingEmptySubsequences: true).count
        let fullTranscript = visible.replacingOccurrences(of: " ", with: "") ==
            configuration.finalText.replacingOccurrences(of: " ", with: "")
        let panelState = hud.panel != nil && hud.hasAttachedViewTree
        let signature = Self.dailyDriverSignature(configuration.finalText)
        configuration.onStatus(
                visibleSentenceCount == 3 && fullTranscript && panelState
                    ? "V3F1\(signature)"
                    : "VX"
        )
    }

    private func dailyDriverUITestHotkeyUp() {
        guard let configuration = dailyDriverUITestConfiguration else { return }
        guard state == .recording else {
            configuration.onStatus("KUX")
            return
        }
        configuration.onStatus("KU")
        state = .transcribing
        hud.processing()
        let isProcessing =
            hud.model.phase == .transcribing &&
            hud.model.confirmed.isEmpty &&
            hud.model.partial.isEmpty &&
            !hud.model.recording
        let panelAttached = hud.panel != nil && hud.hasAttachedViewTree
        configuration.onStatus(isProcessing && panelAttached ? "P" : "PX")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.state == .transcribing else { return }
            if configuration.finalText.isEmpty {
                self.hud.error(
                    title: String(localized: "No speech detected"),
                    detail: String(localized: "Try again and speak a little longer"),
                    hideAfter: 0.2
                )
                configuration.onStatus("D0N")
                self.waitForDailyDriverHUDTeardown(
                    attemptsRemaining: 40,
                    onStatus: configuration.onStatus
                )
                self.state = .transcribed("")
                return
            }
            configuration.deliver(configuration.finalText) { [weak self] result in
                guard let self else { return }
                switch result.hudPresentation {
                case .finished:
                    self.hud.finish(configuration.finalText)
                case .accessibilityFallback:
                    self.hud.error(
                        title: String(localized: "Copied to clipboard"),
                        detail: String(localized: "Enable Accessibility to paste automatically"),
                        hideAfter: 0.2
                    )
                case .secureInputFallback:
                    self.hud.error(
                        title: String(localized: "Field is protected"),
                        detail: String(localized: "The transcript was copied — press ⌘V"),
                        hideAfter: 0.2
                    )
                }
                configuration.onStatus(result.statusToken)
                self.waitForDailyDriverHUDTeardown(
                    attemptsRemaining: 40,
                    onStatus: configuration.onStatus
                )
                self.state = .transcribed(configuration.finalText)
            }
        }
    }

    private func waitForDailyDriverHUDTeardown(
        attemptsRemaining: Int,
        onStatus: @escaping (String) -> Void
    ) {
        if hud.panel == nil && !hud.hasAttachedViewTree {
            onStatus("TRR")
            return
        }
        guard attemptsRemaining > 0 else {
            onStatus("TXX")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForDailyDriverHUDTeardown(
                attemptsRemaining: attemptsRemaining - 1,
                onStatus: onStatus
            )
        }
    }

    private static func dailyDriverSignature(_ text: String) -> String {
        let checksum = text.utf8.reduce(0) { (($0 * 31) + Int($1)) % 100_000 }
        return "N\(text.count)H\(checksum)"
    }
    #endif
}

#if DEBUG
enum DailyDriverHUDPresentation {
    case finished
    case accessibilityFallback
    case secureInputFallback
}

struct DailyDriverDeliveryResult {
    let statusToken: String
    let hudPresentation: DailyDriverHUDPresentation
}

struct DailyDriverUITestConfiguration {
    let finalText: String
    let onStatus: (String) -> Void
    let deliver: (_ text: String, _ completion: @escaping (DailyDriverDeliveryResult) -> Void) -> Void
}
#endif
