import AppKit
import SwiftUI

/// Permission requests stay in context and retain the existing hard/soft gates:
/// microphone is required, while Accessibility may be completed later.
struct PermissionsScreen: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Allow Saymark to listen and type")
                .font(.system(size: 26, weight: .semibold))

            Text("Saymark needs microphone access for dictation. Accessibility lets it insert the result into the app you’re using.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(spacing: 0) {
                    permissionRow(
                        symbol: "mic",
                        title: "Microphone",
                        explanation: "Required to hear dictation",
                        granted: model.flow.micGranted,
                        actionTitle: "Allow Microphone",
                        action: model.requestMic
                    )
                    Divider()
                    permissionRow(
                        symbol: "accessibility",
                        title: "Accessibility",
                        explanation: "Lets Saymark insert text in the active app",
                        granted: model.flow.accessibilityGranted,
                        actionTitle: nil,
                        action: model.promptAccessibility
                    )
                }
            }

            if !model.flow.accessibilityGranted {
                accessibilityDragCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { model.refreshPermissions() }
        .onDisappear { model.stopAccessibilityPolling() }
    }

    private func permissionRow(
        symbol: String,
        title: LocalizedStringKey,
        explanation: LocalizedStringKey,
        granted: Bool,
        actionTitle: LocalizedStringKey?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(SaymarkTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .accessibilityIdentifier("onboarding.permission.allowed")
            } else if let actionTitle {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
    }

    private var accessibilityDragCard: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .onDrag {
                    NSItemProvider(object: Bundle.main.bundleURL as NSURL)
                } preview: {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 56)
                }
                .accessibilityLabel("Saymark application icon")
                .accessibilityHint("Drag into the Accessibility app list in System Settings")

            VStack(alignment: .leading, spacing: 4) {
                Text("Drag Saymark into System Settings")
                    .font(.headline)
                Text("Choose Open System Settings in the macOS prompt, then drag this icon into the app list.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button("Set Up Accessibility") {
                model.promptAccessibility()
            }
            .buttonStyle(.bordered)
        }
        .padding(14)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 1, dash: [5, 4])
                )
        }
    }
}
