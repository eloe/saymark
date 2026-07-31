import KeyboardShortcuts
import SwiftUI

/// Selects the actual shortcut and behavior the user will exercise on Try It.
struct ShortcutScreen: View {
    @AppStorage(TriggerMode.defaultsKey) private var triggerMode = TriggerMode.hold.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose how to start dictation")
                .font(.system(size: 26, weight: .semibold))

            Text("Set a global shortcut, then choose whether to hold it while speaking or press it to start and press it again to stop.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(spacing: 14) {
                    LabeledContent("Shortcut") {
                        KeyboardShortcuts.Recorder(for: .dictate)
                    }

                    Divider()

                    LabeledContent("Behavior") {
                        Picker("Behavior", selection: $triggerMode) {
                            Text("Hold to Dictate").tag(TriggerMode.hold.rawValue)
                            Text("Press to Start/Stop").tag(TriggerMode.toggle.rawValue)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .accessibilityIdentifier("onboarding.trigger-mode")
                    }
                }
                .padding(8)
            }

            Button("Use Recommended Shortcut") {
                KeyboardShortcuts.setShortcut(
                    .init(.space, modifiers: [.control, .shift]),
                    for: .dictate
                )
            }
            .buttonStyle(.link)
            .accessibilityHint("Uses Control and Shift so it does not conflict with the VoiceOver modifier")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
