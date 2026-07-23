import AppKit
import KeyboardShortcuts
import SaymarkKit
import SwiftUI

/// Saymark's preferences window (a SwiftUI `Settings` scene): the push-to-talk
/// shortcut and where the transcript goes on release.
struct SettingsView: View {
    @AppStorage(InsertMode.defaultsKey) private var insertModeRaw = InsertMode.inField.rawValue
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
                Text("Machine-readable local logs contain timings, resource measurements, and counts—never audio or transcript text. Trace records each 480 ms processing step.")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .frame(minHeight: 430)
    }
}
