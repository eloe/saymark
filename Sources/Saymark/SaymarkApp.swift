import AppKit
import SwiftUI

/// Saymark — local push-to-talk dictation for macOS.
///
/// Hold a global hotkey, speak, and the transcription is typed into the focused
/// field of whatever app you're in. Everything runs on-device via MLX (no cloud).
@main
struct SaymarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // The onboarding window is an AppKit `NSWindow` owned by the AppDelegate
        // (a SwiftUI `Window` scene hides on deactivation and can't open reliably at
        // launch here). The live dictation backend stays deferred until onboarding
        // finishes (AppDelegate router) even though the icon is always present.
        MenuBarExtra {
            MenuPopover(dictation: appDelegate.dictation,
                        onSetupTour: { appDelegate.replayOnboarding() })
        } label: {
            Image(nsImage: Self.menuIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }

    /// Saymark's monochrome template mark automatically adapts to the menu bar.
    private static let menuIcon: NSImage = {
        let image = NSImage(named: "SaymarkMenuBar")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: "Saymark")
            ?? NSImage()
        image.accessibilityDescription = "Saymark"
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()
}
