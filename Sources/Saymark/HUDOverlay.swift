import AppKit
import Observation
import SwiftUI

/// Floating dictation HUD. A non-activating, click-through borderless NSPanel (we
/// type into another app's field at the same time) hosting a SwiftUI glass pill
/// that adapts to light/dark. Three states — listening,
/// transcribing (two-tier coloured text), error — plus a larger "presentation"
/// subtitle variant for HUD-only mode.

@Observable
final class HUDModel {
    enum Phase: Equatable { case listening, transcribing, error }
    var phase: Phase = .listening
    var confirmed = ""
    var partial = ""
    var rawTranscript = "" // memory only; cleared at the next HUD lifecycle boundary
    var correctionStatus = "unchanged"
    var correctionRevision: UInt64 = 0
    var showRawTranscript = false
    /// Saymark currently supports English only; this is product truth, not
    /// model language detection.
    var lang = "EN"
    var shortcutLabel = "⌃⇧Space"
    var errorTitle = "No microphone access"
    var errorText = "Open Privacy in Settings →"
    var recoveryActionTitle: String?
    var onRecoveryAction: () -> Void = {}
    var presentation = false      // HUD-only / subtitles
    var recording = false
    var showingFinal = false
    var completionNotice: String?
    var showStop = false          // toggle-mode: HUD shows a clickable Stop
    var onStop: () -> Void = {}

    /// Live captions stay compact. Final text is never line-truncated: the HUD
    /// expands and exposes the entire wrapped value in a native scroll view.
    var transcriptLineLimit: Int? { showingFinal ? nil : (presentation ? 6 : 3) }
    var usesScrollableTranscript: Bool { showingFinal }
    var showsCorrectionDetails: Bool {
        showingFinal && !rawTranscript.isEmpty &&
            (rawTranscript != confirmed || correctionStatus == "failedRawFallback")
    }
    var allowsFinalInteraction: Bool { showingFinal && (showsCorrectionDetails || requiresExpandedFinal) }
    var correctionSummary: String {
        switch correctionStatus {
        case "failedRawFallback":
            return "Vocabulary correction was unavailable. Your raw transcript was kept. Vocabulary revision \(correctionRevision)."
        case "corrected":
            return "Vocabulary correction was applied using revision \(correctionRevision)."
        default:
            return "No vocabulary correction was needed. Vocabulary revision \(correctionRevision)."
        }
    }
    var transcriptAccessibilityLabel: String {
        [confirmed, partial].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var requiresExpandedFinal: Bool {
        showingFinal && (transcriptAccessibilityLabel.count >= 180 ||
                         transcriptAccessibilityLabel.split(whereSeparator: \.isWhitespace).count >= 32)
    }

    var finalDisplayDuration: TimeInterval {
        guard showingFinal else { return 1.6 }
        let words = transcriptAccessibilityLabel.split(whereSeparator: \.isWhitespace).count
        // A final result should read as a stable completion state, not a flash.
        // Long dictations linger longer, while the cap keeps the HUD temporary.
        let readingTime = min(12.0, max(3.2, 2.4 + Double(words) * 0.045))
        return showsCorrectionDetails ? max(8.0, readingTime) : readingTime
    }

    func copyRawTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rawTranscript, forType: .string)
    }
}

// MARK: - Building blocks

/// Animated activity bars (scaleY .32↔1, staggered).
private struct LevelBars: View {
    var color: Color
    var count: Int = 4
    var barHeight: CGFloat = 13
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< count, id: \.self) { i in
                Capsule().fill(color)
                    .frame(width: 2.5, height: barHeight)
                    .scaleEffect(y: (up || reduceMotion) ? 1 : 0.32, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.12), value: up)
            }
        }
        .onAppear { up = true }
        .accessibilityHidden(true)
    }
}

/// Static status dot; the adjacent level bars carry the listening motion.
private struct StatusDot: View {
    var color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

private func brandIcon(_ size: CGFloat) -> some View {
    Image(systemName: "waveform")
        .resizable().scaledToFit().symbolRenderingMode(.hierarchical)
        .foregroundStyle(SaymarkTheme.accent)
        .frame(width: size, height: size)
}

// MARK: - HUD view

private struct HUDView: View {
    let model: HUDModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Group {
            switch model.phase {
            case .error:        errorPill
            case .listening:    listeningPill
            case .transcribing: transcribePill
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 30)
        .padding(.horizontal, 40)
    }

    // Header: Saymark glyph + animated bars + language badge.
    private var header: some View {
        HStack(spacing: 10) {
            brandIcon(18)
            if model.showingFinal {
                Label("Transcribed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(SaymarkTheme.accent)
            } else {
                LevelBars(color: SaymarkTheme.accent, count: 4, barHeight: 13)
            }
            Spacer(minLength: 8)
            Text(model.lang.uppercased())
                .font(.system(size: 10, weight: .medium)).tracking(0.4)
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.4) : SaymarkTheme.ink.opacity(0.5))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(scheme == .dark ? Color.white.opacity(0.08) : SaymarkTheme.ink.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            if model.showStop { stopButton }
        }
    }

    /// Clickable Stop (toggle mode). The panel accepts mouse events while this shows.
    private var stopButton: some View {
        Button(action: model.onStop) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.85) : SaymarkTheme.ink.opacity(0.7))
                .frame(width: 22, height: 22)
                .background(Circle().fill(scheme == .dark ? Color.white.opacity(0.12) : SaymarkTheme.ink.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop dictation")
        .accessibilityHint("Stops recording and finalizes the transcript")
    }

    // Two-tier coloured transcript + blinking accent caret.
    private var transcribePill: some View {
        let big = model.presentation
        return VStack(alignment: .leading, spacing: big ? 12 : 9) {
            header
            if model.showsCorrectionDetails {
                DisclosureGroup(
                    model.correctionStatus == "failedRawFallback" ? "Correction details" : "Raw transcript",
                    isExpanded: Bindable(model).showRawTranscript
                ) {
                    Text(model.correctionSummary)
                        .foregroundStyle(.secondary)
                    Text(model.rawTranscript).textSelection(.enabled)
                    Button("Copy raw transcript") { model.copyRawTranscript() }
                }
                .accessibilityLabel("Raw transcript disclosure")
            }
            if model.showingFinal {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        transcript
                            .font(.system(size: big ? 25 : 19))
                            .lineSpacing(big ? 7 : 5)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("hud.final-transcript")
                            .accessibilityLabel(model.transcriptAccessibilityLabel)
                        if let notice = model.completionNotice {
                            Label(notice, systemImage: "clock.badge.checkmark")
                                .font(.system(size: big ? 13 : 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("hud.completion-notice")
                        }
                    }
                }
                .scrollIndicators(.automatic)
                .frame(maxHeight: big ? 300 : 220)
                .accessibilityIdentifier("hud.final-transcript-scroll")
            } else {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                    (transcript + Text("▏").foregroundStyle(SaymarkTheme.accent.opacity(on ? 1 : 0)))
                        .font(.system(size: big ? 30 : 21))
                        .lineSpacing(big ? 8 : 6)
                        .lineLimit(model.transcriptLineLimit)
                        .truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("hud.live-transcript")
                }
            }
        }
        .padding(.horizontal, big ? 24 : 16)
        .padding(.vertical, big ? 18 : 13)
        .frame(maxWidth: big ? 820 : 460, alignment: .leading)
        .saymarkPill(scheme, radius: big ? 18 : 16, border: borderColor)
    }

    private var transcript: Text {
        let crisp = SaymarkTheme.crisp(scheme), draft = SaymarkTheme.draft(scheme)
        let conf = Self.words(model.confirmed)
        let part = Self.words(model.partial)
        var t = Text("")
        for (i, w) in conf.enumerated() {
            // Approximated "refine flash": the newest confirmed word glows accent.
            let hot = i == conf.count - 1
            t = t + Text(w).foregroundColor(hot ? SaymarkTheme.accent : crisp).fontWeight(.medium) + Text(" ")
        }
        for w in part {
            t = t + Text(w).foregroundColor(draft).fontWeight(.regular) + Text(" ")
        }
        if conf.isEmpty, part.isEmpty {
            let status = model.recording ? "Listening…" : "Transcribing…"
            return Text(status).foregroundColor(draft)
        }
        return t
    }

    private var listeningPill: some View {
        HStack(spacing: 13) {
            StatusDot(color: SaymarkTheme.accent, size: 8)
            Text("Listening…").font(.system(size: 15))
                .foregroundStyle(scheme == .dark ? Color.white.opacity(0.92) : SaymarkTheme.ink)
            LevelBars(color: SaymarkTheme.accent, count: 5, barHeight: 16)
            if model.showStop { stopButton } else { hotkeyBadge }
        }
        .padding(.horizontal, 17).padding(.vertical, 11)
        .saymarkPill(scheme, radius: 14, border: borderColor)
    }

    private var errorPill: some View {
        HStack(spacing: 12) {
            brandIcon(22).overlay(alignment: .bottomTrailing) {
                Circle().fill(SaymarkTheme.error).frame(width: 12, height: 12)
                    .overlay(Text("!").font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                    .offset(x: 4, y: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.errorTitle).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.95) : SaymarkTheme.ink)
                Text(model.errorText).font(.system(size: 11.5))
                    .foregroundStyle(scheme == .dark ? Color.white.opacity(0.55) : SaymarkTheme.ink.opacity(0.6))
                if let title = model.recoveryActionTitle {
                    Button(title, action: model.onRecoveryAction)
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(SaymarkTheme.accent)
                        .padding(.top, 4)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .saymarkPill(scheme, radius: 14, border: SaymarkTheme.error.opacity(0.4))
    }

    private var hotkeyBadge: some View {
        Text(model.shortcutLabel).font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : SaymarkTheme.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : SaymarkTheme.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityLabel("Dictation shortcut \(model.shortcutLabel)")
    }

    private var borderColor: Color {
        scheme == .dark ? Color.white.opacity(0.1) : SaymarkTheme.ink.opacity(0.1)
    }

    private static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}

/// Native material pill with a hairline border and shallow separation shadow.
private extension View {
    func saymarkPill(_ scheme: ColorScheme, radius: CGFloat, border: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(.regularMaterial, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            .shadow(color: .black.opacity(scheme == .dark ? 0.28 : 0.12), radius: 8, y: 3)
    }
}

// MARK: - Panel controller

@MainActor
protocol HUDHideScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> HUDCancellation
}

final class HUDCancellation {
    private let action: () -> Void
    private(set) var isCancelled = false

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        action()
    }
}

@MainActor
final class DispatchHUDHideScheduler: HUDHideScheduling {
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> HUDCancellation {
        let work = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return HUDCancellation { work.cancel() }
    }
}

@MainActor
protocol HUDAnimating {
    func show(_ panel: NSPanel)
    func hide(_ panel: NSPanel, completion: @escaping @MainActor () -> Void)
}

@MainActor
final class AppKitHUDAnimator: HUDAnimating {
    func show(_ panel: NSPanel) {
        // Hotkey feedback must be visible in the same main-thread turn. Starting
        // at alpha zero made the 180 ms fade feel like the shortcut was ignored.
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func hide(_ panel: NSPanel, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup({
            $0.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { completion() }
        })
    }
}

@MainActor
final class HUDController {
    private(set) var model = HUDModel()
    private(set) var panel: NSPanel?
    private(set) var presentationID = 0
    private var hideWork: HUDCancellation?
    private let scheduler: any HUDHideScheduling
    private let animator: any HUDAnimating
    private let halo: any ListeningHaloControlling
    private let activeScreenProvider: @MainActor () -> NSScreen?
    private weak var activeScreen: NSScreen?
    var announcementSink: (String) -> Void = { message in
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
    private(set) var isListeningHaloVisible = false
    private var completesWithHalo = false
    private let normalSize = NSSize(width: 940, height: 260)
    private let presentationSize = NSSize(width: 940, height: 380)
    private let expandedFinalSize = NSSize(width: 940, height: 410)
    private let expandedPresentationFinalSize = NSSize(width: 940, height: 510)
    var hasAttachedViewTree: Bool { panel?.contentView != nil }

    convenience init() {
        self.init(
            scheduler: DispatchHUDHideScheduler(),
            animator: AppKitHUDAnimator(),
            halo: ActiveDisplayHaloController()
        )
    }

    convenience init(scheduler: any HUDHideScheduling, animator: any HUDAnimating) {
        self.init(
            scheduler: scheduler,
            animator: animator,
            halo: ActiveDisplayHaloController()
        )
    }

    init(scheduler: any HUDHideScheduling,
         animator: any HUDAnimating,
         halo: any ListeningHaloControlling,
         activeScreenProvider: @escaping @MainActor () -> NSScreen? = HUDController.pointerScreen) {
        self.scheduler = scheduler
        self.animator = animator
        self.halo = halo
        self.activeScreenProvider = activeScreenProvider
    }

    /// Reveal the HUD for a new utterance. `interactive` (toggle mode) makes the
    /// panel accept clicks so the Stop button works.
    func begin(
        presentation: Bool,
        lang: String,
        shortcutLabel: String = "⌃⇧Space",
        interactive: Bool = false,
        onStop: @escaping () -> Void = {}
    ) {
        hideWork?.cancel(); hideWork = nil
        presentationID += 1
        let size = presentation ? presentationSize : normalSize
        let panel = ensurePanel(size: size)
        panel.setContentSize(size)
        model.presentation = presentation
        model.lang = lang
        model.shortcutLabel = shortcutLabel
        model.phase = .listening
        model.confirmed = ""; model.partial = ""; model.rawTranscript = ""; model.showRawTranscript = false
        model.correctionStatus = "unchanged"; model.correctionRevision = 0
        model.recording = true
        model.showingFinal = false
        model.completionNotice = nil
        model.showStop = interactive
        model.onStop = onStop
        model.recoveryActionTitle = nil
        model.onRecoveryAction = {}
        panel.ignoresMouseEvents = !interactive
        activeScreen = activeScreenProvider()
        position(panel)
        animator.show(panel)
        announcementSink("Listening")
        completesWithHalo = interactive
        isListeningHaloVisible = interactive
        if interactive {
            halo.begin(on: activeScreen)
        } else {
            halo.dismiss()
        }
    }

    /// Live two-tier update.
    func update(confirmed: String, partial: String, rawConfirmed: String? = nil, rawPartial: String? = nil,
                correctionStatus: String? = nil, correctionRevision: UInt64? = nil) {
        model.showingFinal = false
        model.completionNotice = nil
        model.confirmed = confirmed
        model.partial = partial
        if let rawConfirmed, let rawPartial { model.rawTranscript = rawConfirmed + rawPartial }
        if let correctionStatus { model.correctionStatus = correctionStatus }
        if let correctionRevision { model.correctionRevision = correctionRevision }
        if model.phase != .error {
            model.phase = (confirmed.isEmpty && partial.isEmpty) ? .listening : .transcribing
        }
    }

    /// Release is a real visual state, not a blank gap while final decoding runs.
    func processing() {
        guard panel != nil else { return }
        hideWork?.cancel(); hideWork = nil
        model.phase = .transcribing
        model.confirmed = ""
        model.partial = ""
        model.rawTranscript = ""; model.showRawTranscript = false
        model.recording = false
        model.showingFinal = false
        model.completionNotice = nil
        model.showStop = false
        announcementSink("Processing dictation")
        if isListeningHaloVisible {
            halo.stopListening()
            isListeningHaloVisible = false
        }
    }

    /// Surface a mic/permission error in the HUD.
    func error(_ text: String) {
        error(title: "No microphone access", detail: text, hideAfter: 3.2)
    }

    /// Surface a specific actionable outcome (for example, copied because macOS
    /// Accessibility trust is missing) and leave it visible long enough to read.
    func error(title: String, detail: String, hideAfter delay: TimeInterval = 3.2) {
        hideWork?.cancel(); hideWork = nil
        presentationID += 1
        let panel = ensurePanel(size: normalSize)
        model.phase = .error
        model.errorTitle = title
        if !detail.isEmpty { model.errorText = detail }
        model.recording = false
        model.showingFinal = false
        model.completionNotice = nil
        model.showStop = false
        model.recoveryActionTitle = nil
        model.onRecoveryAction = {}
        halo.dismiss()
        isListeningHaloVisible = false
        completesWithHalo = false
        position(panel)
        animator.show(panel)
        announcementSink([title, detail].filter { !$0.isEmpty }.joined(separator: ". "))
        scheduleHide(after: delay)
    }

    /// Failure recovery is opt-in and only offered after a final row committed.
    /// The action contains no transcript text and is never used for protected
    /// fields, HUD-only dictation, History Off, or a deadline miss.
    func offerRecentDictationsRecovery(_ action: @escaping () -> Void) {
        guard model.phase == .error, panel != nil else { return }
        hideWork?.cancel()
        model.recoveryActionTitle = "Open Recent Dictations"
        model.onRecoveryAction = { [weak self] in
            action()
            self?.panel?.orderOut(nil)
        }
        panel?.ignoresMouseEvents = false
        announcementSink("Open Recent Dictations is available")
        scheduleHide(after: 7.0)
    }

    /// Show the final text, then fade — lingering longer in presentation mode.
    func finish(_ finalText: String, rawText: String? = nil, correctionStatus: String? = nil,
                correctionRevision: UInt64? = nil, completionNotice: String? = nil) {
        guard panel != nil else { return }
        model.recording = false
        model.showStop = false
        if !finalText.isEmpty {
            model.confirmed = finalText
            model.partial = ""
            model.rawTranscript = rawText ?? finalText
            if let correctionStatus { model.correctionStatus = correctionStatus }
            if let correctionRevision { model.correctionRevision = correctionRevision }
            model.showRawTranscript = false
            model.showingFinal = true
            model.completionNotice = completionNotice
            model.phase = .transcribing
            panel?.ignoresMouseEvents = !model.allowsFinalInteraction
            if model.requiresExpandedFinal, let panel {
                let size = model.presentation ? expandedPresentationFinalSize : expandedFinalSize
                panel.setContentSize(size)
                position(panel)
            }
        }
        if completesWithHalo, !finalText.isEmpty {
            halo.complete()
        } else {
            halo.dismiss()
        }
        isListeningHaloVisible = false
        completesWithHalo = false
        if !finalText.isEmpty {
            let completion = model.presentation ? "Dictation complete. \(finalText)" : "Dictation complete"
            announcementSink([completion, completionNotice].compactMap { $0 }.joined(separator: ". "))
        }
        let delay = model.showingFinal
            ? model.finalDisplayDuration
            : (model.presentation ? 4.0 : 1.6)
        scheduleHide(after: delay)
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWork?.cancel()
        let presentationID = presentationID
        hideWork = scheduler.schedule(after: delay) { [weak self] in
            self?.fadeOut(presentationID: presentationID)
        }
    }

    private func fadeOut(presentationID: Int) {
        guard presentationID == self.presentationID, let panel else { return }
        hideWork = nil
        animator.hide(panel) { [weak self, weak panel] in
            guard let self, let panel,
                  presentationID == self.presentationID, panel === self.panel else { return }
            panel.orderOut(nil)

            // `orderOut` only hides the panel. Keeping its NSHostingView attached leaves
            // SwiftUI's repeat-forever bars and TimelineView rendering off-screen forever.
            // Release the view tree so those display updates stop while Saymark is idle.
            panel.contentView = nil
            self.panel = nil
        }
    }

    private func ensurePanel(size: NSSize) -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        let host = NSHostingView(rootView: HUDView(model: model))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        guard let screen = activeScreen ?? activeScreenProvider() else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrame(Self.frame(panelSize: size, visibleFrame: v), display: true)
    }

    static func pointerScreen() -> NSScreen? {
        NSScreen.screens.first {
            NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
        } ?? NSScreen.main
    }

    static func frame(panelSize: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(x: visibleFrame.midX - panelSize.width / 2,
               y: visibleFrame.minY + 24,
               width: panelSize.width,
               height: panelSize.height)
    }
}
