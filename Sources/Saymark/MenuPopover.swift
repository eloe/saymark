import AppKit
import SaymarkKit
import PostHog
import SwiftUI

/// The native menu-bar dropdown shown as a `.window`-style MenuBarExtra: native
/// glyph + master toggle, live status + hotkey, a mic meter, the Model / Insert /
/// Hotkey segmented controls, and a Settings/Quit footer.
struct MenuPopover: View {
    let dictation: DictationController
    /// Re-open the onboarding window (resets to Welcome + presents it).
    let onSetupTour: () -> Void
    let onRecentDictations: () -> Void
    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorScheme) private var scheme

    @AppStorage(DictationEnabled.key) private var enabled = true
    @AppStorage(InsertMode.defaultsKey) private var insertRaw = InsertMode.inField.rawValue
    @AppStorage(TriggerMode.defaultsKey) private var triggerRaw = TriggerMode.hold.rawValue
    @AppStorage(ModelSetting.key) private var modelRaw = DictationMode.accurate.rawValue

    var body: some View {
        VStack(spacing: 0) {
            head
            divider
            micRow
            divider
            settings
            divider
            footer
        }
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
        // Switching model loads the newly selected mode's models (lazy by mode).
        .onChange(of: modelRaw) { oldValue, newValue in
            dictation.prepareCurrentMode()
            PostHogSDK.shared.capture("model_mode_changed", properties: [
                "from_mode": oldValue,
                "to_mode": newValue,
            ])
        }
    }

    // MARK: head

    private var head: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .resizable().scaledToFit().symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SaymarkTheme.accent)
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text("Saymark").font(.system(size: 15, weight: .semibold)).foregroundStyle(primary)
                Spacer()
                Toggle("", isOn: $enabled).toggleStyle(.switch).tint(SaymarkTheme.accent).labelsHidden()
            }
            HStack(spacing: 8) {
                Circle().fill(dictation.isActive ? SaymarkTheme.accent : secondary.opacity(0.45))
                    .frame(width: 7, height: 7)
                Text(dictation.shortStatus).font(.system(size: 12)).foregroundStyle(secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(dictation.shortcutLabel).font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(secondary)
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(fieldBG, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            }
        }
        .padding(.horizontal, 16).padding(.top, 15).padding(.bottom, 12)
    }

    // MARK: mic meter (animated for now; live level is a later pass)

    private var micRow: some View {
        HStack(spacing: 11) {
            Text("Microphone").font(.system(size: 12)).foregroundStyle(secondary)
                .frame(width: 74, alignment: .leading)
            MeterBars(active: dictation.isActive)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
    }

    // MARK: segmented settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 0) {
            label("Model")
            SaymarkSegment("Model", selection: $modelRaw,
                           options: [(DictationMode.accurate.rawValue, "Efficient"),
                                     (DictationMode.hybrid.rawValue, "Live Preview")])
            label("Insert").padding(.top, 11)
            SaymarkSegment("Insert", selection: $insertRaw,
                           options: [(InsertMode.inField.rawValue, "In field"),
                                     (InsertMode.hudOnly.rawValue, "HUD only")])
            label("Hotkey").padding(.top, 11)
            SaymarkSegment("Hotkey", selection: $triggerRaw,
                           options: [(TriggerMode.hold.rawValue, "Hold to Dictate"),
                                     (TriggerMode.toggle.rawValue, "Start / Stop")])
            if dictation.needsAccessibilityToType, insertRaw == InsertMode.inField.rawValue {
                Button { dictation.requestAccessibility() } label: {
                    Text("Grant Accessibility to type…")
                        .font(.system(size: 11.5)).foregroundStyle(SaymarkTheme.accent)
                }
                .buttonStyle(.plain).padding(.top, 10)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .onAppear {
            // Migrate the old Nemotron-only UI choice to the safer one-model final
            // experience. `.fast` remains available to benchmarks, not normal users.
            if modelRaw == DictationMode.fast.rawValue {
                modelRaw = DictationMode.accurate.rawValue
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 12)).foregroundStyle(tertiary)
            .padding(.bottom, 7).frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: footer

    private var footer: some View {
        VStack(spacing: 0) {
            footerRow("Settings…", "⌘ ,") {
                PostHogSDK.shared.capture("settings_opened")
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            // Re-run the first-run tour: reset to Welcome, then ask the App scene
            // (via the router) to open the onboarding window.
            footerRow("Setup tour…", "") { onSetupTour() }
            if RecentDictationsRetention.current != .off {
                footerRow("Recent Dictations…", "") { onRecentDictations() }
            }
            footerRow("Quit Saymark", "⌘ Q") { NSApplication.shared.terminate(nil) }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
    }

    private func footerRow(_ title: LocalizedStringKey, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title).font(.system(size: 13)).foregroundStyle(primary)
                Spacer()
                Text(verbatim: key).font(.system(size: 11, design: .monospaced)).foregroundStyle(tertiary)
            }
            .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: chrome

    private var divider: some View {
        Rectangle().fill(scheme == .dark ? Color.white.opacity(0.07) : SaymarkTheme.ink.opacity(0.07)).frame(height: 1)
    }
    private var primary: Color { scheme == .dark ? Color.white.opacity(0.92) : SaymarkTheme.ink }
    private var secondary: Color { scheme == .dark ? Color.white.opacity(0.6) : SaymarkTheme.ink.opacity(0.65) }
    private var tertiary: Color { scheme == .dark ? Color.white.opacity(0.5) : SaymarkTheme.ink.opacity(0.55) }
    private var fieldBG: Color { scheme == .dark ? Color.white.opacity(0.1) : SaymarkTheme.ink.opacity(0.07) }
}

/// System segmented control so sizing, contrast, focus, and interaction follow
/// the user's current macOS appearance and accessibility settings.
private struct SaymarkSegment: View {
    let title: String
    @Binding var selection: String
    let options: [(value: String, label: String)]

    init(_ title: String, selection: Binding<String>, options: [(value: String, label: String)]) {
        self.title = title
        _selection = selection
        self.options = options
    }

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.value) { opt in
                Text(opt.label).tag(opt.value)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
    }
}

/// Mic level meter — animated bars (live RMS is a later pass).
private struct MeterBars: View {
    var active: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0 ..< 8, id: \.self) { i in
                let lit = active && i < 5
                Capsule()
                    .fill(lit ? SaymarkTheme.accent : (scheme == .dark ? Color.white.opacity(0.16) : SaymarkTheme.ink.opacity(0.18)))
                    .frame(width: 3, height: 18)
                    .scaleEffect(y: (up || reduceMotion) && lit ? 1 : 0.4, anchor: .center)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.07), value: up)
            }
        }
        .frame(height: 18)
        .accessibilityHidden(true)   // decorative meter
        .onAppear { up = true }
    }
}
