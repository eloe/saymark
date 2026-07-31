import AppKit
import AVFoundation
import Foundation
import KeyboardShortcuts
import SaymarkKit
import Observation
import PostHog
import SwiftUI

/// App-side `@Observable` that drives the onboarding window. Wraps the pure
/// `OnboardingFlow.State`, delegates every transition/gate to `OnboardingFlow`,
/// and owns the real-subsystem hooks (mic, accessibility, download, try-it) —
/// implemented as stubs here and filled in by later phases. Reuses the already-
/// warmed `DictationSession` from `DictationController` so the try-it step does
/// not spin up a second pipeline.
@MainActor
@Observable
final class OnboardingModel {
    static let didOnboardKey = "saymark.didOnboard"

    var flow = OnboardingFlow.State()
    var finished = false
    var downloadError: String?

    /// Called once the user completes onboarding — the AppDelegate uses it to boot
    /// the live menu app (mic now granted, models now cached). Set before launch.
    var onFinished: (() -> Void)?

    /// Bring the onboarding window back to the front. A TCC permission dialog steals
    /// focus and, for a menu-bar (`.accessory`) app with no Dock icon, leaves the
    /// setup window buried behind other apps — so we re-front it after the mic prompt.
    var onReactivate: (() -> Void)?

    /// Guards `startDownload` so repeated Download-step appearances or a manual
    /// Retry never spawn two concurrent downloads.
    @ObservationIgnored private var downloadStarted = false

    private let session: DictationSession
    @ObservationIgnored private var captureStopSubscription: DictationUpdateSubscription?

    /// Polls AX trust while the Permissions step is open — there's no
    /// notification for Accessibility-trust changes, so we have to ask.
    @ObservationIgnored private var accPollTimer: Timer?

    init(session: DictationSession) {
        self.session = session
        captureStopSubscription = session.observeCaptureStopRequests { [weak self] request in
            Task { @MainActor in
                guard let self,
                      request.belongs(to: self.session.activeSessionID),
                      self.tryListening
                else { return }
                self.tryEnd()
            }
        }
    }

    // MARK: navigation

    var canContinue: Bool { OnboardingFlow.canContinue(flow) }
    var showBack: Bool { flow.step != .welcome && !finished }

    /// The configured dictation shortcut shown and exercised on Try It.
    var shortcutLabel: String {
        KeyboardShortcuts.getShortcut(for: .dictate)?.description ?? "⌃⇧Space"
    }

    func next() {
        guard canContinue else { return }
        if flow.step == .permissions { stopAccessibilityPolling() }
        if flow.step == .tryIt {
            stopTrying { [weak self] in self?.finish() }
            return
        }
        if flow.step == .done { finish(); return }
        // Download starts when the Download step itself appears (DownloadScreen
        // .onAppear) — no preemptive background load during earlier steps.
        flow.step = OnboardingFlow.next(flow.step)
    }
    func back() {
        if flow.step == .permissions { stopAccessibilityPolling() }
        if flow.step == .tryIt { tryEnd() }                   // stop + restore onUpdate on leave
        flow.step = OnboardingFlow.back(flow.step)
    }

    func finish() {
        PostHogSDK.shared.capture("onboarding_completed", properties: [
            "accessibility_granted": flow.accessibilityGranted,
        ])
        UserDefaults.standard.set(true, forKey: Self.didOnboardKey)
        finished = true
        onFinished?()                 // boot the live menu app (mic granted, models cached)
        NSApp.keyWindow?.orderOut(nil)
    }
    func replay() {
        flow = OnboardingFlow.State(); finished = false; downloadError = nil
        tryConfirmed = ""; tryPartial = ""
        // Re-arm the download trigger; the models are already on disk from the first
        // run, so show the Download step as instantly complete instead of a 0-bar
        // soft-lock (the guard would otherwise early-return and never gate-open).
        downloadStarted = false
        if session.isReady(OnboardingFlow.modelPlan.mode) {
            for model in OnboardingFlow.modelPlan.models {
                flow.modelFractions[model.id] = 1
            }
        }
    }

    // MARK: permissions — mic (hard gate) + accessibility (skippable)

    /// Ask for microphone access; the system shows its dialog on first call and
    /// returns the cached answer after. Reflects the result into the flow gate.
    func requestMic() {
        if RuntimeEnvironment.isUITesting {
            flow.micGranted = true
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                self.flow.micGranted = ok
                if ok { PostHogSDK.shared.capture("mic_permission_granted") }
                self.onReactivate?()   // the TCC dialog stole focus — pull the window back
            }
        }
    }

    /// Show the Accessibility-trust prompt (deep-links to System Settings), then
    /// poll until the user flips it on — there's no AX-trust notification.
    func promptAccessibility() {
        if RuntimeEnvironment.isUITesting {
            if !RuntimeEnvironment.isOnboardingReview {
                flow.accessibilityGranted = true
            }
            return
        }
        _ = Accessibility.prompt()
        startAccessibilityPolling()
    }

    /// Reflect already-granted permissions when the screen appears, so a returning
    /// user sees "Granted" without re-prompting.
    func refreshPermissions() {
        if RuntimeEnvironment.isUITesting {
            flow.micGranted = true
            flow.accessibilityGranted = !RuntimeEnvironment.isOnboardingReview
            return
        }
        flow.micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        flow.accessibilityGranted = Accessibility.isTrusted
        if !flow.accessibilityGranted { startAccessibilityPolling() }
    }

    private func startAccessibilityPolling() {
        guard accPollTimer == nil else { return }
        accPollTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { _ in
            Task { @MainActor in
                let trusted = Accessibility.isTrusted
                let wasGranted = self.flow.accessibilityGranted
                self.flow.accessibilityGranted = trusted
                if trusted && !wasGranted { PostHogSDK.shared.capture("accessibility_permission_granted") }
                if self.flow.accessibilityGranted { self.stopAccessibilityPolling() }
            }
        }
    }

    func stopAccessibilityPolling() {
        accPollTimer?.invalidate()
        accPollTimer = nil
    }

    // MARK: download — plan-driven per-model progress

    /// Pre-download the onboarding plan with live per-model progress into the HF
    /// cache `*.fromPretrained` reads, then warm that pipeline (cache hit, no
    /// re-download). Triggered by the Download step's `.onAppear` (nothing loads
    /// before then); re-callable as Retry after `downloadError` clears `downloadStarted`.
    func startDownload() {
        guard !downloadStarted else { return }
        downloadStarted = true
        downloadError = nil
        if RuntimeEnvironment.isUITesting {
            for model in OnboardingFlow.modelPlan.models {
                flow.modelFractions[model.id] = 1
            }
            modelsReady = true
            return
        }
        PostHogSDK.shared.capture("model_download_started")
        Task {
            do {
                try await OnboardingDownloader.download(plan: OnboardingFlow.modelPlan) { progress in
                    // Monotonic: progress ticks arrive unordered (per-tick Tasks),
                    // so a stale sub-1.0 tick must never regress a finished lane —
                    // else the gate (both ≥ 1) could hang at full-looking bars (I1).
                    for (modelID, fraction) in progress.fractions {
                        self.flow.modelFractions[modelID] = max(
                            self.flow.modelFractions[modelID, default: 0],
                            fraction
                        )
                    }
                }
                try await self.session.load(mode: OnboardingFlow.modelPlan.mode)
                self.modelsReady = true                       // pipeline in memory → try-it button enables
                PostHogSDK.shared.capture("model_download_completed", properties: [
                    "total_gb": OnboardingFlow.totalGB,
                ])
            } catch {
                self.downloadError = error.localizedDescription
                self.downloadStarted = false                 // allow Retry
                PostHogSDK.shared.capture("model_download_failed", properties: [
                    "error_type": String(reflecting: type(of: error)),
                ])
            }
        }
    }

    /// Reset and re-run the download after a failure (Download screen "Retry").
    func retryDownload() {
        downloadError = nil
        // Only restart unfinished models — don't blink an already-cached
        // model's bar from 1 → 0 → 1 (I2). The monotonic max-clamp keeps it stable.
        for model in OnboardingFlow.modelPlan.models
            where flow.modelFractions[model.id, default: 0] < 1 {
            flow.modelFractions[model.id] = 0
        }
        modelsReady = session.isReady(OnboardingFlow.modelPlan.mode)
        startDownload()
    }

    // MARK: try-it — real in-window dictation using the onboarding plan

    /// Live two-tier transcript rendered into the try-it field (confirmed crisp +
    /// newest-word accent flash; partial in draft). Empty until the user holds.
    var tryConfirmed = ""
    var tryPartial = ""
    var tryListening = false
    var tryError: String?

    /// True once the Hybrid pipeline is loaded into memory (set after the Download
    /// step's `session.load`). Observable — so the try-it button re-enables the moment
    /// loading finishes, which lags the download bars (`session.isReady` isn't tracked).
    var modelsReady = false
    var tryReady: Bool { modelsReady }
    var canToggleTry: Bool { tryReady && !tryBusy }

    /// Independent observation of the shared session while try-it is active.
    @ObservationIgnored private var tryUpdateSubscription: DictationUpdateSubscription?

    /// True while a previous `tryEnd` is still draining `stop()` off-main. Blocks a
    /// rapid re-press from starting a new utterance before teardown finishes —
    /// otherwise it would overlap start()/stop() on the shared session.
    @ObservationIgnored private var tryBusy = false
    @ObservationIgnored private var tryIdleCallbacks: [@MainActor () -> Void] = []
    @ObservationIgnored private let tryHalo: any ListeningHaloControlling =
        ActiveDisplayHaloController()

    /// Press: borrow the warmed session, redirect its updates into our field, and
    /// start an utterance. No-op if the pipeline isn't ready, already live,
    /// or a previous stop is still draining.
    func tryStart() {
        if RuntimeEnvironment.isUITesting {
            guard modelsReady, !tryListening else { return }
            tryConfirmed = ""
            tryPartial = ""
            tryListening = true
            beginTryHaloIfNeeded()
            return
        }
        guard session.isReady(OnboardingFlow.modelPlan.mode), !tryListening, !tryBusy else { return }
        tryConfirmed = ""
        tryPartial = ""
        tryError = nil
        tryUpdateSubscription = session.observeUpdates { c, p in
            Task { @MainActor in
                self.tryConfirmed = c
                self.tryPartial = p
            }
        }
        do {
            try session.start(mode: OnboardingFlow.modelPlan.mode)
            tryListening = true
            beginTryHaloIfNeeded()
        } catch {
            tryListening = false
            tryHalo.dismiss()
            tryUpdateSubscription?.cancel()
            tryUpdateSubscription = nil
        }
    }

    /// Release: stop off-main (drains the backlog), settle the final text, mark the
    /// try-it gate, and restore the controller's HUD handler. Idempotent via the
    /// `tryListening` guard, so `.onDisappear` can call it safely.
    func tryEnd() {
        guard tryListening else { return }
        tryListening = false
        let completesWithHalo = TriggerMode.current == .toggle
        if completesWithHalo {
            tryHalo.stopListening()
        } else {
            tryHalo.dismiss()
        }
        if RuntimeEnvironment.isUITesting {
            tryConfirmed = "Write with your voice anywhere."
            tryPartial = ""
            flow.didTry = true
            if completesWithHalo {
                tryHalo.complete()
            }
            runTryIdleCallbacks()
            return
        }
        tryBusy = true
        tryUpdateSubscription?.cancel()
        tryUpdateSubscription = nil
        // Only the draining `stop()` goes off-main (like endRecording); capture
        // `session` directly so it doesn't touch main-actor `self` there.
        Task.detached(priority: .userInitiated) { [session] in
            let outcome = session.stop()
            await MainActor.run { [weak self] in
                guard let self else { return }
                if outcome.reason == .backlogOverload || outcome.reason == .captureFailure {
                    self.tryConfirmed = ""
                    self.tryPartial = ""
                    self.tryError = outcome.reason == .captureFailure
                        ? "Audio capture failed. Try again."
                        : "Dictation couldn’t keep up. Try a shorter sentence."
                    self.tryHalo.dismiss()
                    self.tryBusy = false
                    self.runTryIdleCallbacks()
                    return
                }
                self.tryConfirmed = outcome.text
                self.tryPartial = ""
                let wasFirst = !self.flow.didTry
                self.flow.didTry = self.flow.didTry || !outcome.text.isEmpty   // monotonic: one success is enough
                if wasFirst && !outcome.text.isEmpty {
                    PostHogSDK.shared.capture("try_it_completed")
                }
                if completesWithHalo, !outcome.text.isEmpty {
                    self.tryHalo.complete()
                } else {
                    self.tryHalo.dismiss()
                }
                self.tryBusy = false
                if outcome.reason == .maximumDuration {
                    self.tryError = "Maximum dictation length reached."
                }
                self.runTryIdleCallbacks()
            }
        }
    }

    /// Stop any onboarding utterance and run `completion` only after the shared
    /// session has fully drained. Runtime hotkey ownership must not resume sooner.
    func stopTrying(then completion: @escaping @MainActor () -> Void) {
        tryIdleCallbacks.append(completion)
        tryEnd()
        if !tryListening && !tryBusy {
            runTryIdleCallbacks()
        }
    }

    private func runTryIdleCallbacks() {
        guard !tryListening, !tryBusy else { return }
        let callbacks = tryIdleCallbacks
        tryIdleCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    /// Clear the try-it field for another attempt ("Try again"). Leaves `didTry`
    /// set — one success is enough to keep Continue unlocked.
    func tryReset() {
        tryConfirmed = ""
        tryPartial = ""
        tryHalo.dismiss()
    }

    /// VoiceOver can't hold a key — double-tap toggles the utterance instead.
    func tryToggle() {
        if tryListening { tryEnd() } else { tryStart() }
    }

    func tryHotkeyDown() {
        guard flow.step == .tryIt, !finished else { return }
        switch TriggerMode.current {
        case .hold: tryStart()
        case .toggle: tryToggle()
        }
    }

    func tryHotkeyUp() {
        guard flow.step == .tryIt, !finished else { return }
        if TriggerMode.current == .hold { tryEnd() }
    }

    private func beginTryHaloIfNeeded() {
        guard TriggerMode.current == .toggle else {
            tryHalo.dismiss()
            return
        }
        let activeDisplay = NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
        tryHalo.begin(on: activeDisplay)
    }

    /// Should onboarding be shown at launch?
    static var shouldShow: Bool {
        !UserDefaults.standard.bool(forKey: didOnboardKey)
    }
}
