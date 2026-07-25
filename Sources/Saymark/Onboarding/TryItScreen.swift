import KeyboardShortcuts
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
            return "Press \(model.shortcutLabel) to start, then press it again to finish."
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            for await event in KeyboardShortcuts.events(for: .dictate) {
                switch (TriggerMode.current, event) {
                case (.hold, .keyDown):
                    model.tryStart()
                case (.hold, .keyUp):
                    model.tryEnd()
                case (.toggle, .keyDown):
                    model.tryToggle()
                case (.toggle, .keyUp):
                    break
                }
            }
        }
        .onDisappear { model.tryEnd() }
    }

    private var successHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text("Shortcut works.")
                    .font(.system(size: 26, weight: .semibold))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }

            Text("Saymark is ready to dictate in any app.")
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
        if model.tryListening {
            Label("Listening — speak naturally", systemImage: "waveform")
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
