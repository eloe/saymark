import SaymarkKit
import SwiftUI

/// Saymark's waveform-and-cursor mark from the production asset catalog.
func onboardingMark(_ size: CGFloat) -> some View {
    Image("SaymarkMenuBar")
        .renderingMode(.template)
        .resizable()
        .scaledToFit()
        .foregroundStyle(SaymarkTheme.accent)
        .frame(width: size, height: size)
}

/// Standard wizard navigation with a single progress label and native buttons.
struct OnboardingFooter: View {
    @Bindable var model: OnboardingModel

    private var continueLabel: LocalizedStringKey {
        switch model.flow.step {
        case .welcome: return "Set Up Saymark"
        case .permissions:
            return model.flow.accessibilityGranted ? "Continue" : "Set Up Later"
        case .shortcut: return "Continue"
        case .download: return model.canContinue ? "Continue" : "Downloading…"
        case .tryIt: return "Finish"
        case .done: return "Finish"
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if model.showBack {
                Button("Back") { model.back() }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            Button(continueLabel) { model.next() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canContinue)
                .accessibilityIdentifier("onboarding.continue")
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(.bar)
    }
}
