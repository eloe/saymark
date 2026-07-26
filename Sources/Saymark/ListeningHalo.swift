import AppKit
import Observation
import SwiftUI

/// A quiet, system-wide recording affordance for Start/Stop mode. The edge
/// appears only on the active display, never accepts input, and settles after
/// one short bloom rather than continuously pulsing.
@MainActor
protocol ListeningHaloControlling {
    func begin(on screen: NSScreen?)
    func stopListening()
    func complete()
    func dismiss()
}

@Observable
private final class ListeningHaloModel {
    enum Tone { case listening, complete }

    var tone: Tone = .listening
    var blooming = true
}

private struct ListeningHaloView: View {
    let model: ListeningHaloModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        switch model.tone {
        case .listening: SaymarkTheme.accent
        case .complete: .green
        }
    }

    var body: some View {
        Rectangle()
            .strokeBorder(
                color.opacity(model.blooming && !reduceMotion ? 0.72 : 0.38),
                lineWidth: model.blooming && !reduceMotion ? 3 : 1.5
            )
            .shadow(
                color: color.opacity(model.blooming && !reduceMotion ? 0.55 : 0.20),
                radius: model.blooming && !reduceMotion ? 14 : 5
            )
            .padding(2)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.45),
                value: model.blooming
            )
            .allowsHitTesting(false)
    }
}

@MainActor
final class ActiveDisplayHaloController: ListeningHaloControlling {
    private let model = ListeningHaloModel()
    private var panel: NSPanel?
    private weak var display: NSScreen?
    private var settleWork: DispatchWorkItem?
    private var completionWork: DispatchWorkItem?
    private var generation = 0

    func begin(on screen: NSScreen?) {
        guard let screen else { return }
        cancelPendingWork()
        generation += 1
        display = screen

        let panel = ensurePanel()
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 1
        model.tone = .listening
        model.blooming = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.orderFrontRegardless()

        guard model.blooming else { return }
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.model.blooming = false
                self.settleWork = nil
            }
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func stopListening() {
        generation += 1
        cancelPendingWork()
        panel?.orderOut(nil)
    }

    func complete() {
        guard let display else { return }
        cancelPendingWork()
        generation += 1
        let expectedGeneration = generation

        let panel = ensurePanel()
        panel.setFrame(display.frame, display: true)
        panel.alphaValue = 1
        model.tone = .complete
        model.blooming = false
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.55
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        }

        let work = DispatchWorkItem { [weak self, weak panel] in
            MainActor.assumeIsolated {
                guard let self, let panel, self.generation == expectedGeneration else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
                self.completionWork = nil
            }
        }
        completionWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func dismiss() {
        generation += 1
        cancelPendingWork()
        panel?.orderOut(nil)
    }

    private func cancelPendingWork() {
        settleWork?.cancel()
        settleWork = nil
        completionWork?.cancel()
        completionWork = nil
        panel?.alphaValue = 1
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true

        let host = NSHostingView(rootView: ListeningHaloView(model: model))
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}
