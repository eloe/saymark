#if DEBUG
import AppKit
import Observation
@_spi(Testing) import SaymarkKit
import SwiftUI

private struct DailyDriverTargetResult: Identifiable, Equatable {
    let id: String
    var deliveries = 0
    var restoredClipboards = 0
    var exactOnce = false
}

@MainActor
@Observable
private final class DailyDriverUITestModel {
    static let transcript = """
    First, Saymark keeps the full thought visible while I continue speaking. \
    Second, releasing the shortcut moves the HUD into a clear processing state. \
    Third, the final transcript is delivered exactly once without losing clipboard data.
    """

    let scenario = RuntimeEnvironment.dailyDriverScenario
    var status = ""
    var targetText = ""
    var deliveryCount = 0
    var clipboardValue = ""
    var isRunning = false
    var targets = [
        DailyDriverTargetResult(id: "native-text-view"),
        DailyDriverTargetResult(id: "web-textarea"),
        DailyDriverTargetResult(id: "electron-field"),
        DailyDriverTargetResult(id: "terminal"),
    ]

    func appendStatus(_ value: String) {
        status = status.isEmpty ? value : "\(status)|\(value)"
        if value == "KD" { isRunning = true }
        if value.hasPrefix("T") { isRunning = false }
    }
}

/// A deterministic host around the production hotkey/HUD/delivery lifecycle.
/// XCUITest generates the real registered Carbon shortcut. Only microphone,
/// model inference, Accessibility trust, secure-input state, and the receiving
/// app boundary are substituted.
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
        originalPasteboardItems = Self.capturePasteboard()
        let host = NSHostingController(rootView: DailyDriverUITestView(model: model))
        let window = NSWindow(contentViewController: host)
        window.title = "Saymark Daily Driver Test"
        window.identifier = NSUserInterfaceItemIdentifier("daily-driver.window")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 700, height: 500))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.regular)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.makeKeyAndOrderFront(nil)
        }

        let finalText = model.scenario == "no-speech" ? "" : DailyDriverUITestModel.transcript
        dictation.prepareDailyDriverUITest(
            DailyDriverUITestConfiguration(
                finalText: finalText,
                onStatus: { [weak self] in self?.model.appendStatus($0) },
                deliver: { [weak self] text, completion in
                    self?.deliver(text, completion: completion)
                }
            )
        )
    }

    private func deliver(
        _ text: String,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        switch model.scenario {
        case "accessibility", "fallback":
            copiedAccessibilityFallback(text, completion: completion)
        case "secure-input":
            copiedSecureInputFallback(text, completion: completion)
        case "clipboard-restore":
            pasteOnce(text, requireRestoration: true, preserveNewerCopy: false, completion: completion)
        case "clipboard-preserve":
            pasteOnce(text, requireRestoration: false, preserveNewerCopy: true, completion: completion)
        case "compatibility-matrix":
            runCompatibilityMatrix(text, completion: completion)
        default:
            pasteOnce(text, requireRestoration: true, preserveNewerCopy: false, completion: completion)
        }
    }

    /// Mirrors DictationController's untrusted-Accessibility branch: no ⌘V is
    /// attempted and the transcript remains available for manual paste.
    private func copiedAccessibilityFallback(
        _ text: String,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.clipboardValue = NSPasteboard.general.string(forType: .string) ?? ""
        model.deliveryCount = 0
        completion(.init(
            statusToken: "D0AC1\(Self.signature(text))",
            hudPresentation: .accessibilityFallback
        ))
    }

    /// Uses TextInjector's exact production policy with secure input forced on.
    private func copiedSecureInputFallback(
        _ text: String,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        let payload = text + " "
        let result = TextInjector.pasteForTesting(
            payload,
            secureInputActive: true,
            postPaste: { false }
        )
        model.clipboardValue = NSPasteboard.general.string(forType: .string) ?? ""
        model.deliveryCount = 0
        let copied = result == .copiedSecureInput && model.clipboardValue == payload
        completion(.init(
            statusToken: "D0SC\(copied ? 1 : 0)\(Self.signature(text))",
            hudPresentation: .secureInputFallback
        ))
    }

    /// Executes one atomic paste through TextInjector, including delayed restore
    /// and the change-count guard that protects a newer user clipboard copy.
    private func pasteOnce(
        _ text: String,
        requireRestoration: Bool,
        preserveNewerCopy: Bool,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        let payload = text + " "
        let original = "clipboard-before-\(model.scenario)"
        let newer = "newer-user-copy"
        Self.setClipboard(original)
        model.targetText = ""
        model.deliveryCount = 0

        let result = TextInjector.pasteForTesting(
            payload,
            restoreDelay: 0.02,
            postPaste: { [weak self] in
                guard let self else { return false }
                let received = NSPasteboard.general.string(forType: .string) ?? ""
                self.model.targetText += received
                self.model.deliveryCount += 1
                if preserveNewerCopy { Self.setClipboard(newer) }
                return true
            },
            onRestore: { [weak self] restoreResult in
                guard let self else { return }
                self.model.clipboardValue = NSPasteboard.general.string(forType: .string) ?? ""
                let exactlyOnce = self.model.deliveryCount == 1 && self.model.targetText == payload
                let clipboardPolicyPassed: Bool
                let policyCode: String
                if preserveNewerCopy {
                    clipboardPolicyPassed =
                        restoreResult == .preservedNewerClipboard &&
                        self.model.clipboardValue == newer
                    policyCode = "N"
                } else {
                    clipboardPolicyPassed =
                        restoreResult == .restoredOriginal &&
                        self.model.clipboardValue == original
                    policyCode = "R"
                }
                let expectedPolicy = preserveNewerCopy ? !requireRestoration : requireRestoration
                completion(.init(
                    statusToken:
                        "D\(self.model.deliveryCount)I" +
                        "E\(exactlyOnce ? 1 : 0)" +
                        "\(policyCode)\(clipboardPolicyPassed && expectedPolicy ? 1 : 0)" +
                        Self.signature(text),
                    hudPresentation: .finished
                ))
            }
        )
        if result != .pasted {
            completion(.init(statusToken: "DX", hudPresentation: .finished))
        }
    }

    /// Four deterministic receiving-app adapters execute ten atomic production
    /// paste-policy cycles each. They represent the behavior boundary Saymark
    /// relies on across native AppKit, browser, Electron, and terminal fields.
    private func runCompatibilityMatrix(
        _ text: String,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        runMatrixIteration(
            text: text,
            targetIndex: 0,
            repetition: 0,
            totalDeliveries: 0,
            totalRestores: 0,
            completion: completion
        )
    }

    private func runMatrixIteration(
        text: String,
        targetIndex: Int,
        repetition: Int,
        totalDeliveries: Int,
        totalRestores: Int,
        completion: @escaping (DailyDriverDeliveryResult) -> Void
    ) {
        guard targetIndex < model.targets.count else {
            let allExact = model.targets.allSatisfy {
                $0.deliveries == 10 && $0.restoredClipboards == 10 && $0.exactOnce
            }
            model.deliveryCount = totalDeliveries
            model.clipboardValue = "matrix-restored-\(totalRestores)"
            completion(.init(
                statusToken:
                    "M\(model.targets.count)X10D\(totalDeliveries)" +
                    "E\(allExact ? 1 : 0)R\(totalRestores)",
                hudPresentation: .finished
            ))
            return
        }

        if repetition == 10 {
            model.targets[targetIndex].exactOnce =
                model.targets[targetIndex].deliveries == 10 &&
                model.targets[targetIndex].restoredClipboards == 10
            runMatrixIteration(
                text: text,
                targetIndex: targetIndex + 1,
                repetition: 0,
                totalDeliveries: totalDeliveries,
                totalRestores: totalRestores,
                completion: completion
            )
            return
        }

        let payload = text + " "
        let original = "matrix-\(model.targets[targetIndex].id)-\(repetition)"
        Self.setClipboard(original)
        var deliveriesThisIteration = 0
        let result = TextInjector.pasteForTesting(
            payload,
            restoreDelay: 0.002,
            postPaste: {
                let received = NSPasteboard.general.string(forType: .string)
                if received == payload { deliveriesThisIteration += 1 }
                return true
            },
            onRestore: { [weak self] restoreResult in
                guard let self else { return }
                let restored =
                    restoreResult == .restoredOriginal &&
                    NSPasteboard.general.string(forType: .string) == original
                self.model.targets[targetIndex].deliveries += deliveriesThisIteration
                if restored { self.model.targets[targetIndex].restoredClipboards += 1 }
                self.runMatrixIteration(
                    text: text,
                    targetIndex: targetIndex,
                    repetition: repetition + 1,
                    totalDeliveries: totalDeliveries + deliveriesThisIteration,
                    totalRestores: totalRestores + (restored ? 1 : 0),
                    completion: completion
                )
            }
        )
        if result != .pasted {
            completion(.init(statusToken: "MX", hudPresentation: .finished))
        }
    }

    func windowWillClose(_ notification: Notification) {
        restorePasteboard()
    }

    private static func signature(_ text: String) -> String {
        let checksum = text.utf8.reduce(0) { (($0 * 31) + Int($1)) % 100_000 }
        return "N\(text.count)H\(checksum)"
    }

    private static func setClipboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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
        let items = originalPasteboardItems.map { values -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        NSPasteboard.general.clearContents()
        if !items.isEmpty { NSPasteboard.general.writeObjects(items) }
        originalPasteboardItems = []
    }
}

private struct DailyDriverUITestView: View {
    let model: DailyDriverUITestModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily-driver integration")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("daily-driver.title")
            Text("Press ⌃⌥Space. The test drives Saymark’s registered global shortcut.")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("daily-driver.shortcut-instruction")
            Text("Scenario: \(model.scenario)")
                .accessibilityIdentifier("daily-driver.scenario")

            GroupBox("Expected final transcript") {
                Text(DailyDriverUITestModel.transcript)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .accessibilityIdentifier("daily-driver.expected-transcript")
            }

            if model.scenario == "compatibility-matrix" {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.targets) { target in
                        Text(
                            "\(target.id)|\(target.deliveries)/10|" +
                            "restored=\(target.restoredClipboards)/10|" +
                            "exact=\(target.exactOnce ? 1 : 0)"
                        )
                        .font(.system(.caption, design: .monospaced))
                        .accessibilityIdentifier("daily-driver.target.\(target.id)")
                    }
                }
            } else {
                Text(model.targetText.isEmpty ? "<empty>" : model.targetText)
                    .lineLimit(2)
                    .accessibilityIdentifier("daily-driver.target-text")
            }

            Text("deliveries=\(model.deliveryCount)")
                .accessibilityIdentifier("daily-driver.delivery-count")
            Text(model.clipboardValue.isEmpty ? "<empty>" : model.clipboardValue)
                .lineLimit(1)
                .accessibilityIdentifier("daily-driver.clipboard")
            Text(model.status)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .accessibilityIdentifier("daily-driver.status")
                .accessibilityLabel(model.status)

            Spacer()
            Label(
                model.isRunning ? "Shortcut lifecycle running" : "Ready for shortcut",
                systemImage: model.isRunning ? "waveform" : "keyboard"
            )
            .accessibilityIdentifier("daily-driver.lifecycle")
        }
        .padding(24)
        .frame(width: 700, height: 500)
    }
}
#endif
