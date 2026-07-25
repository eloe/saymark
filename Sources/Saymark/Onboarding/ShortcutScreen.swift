import KeyboardShortcuts
import SwiftUI

/// Selects the actual shortcut and behavior the user will exercise on Try It.
struct ShortcutScreen: View {
    @AppStorage(TriggerMode.defaultsKey) private var triggerMode = TriggerMode.hold.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Choose how to start dictation")
                .font(.system(size: 26, weight: .semibold))

            Text("Set a global shortcut, then choose whether to hold it while speaking or press it once to start and again to stop.")
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
                            Text("Hold to Talk").tag(TriggerMode.hold.rawValue)
                            Text("Press Once").tag(TriggerMode.toggle.rawValue)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 205)
                        .accessibilityIdentifier("onboarding.trigger-mode")
                    }
                }
                .padding(8)
            }

            Button("Use Recommended Shortcut") {
                KeyboardShortcuts.setShortcut(
                    .init(.space, modifiers: [.control, .option]),
                    for: .dictate
                )
            }
            .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
