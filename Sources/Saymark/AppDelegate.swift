import AppKit
import SaymarkKit
import PostHog
import SwiftUI

// PostHog project (ingestion) key — injected into Info.plist at `tuist generate` time from
// TUIST_SAYMARK_POSTHOG_KEY (see Project.swift). Empty in plain source/fork builds, so analytics
// stays dark unless the maintainer's build supplies it. It's a write-only client key (not a
// secret); keeping it out of source just means forks don't phone home to our project.
private var posthogApiKey: String {
    Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String ?? ""
}
private let posthogHost = "https://eu.i.posthog.com"

/// Runs Saymark as a menu-bar agent, owns the dictation controller, and hosts the
/// onboarding window.
///
/// `.accessory` keeps the process alive in the background (so the global hotkey
/// keeps working) while staying out of the Dock and ⌘-Tab switcher.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let dictation = DictationController()
    private let resourceMonitor = ProcessResourceMonitor()

    /// Drives the onboarding window. Lazy so it builds after `dictation` exists,
    /// reusing the controller's already-warmed `DictationSession`.
    lazy var onboarding = OnboardingModel(session: dictation.dictationSession)

    private var onboardingWindow: NSWindow?
    private var didStartMenuApp = false
    #if DEBUG
    private var dailyDriverUITestHarness: DailyDriverUITestHarness?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLogSetting.configure()
        Task {
            // Durable store metadata is the sole policy authority. History
            // remains unavailable until open, validation, and launch purge
            // finish for every retained policy.
            await RecentDictationsController.shared.initializeAtLaunch()
            await RecentDictationsController.shared.prepareForDelivery()
            RecentDictationsController.shared.configureIdleMaintenance { [weak self] in
                self?.dictation.isActive ?? false
            }
            RecentDictationsController.shared.startRecurringIdleMaintenance()
        }
        SaymarkDiagnostics.log(.info, "app.launched", fields: [
            "bundle_id": Bundle.main.bundleIdentifier ?? "unknown",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
            "physical_memory_bytes": Int64(ProcessInfo.processInfo.physicalMemory),
            "log_level": SaymarkDiagnostics.level.name,
        ])
        resourceMonitor.start()

        // Analytics is optional: no API key → never initialize (e.g. a privacy/App
        // Store build); key present but consent off → set up then opt out, which makes
        // every `capture(…)` a no-op. Audio/transcripts are never sent regardless.
        if !posthogApiKey.isEmpty {
            let config = PostHogConfig(projectToken: posthogApiKey, host: posthogHost)
            config.captureApplicationLifecycleEvents = true
            PostHogSDK.shared.setup(config)
            // Sync PostHog to our consent (opt-in: off until enabled on Welcome).
            if AnalyticsConsent.enabled { PostHogSDK.shared.optIn() } else { PostHogSDK.shared.optOut() }
        }

        // Router: first run → onboarding ONLY, as a REGULAR app (Dock icon, ⌘-Tab,
        // normal focus — so a TCC permission dialog can't bury the window beyond
        // recovery). The live menu app (hotkey, mic prompt, model warm-up) boots —
        // and the app drops to a `.accessory` menu-bar agent — only when onboarding
        // finishes. A returning user goes straight to the menu app.
        onboarding.onFinished = { [weak self] in
            self?.dictation.reclaimHotkeyFromOnboarding()
            self?.startMenuApp()
        }
        onboarding.onReactivate = { [weak self] in self?.presentOnboarding() }
        dictation.onboardingHotkeyDown = { [weak self] in self?.onboarding.tryHotkeyDown() }
        dictation.onboardingHotkeyUp = { [weak self] in self?.onboarding.tryHotkeyUp() }
        dictation.installHotkeyRouting()
        if OnboardingModel.shouldShow {
            SaymarkDiagnostics.log(.info, "app.route", fields: ["destination": "onboarding"])
            NSApp.setActivationPolicy(.regular)
            PostHogSDK.shared.capture("onboarding_started")
            dictation.handOffHotkeyToOnboarding { [weak self] in self?.presentOnboarding() }
        } else {
            SaymarkDiagnostics.log(.info, "app.route", fields: ["destination": "menu"])
            startMenuApp()
        }
    }

    /// Become the menu-bar agent (no Dock icon) and wire up live dictation. Idempotent
    /// — for a first run this runs once onboarding completes (mic granted, models
    /// cached), for a returning user it runs at launch.
    private func startMenuApp() {
        guard !didStartMenuApp else {
            SaymarkDiagnostics.log(.debug, "app.menu_start_ignored", fields: ["reason": "already_started"])
            return
        }
        didStartMenuApp = true
        #if DEBUG
        // A returning-user daily-driver UI test must remain a foreground app so
        // XCTest can focus its window and emit the real registered shortcut.
        // Production still transitions to `.accessory` immediately below.
        if RuntimeEnvironment.isDailyDriverUITesting {
            NSApp.setActivationPolicy(.regular)
            SaymarkDiagnostics.log(.debug, "app.menu_started", fields: ["ui_testing": true])
            let harness = DailyDriverUITestHarness(dictation: dictation)
            dailyDriverUITestHarness = harness
            harness.present()
            return
        }
        #endif
        NSApp.setActivationPolicy(.accessory)
        guard !RuntimeEnvironment.isUITesting else {
            SaymarkDiagnostics.log(.debug, "app.menu_started", fields: ["ui_testing": true])
            return
        }
        SaymarkDiagnostics.log(.info, "app.menu_started", fields: ["ui_testing": false])
        dictation.bootstrap()
    }

    /// Show (or re-show) the onboarding window. AppKit-owned `NSWindow` rather than a
    /// SwiftUI `Window` scene: a menu-bar (`.accessory`) app can't open a scene window
    /// reliably at launch, and a scene window hides on deactivation. This one persists
    /// (`isReleasedWhenClosed = false`) so "Setup tour…" can re-open it.
    func presentOnboarding() {
        let window = onboardingWindow ?? makeOnboardingWindow()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    /// "Setup tour…" — reset to Welcome, then present.
    func replayOnboarding() {
        dictation.handOffHotkeyToOnboarding { [weak self] in
            guard let self else { return }
            self.onboarding.stopTrying { [weak self] in
                guard let self else { return }
                self.onboarding.replay()
                self.presentOnboarding()
            }
        }
    }

    private func makeOnboardingWindow() -> NSWindow {
        let size = NSSize(width: 680, height: 500)
        let host = NSHostingController(rootView: OnboardingView(model: onboarding).frame(
            width: size.width,
            height: size.height
        ))
        let window = NSWindow(contentViewController: host)
        window.title = "Saymark Setup"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = false
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Closing the setup window before finishing (initial onboarding) cancels setup →
    /// quit, so the app never lingers half-configured. A returning user's "Setup tour…"
    /// replay (menu app already running) just closes the window.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === onboardingWindow else { return }
        if !didStartMenuApp {
            NSApp.terminate(nil)
        } else {
            onboarding.stopTrying { [weak self] in
                self?.dictation.reclaimHotkeyFromOnboarding()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecentDictationsController.shared.clearSessionAtTermination()
        resourceMonitor.stop()
        SaymarkDiagnostics.log(.info, "app.terminating")
    }
}
