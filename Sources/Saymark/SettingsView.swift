import AppKit
import KeyboardShortcuts
import SaymarkKit
import SwiftUI

/// Saymark's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    @AppStorage(InsertMode.defaultsKey) private var insertModeRaw = InsertMode.inField.rawValue
    @State private var historyRetentionRaw = RecentDictationsRetention.current.rawValue
    @State private var pendingHistoryRetention: RecentDictationsRetention?
    @State private var showingRetentionConfirmation = false
    @State private var showingClearConfirmation = false
    @AppStorage(AnalyticsConsent.key) private var analyticsEnabled = false
    @AppStorage(DiagnosticLogSetting.key) private var logLevelRaw = DiagnosticLogSetting.defaultLevel.name

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Push-to-talk:", name: .dictate)
            } header: {
                Text("Shortcut")
            } footer: {
                Text("Hold the shortcut to dictate; release to finish.")
            }

            Section {
                Picker("On release", selection: $insertModeRaw) {
                    Text("Type into the focused field").tag(InsertMode.inField.rawValue)
                    Text("Show in the HUD only").tag(InsertMode.hudOnly.rawValue)
                }
                .pickerStyle(.inline)
            } header: {
                Text("Insert")
            } footer: {
                Text("“HUD only” never types into other apps — it shows live subtitles in the HUD, handy for presentations and demos.")
            }

            Section {
                Picker("Keep recent dictations", selection: $historyRetentionRaw) {
                    ForEach(RecentDictationsRetention.allCases) { retention in
                        Text(retention.label).tag(retention.rawValue)
                    }
                }
                .pickerStyle(.menu)

                Button("Clear Recent Dictations") {
                    showingClearConfirmation = true
                }
                .disabled(RecentDictationsRetention.current == .off)
            } header: {
                Text("Recent Dictations")
            } footer: {
                Text("Off is the default. When enabled, Saymark keeps final text only on this Mac—never audio, secure-input dictation, or HUD-only sessions. 30 days is recommended after you choose to enable history. Clearing removes Saymark’s current local store; it cannot erase earlier backups or snapshots.")
            }
            .onChange(of: historyRetentionRaw) { _, rawValue in
                let policy = RecentDictationsRetention(rawValue: rawValue) ?? .off
                chooseRetention(policy)
            }

            if AnalyticsConsent.isAvailable {
                Section {
                    Toggle("Share anonymous usage & crash reports", isOn: $analyticsEnabled)
                        .onChange(of: analyticsEnabled) { _, on in
                            AnalyticsConsent.set(on)
                        }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Helps fix bugs and improve Saymark. Only anonymous events and errors are sent — never your audio or transcripts. Dictation runs fully on-device either way.")
                }
            } else {
                Section {
                    LabeledContent("Remote analytics", value: "Not configured")
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("This build does not send usage or crash reports. Diagnostic logs remain on this Mac.")
                }
            }

            Section {
                Picker("Log level", selection: $logLevelRaw) {
                    ForEach(SaymarkLogLevel.allCases, id: \.rawValue) { level in
                        Text(level.name.capitalized).tag(level.name)
                    }
                }
                .onChange(of: logLevelRaw) { _, value in
                    if let level = SaymarkLogLevel(configurationValue: value) {
                        DiagnosticLogSetting.set(level)
                    }
                }

                Button("Reveal diagnostic log") {
                    DiagnosticLogSetting.configure()
                    let file = DiagnosticLogSetting.fileURL
                    if FileManager.default.fileExists(atPath: file.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([file])
                    } else {
                        NSWorkspace.shared.open(file.deletingLastPathComponent())
                    }
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Machine-readable local logs contain timings, resource measurements, and counts—never audio or transcript text. Trace records each 160 ms processing step.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 430)
        .confirmationDialog(
            "Update Recent Dictations retention?",
            isPresented: $showingRetentionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                if let pendingHistoryRetention { applyRetention(pendingHistoryRetention) }
                pendingHistoryRetention = nil
            }
            Button("Keep Current Setting", role: .cancel) { pendingHistoryRetention = nil }
        } message: {
            Text(retentionConfirmationMessage)
        }
        .confirmationDialog(
            "Clear Recent Dictations?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { RecentDictationsController.shared.clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes dictations from Saymark’s current local history store.")
        }
    }

    private func chooseRetention(_ proposed: RecentDictationsRetention) {
        let current = RecentDictationsRetention.current
        guard proposed != current else { return }
        if current == .off || proposed.deletesExistingHistory(comparedWith: current) {
            pendingHistoryRetention = proposed
            historyRetentionRaw = current.rawValue
            showingRetentionConfirmation = true
        } else {
            applyRetention(proposed)
        }
    }

    private func applyRetention(_ retention: RecentDictationsRetention) {
        Task {
            let didCommit = await RecentDictationsController.shared.setRetention(retention)
            historyRetentionRaw = didCommit ? retention.rawValue : RecentDictationsRetention.current.rawValue
        }
    }

    private var retentionConfirmationMessage: String {
        if let pendingHistoryRetention,
           pendingHistoryRetention.deletesExistingHistory(comparedWith: RecentDictationsRetention.current) {
            return "Changing to this retention period immediately deletes dictations that no longer fit. This cannot erase backups or snapshots made outside Saymark."
        }
        return "Saymark will keep final dictation text only on this Mac. It never keeps audio, secure-input dictation, or HUD-only sessions."
    }
}

private extension RecentDictationsRetention {
    func deletesExistingHistory(comparedWith current: Self) -> Bool {
        if self == .off || self == .session { return current != self }
        func rank(_ value: Self) -> Int {
            switch value {
            case .session: return 0
            case .days7: return 7
            case .days30: return 30
            case .days90: return 90
            case .untilDeleted: return .max
            case .off: return -1
            }
        }
        return rank(self) < rank(current)
    }
}
