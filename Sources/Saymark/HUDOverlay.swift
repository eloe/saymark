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
    var lang = "Auto"
    var errorTitle = "No microphone access"
    var errorText = "Open Privacy in Settings →"
    var presentation = false      // HUD-only / subtitles
    var recording = false
    var showStop = false          // toggle-mode: HUD shows a clickable Stop
    var onStop: () -> Void = {}

    /// Rolling caption bounds: compact dictation stays unobtrusive; HUD-only
    /// presentation gets enough room for several sentences.
    var transcriptLineLimit: Int { presentation ? 6 : 3 }
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
            LevelBars(color: SaymarkTheme.accent, count: 4, barHeight: 13)
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
    }

    // Two-tier coloured transcript + blinking accent caret.
    private var transcribePill: some View {
        let big = model.presentation
        return VStack(alignment: .leading, spacing: big ? 12 : 9) {
            header
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let on = Int(ctx.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
                (transcript + Text("▏").foregroundStyle(SaymarkTheme.accent.opacity(on ? 1 : 0)))
                    .font(.system(size: big ? 30 : 21))
                    .lineSpacing(big ? 8 : 6)
                    .lineLimit(model.transcriptLineLimit)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .saymarkPill(scheme, radius: 14, border: SaymarkTheme.error.opacity(0.4))
    }

    private var hotkeyBadge: some View {
        Text("⌥ Space").font(.system(size: 11, design: .monospaced))
            .foregroundStyle(scheme == .dark ? Color.white.opacity(0.5) : SaymarkTheme.ink.opacity(0.55))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(scheme == .dark ? Color.white.opacity(0.09) : SaymarkTheme.ink.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
    private(set) var isListeningHaloVisible = false
    private var completesWithHalo = false
    private let normalSize = NSSize(width: 940, height: 260)
    private let presentationSize = NSSize(width: 940, height: 380)
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
         halo: any ListeningHaloControlling) {
        self.scheduler = scheduler
        self.animator = animator
        self.halo = halo
    }

    /// Reveal the HUD for a new utterance. `interactive` (toggle mode) makes the
    /// panel accept clicks so the Stop button works.
    func begin(presentation: Bool, lang: String, interactive: Bool = false, onStop: @escaping () -> Void = {}) {
        hideWork?.cancel(); hideWork = nil
        presentationID += 1
        let size = presentation ? presentationSize : normalSize
        let panel = ensurePanel(size: size)
        panel.setContentSize(size)
        model.presentation = presentation
        model.lang = lang
        model.phase = .listening
        model.confirmed = ""; model.partial = ""
        model.recording = true
        model.showStop = interactive
        model.onStop = onStop
        panel.ignoresMouseEvents = !interactive
        position(panel)
        animator.show(panel)
        completesWithHalo = interactive
        isListeningHaloVisible = interactive
        if interactive {
            let activeDisplay = NSScreen.screens.first {
                NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
            } ?? NSScreen.main
            halo.begin(on: activeDisplay)
        } else {
            halo.dismiss()
        }
    }

    /// Live two-tier update.
    func update(confirmed: String, partial: String) {
        model.confirmed = confirmed
        model.partial = partial
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
        model.recording = false
        model.showStop = false
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
        model.showStop = false
        halo.dismiss()
        isListeningHaloVisible = false
        completesWithHalo = false
        position(panel)
        animator.show(panel)
        scheduleHide(after: delay)
    }

    /// Show the final text, then fade — lingering longer in presentation mode.
    func finish(_ finalText: String) {
        guard panel != nil else { return }
        model.recording = false
        model.showStop = false
        if !finalText.isEmpty {
            model.confirmed = finalText; model.partial = ""; model.phase = .transcribing
        }
        if completesWithHalo, !finalText.isEmpty {
            halo.complete()
        } else {
            halo.dismiss()
        }
        isListeningHaloVisible = false
        completesWithHalo = false
        scheduleHide(after: model.presentation ? 4.0 : 1.6)
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
        guard let screen = NSScreen.main else { return }
        let v = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrame(NSRect(x: v.midX - size.width / 2, y: v.minY + 24,
                              width: size.width, height: size.height), display: true)
    }
}
