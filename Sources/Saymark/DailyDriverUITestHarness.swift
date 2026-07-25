#if DEBUG
import AppKit
import Observation
import SwiftUI

@MainActor
@Observable
private final class DailyDriverUITestModel {
    static let transcript = """
    First, Saymark keeps the full thought visible while I continue speaking. \
    Second, releasing the shortcut moves the HUD into a clear processing state. \
    Third, the final transcript is delivered exactly once without losing clipboard data.
    """

    var status = "ready"
    var isRunning = false
}

@MainActor
final class DailyDriverUITestHarness: NSObject, NSWindowDelegate {
    private let dictation: DictationController
    private let model = DailyDriverUITestModel()
    private var window: NSWindow?
    private var originalPasteboardItems: [[NSPasteboard.PasteboardType: Data]] = []

    init(dictation: DictationController) {
        self.dictation = dictation
        super.init()
    }

    func present() {
        let view = DailyDriverUITestView(
            model: model,
            run: { [weak self] in self?.run() }
        )
        let host = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: host)
        window.title = "Saymark Daily Driver Test"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 660, height: 420))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func run() {
        guard !model.isRunning else { return }
        model.isRunning = true
        model.status = ""
        originalPasteboardItems = Self.capturePasteboard()

        dictation.runDailyDriverUITest(
            finalText: DailyDriverUITestModel.transcript,
            onStatus: { [weak self] status in
                guard let self else { return }
                if self.model.status.isEmpty {
                    self.model.status = status
                } else {
                    self.model.status += "|\(status)"
                }
                if status.hasPrefix("T") {
                    self.model.isRunning = false
                }
            }
        )
    }

    func windowWillClose(_ notification: Notification) {
        restorePasteboard()
    }

    private static func capturePasteboard() -> [[NSPasteboard.PasteboardType: Data]] {
        NSPasteboard.general.pasteboardItems?.map { item in
            Dictionary(
                uniqueKeysWithValues: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                }
            )
        } ?? []
    }

    private func restorePasteboard() {
        guard !originalPasteboardItems.isEmpty else { return }
        let items = originalPasteboardItems.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(items)
        originalPasteboardItems = []
    }
}

private struct DailyDriverUITestView: View {
    let model: DailyDriverUITestModel
    let run: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Daily-driver integration")
                .font(.title2.weight(.semibold))
            Text("Deterministic UI test: no microphone, model, network, or Accessibility permission.")
                .foregroundStyle(.secondary)

            GroupBox("Expected final transcript") {
                Text(DailyDriverUITestModel.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityIdentifier("daily-driver.expected-transcript")
            }

            Text(model.status)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            Spacer()
            Button(model.isRunning ? "Running…" : "Run deterministic dictation", action: run)
                .disabled(model.isRunning)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("daily-driver.run")
        }
        .padding(24)
        .frame(width: 660, height: 420)
    }
}
#endif
