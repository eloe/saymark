import Foundation
import SaymarkKit
import SwiftUI

/// A restrained, linear setup flow built from standard macOS controls. The
/// underlying `OnboardingModel` and `OnboardingFlow` remain the source of truth
/// for permissions, model preparation, and try-it gates.
struct OnboardingView: View {
    @Bindable var model: OnboardingModel
    @FocusState private var focusedControl: OnboardingFocus?

    var body: some View {
        HStack(spacing: 0) {
            OnboardingSidebar(model: model)

            Divider()

            VStack(spacing: 0) {
                ScrollView {
                    content
                        .frame(maxWidth: 480, alignment: .leading)
                        .padding(.horizontal, 36)
                        .padding(.vertical, 34)
                        .frame(maxWidth: .infinity, minHeight: 410, alignment: .top)
                }

                Divider()
                OnboardingFooter(model: model, focusedControl: $focusedControl)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .accessibilityIdentifier("onboarding.root")
    }

    @ViewBuilder private var content: some View {
        switch model.flow.step {
        case .welcome: WelcomeScreen()
        case .permissions: PermissionsScreen(model: model)
        case .shortcut:
            ShortcutScreen {
                focusedControl = .continueButton
            }
        case .download: DownloadScreen(model: model)
        case .tryIt, .done: TryItScreen(model: model)
        }
    }
}

enum OnboardingFocus: Hashable {
    case continueButton
}

private struct OnboardingSidebar: View {
    @Bindable var model: OnboardingModel

    private struct Step {
        let title: LocalizedStringKey
        let symbol: String
    }

    private let steps: [Step] = [
        Step(title: "Welcome", symbol: "hand.wave"),
        Step(title: "Permissions", symbol: "lock.shield"),
        Step(title: "Shortcut", symbol: "command"),
        Step(title: "Prepare", symbol: "arrow.down.circle"),
        Step(title: "Try it", symbol: "waveform"),
    ]

    private var currentStep: Int {
        switch model.flow.step {
        case .welcome: return 0
        case .permissions: return 1
        case .shortcut: return 2
        case .download: return 3
        case .tryIt, .done: return 4
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                onboardingMark(30)
                    .accessibilityHidden(true)
                Text("Saymark")
                    .font(.headline)
            }
            .padding(.bottom, 30)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(steps.indices, id: \.self) { index in
                    stepRow(steps[index], index: index)
                }
            }

            Spacer()

            Label("On-device", systemImage: "lock.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.init(top: 28, leading: 20, bottom: 22, trailing: 18))
        .frame(width: 188)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.sidebar")
    }

    private func stepRow(_ step: Step, index: Int) -> some View {
        let active = index == currentStep
        let complete = index < currentStep

        return HStack(spacing: 10) {
            Image(systemName: complete ? "checkmark.circle.fill" : step.symbol)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(active || complete ? SaymarkTheme.accent : Color.secondary)
                .frame(width: 18)

            Text(step.title)
                .font(.system(size: 13, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color.primary : Color.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(
            active ? Color.primary.opacity(0.075) : Color.clear,
            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(step.title)
        .accessibilityValue(active ? "Current step" : (complete ? "Completed" : "Not started"))
    }
}

private struct WelcomeScreen: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            onboardingMark(58)
                .accessibilityLabel("Saymark")
                .accessibilityIdentifier("onboarding.welcome-mark")

            Text("Speak naturally. Write anywhere.")
                .font(.system(size: 28, weight: .semibold))

            Text("Saymark turns your voice into text in any app. Dictation runs on this Mac.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Label(
                "Setup downloads about \(String(format: "%.1f GB", OnboardingFlow.totalGB)) for private, on-device dictation.",
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
