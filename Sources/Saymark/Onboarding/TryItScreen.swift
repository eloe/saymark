import SwiftUI

/// Exercises the configured global shortcut against the real warmed pipeline.
/// Completion is intentionally gated on using that shortcut so onboarding
/// teaches the same interaction the user will use after setup.
struct TryItScreen: View {
    @Bindable var model: OnboardingModel
    @Environment(\.colorScheme) private var scheme

    private var ready: Bool { model.tryReady }

    private var instruction: String {
        switch TriggerMode.current {
        case .hold:
            return "Hold \(model.shortcutLabel) and say a sentence."
        case .toggle:
            return "Press \(model.shortcutLabel) to start dictation."
        }
    }

    private var listeningInstruction: String {
        switch TriggerMode.current {
        case .hold:
            return "Listening — release \(model.shortcutLabel) to stop"
        case .toggle:
            return "Listening — press \(model.shortcutLabel) again to stop"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if model.flow.didTry {
                successHeader
            } else {
                Text("Try your shortcut")
                    .font(.system(size: 26, weight: .semibold))
                Text(instruction)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("onboarding.shortcut-instruction")
            }

            GroupBox {
                transcript
                    .font(.body)
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
                    .padding(8)
            } label: {
                Label("Live transcript", systemImage: model.tryListening ? "waveform" : "text.cursor")
                    .foregroundStyle(model.tryListening ? SaymarkTheme.accent : Color.secondary)
            }
            .accessibilityIdentifier("onboarding.try-transcript")

            status

            Button(model.tryListening ? "Stop Dictation" : "Start Dictation") {
                model.tryAccessibleToggle()
            }
            .disabled(!model.canToggleTry)
            .accessibilityIdentifier("onboarding.try-toggle")
            .accessibilityHint(model.tryListening
                ? "Stops the current practice dictation"
                : "Starts practice dictation without holding the global shortcut")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onDisappear { model.tryEnd() }
    }

    private var successHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(model.didVerifyShortcut ? "Shortcut works." : "Dictation works.")
                    .font(.system(size: 26, weight: .semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text(model.didVerifyShortcut
                 ? "Saymark is ready to dictate in any app."
                 : "Practice succeeded. Use this button with VoiceOver, or choose and test a global shortcut later.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var transcript: Text {
        let confirmed = Self.words(model.tryConfirmed)
        let partial = Self.words(model.tryPartial)
        guard !confirmed.isEmpty || !partial.isEmpty else {
            return Text("Your words will appear here as you speak.")
                .foregroundColor(.secondary)
        }

        var output = Text("")
        for word in confirmed {
            output = output + Text(word).foregroundColor(SaymarkTheme.crisp(scheme)) + Text(" ")
        }
        for word in partial {
            output = output + Text(word).foregroundColor(SaymarkTheme.draft(scheme)) + Text(" ")
        }
        return output
    }

    @ViewBuilder private var status: some View {
        if let error = model.tryError {
            Label(error, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        } else if model.tryListening {
            Label(listeningInstruction, systemImage: "waveform")
                .foregroundStyle(SaymarkTheme.accent)
                .accessibilityIdentifier("onboarding.try-listening")
        } else if !ready {
            ProgressView("Warming up dictation…")
                .controlSize(.small)
        } else if !model.flow.didTry {
            Label("Shortcut ready", systemImage: "keyboard")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
}
