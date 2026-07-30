import SaymarkKit
import PostHog
import SwiftUI

/// Native macOS-aligned Saymark tokens. The palette stays neutral and lets the
/// system appearance provide surfaces; blue is reserved for active/selected UI.
enum SaymarkTheme {
    static let accent = Color(red: 0x0A / 255, green: 0x84 / 255, blue: 0xFF / 255)
    static let ink    = Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255)
    static let error  = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)

    /// Crisp (finalized) transcript ink per appearance.
    static func crisp(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.97) : ink
    }

    /// Fast-draft (provisional) transcript ink per appearance.
    static func draft(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.34) : ink.opacity(0.34)
    }
}

/// How the push-to-talk hotkey behaves.
enum TriggerMode: String, CaseIterable, Identifiable {
    case hold      // record while held, stop on release (push-to-talk)
    case toggle    // tap to start, tap again (or the HUD Stop button) to stop

    var id: String { rawValue }
    var label: String { self == .hold ? "Hold to Dictate" : "Press to Start/Stop" }

    static let defaultsKey = "saymark.triggerMode"
    static var current: TriggerMode {
        TriggerMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .hold
    }
}

/// Master on/off — when off, the hotkey is ignored.
enum DictationEnabled {
    static let key = "saymark.enabled"
    /// Defaults to `true` when unset.
    static var value: Bool {
        UserDefaults.standard.object(forKey: key) == nil ? true : UserDefaults.standard.bool(forKey: key)
    }
}

/// Which model(s) transcribe — persisted; read by DictationController at begin.
enum ModelSetting {
    static let key = "saymark.model"
    static var current: DictationMode {
        switch DictationMode(rawValue: UserDefaults.standard.string(forKey: key) ?? "") {
        case .hybrid: return .hybrid
        case .accurate, .fast, nil: return .accurate
        }
    }
}

/// Where the transcript goes when you release the hotkey.
enum InsertMode: String, CaseIterable, Identifiable {
    case inField   // type into the focused field of any app (needs Accessibility)
    case hudOnly   // presentation/subtitles: show in the HUD only, never inject

    var id: String { rawValue }
    var label: String { self == .inField ? "In field" : "HUD only" }

    static let defaultsKey = "saymark.insertMode"
    static var current: InsertMode {
        InsertMode(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .inField
    }
}

/// Explicit opt-in persistence for final dictation text. Unknown persisted
/// values deliberately resolve to `.off`; text is never stored by default.
enum RecentDictationsRetention: String, CaseIterable, Identifiable {
    case off
    case session
    case days7
    case days30
    case days90
    case untilDeleted

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .session: return "This session"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .days90: return "90 days"
        case .untilDeleted: return "Until I delete"
        }
    }

    static let defaultsKey = "saymark.recentDictationsRetention"

    static var current: RecentDictationsRetention {
        RecentDictationsRetention(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .off
    }
}

/// Anonymous usage & error analytics (PostHog). **Opt-in**: off until the user
/// enables it on the onboarding Welcome step (or in Settings). While off,
/// `PostHogSDK.shared.optOut()` makes every `capture(…)` a no-op — no audio or
/// transcripts are ever sent regardless.
enum AnalyticsConsent {
    static let key = "saymark.analyticsEnabled"
    /// Remote analytics is unavailable in source/local builds until Saymark has
    /// its own PostHog project and the build injects that project's write-only key.
    static var isAvailable: Bool {
        guard let token = Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String else {
            return false
        }
        return !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    /// Defaults to `false` (opt-in) when unset.
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }
    /// SSOT for applying consent: persists + flips PostHog. Call from any toggle.
    @MainActor static func set(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: key)
        on ? PostHogSDK.shared.optIn() : PostHogSDK.shared.optOut()
    }
}

/// Local diagnostic logging. Environment variables win over persisted settings
/// so benchmark launches can be configured without mutating app preferences.
enum DiagnosticLogSetting {
    static let key = "saymark.logLevel"
    static let maxBytesKey = "saymark.logMaxBytes"

    static var defaultLevel: SaymarkLogLevel {
        Bundle.main.bundleIdentifier?.hasSuffix(".local") == true ? .debug : .info
    }

    static var current: SaymarkLogLevel {
        if let value = ProcessInfo.processInfo.environment["SAYMARK_LOG_LEVEL"],
           let level = SaymarkLogLevel(configurationValue: value) {
            return level
        }
        if let value = UserDefaults.standard.string(forKey: key),
           let level = SaymarkLogLevel(configurationValue: value) {
            return level
        }
        return defaultLevel
    }

    static var fileURL: URL {
        if let path = ProcessInfo.processInfo.environment["SAYMARK_LOG_FILE"], !path.isEmpty {
            return URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "com.eloe.saymark"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("saymark.jsonl")
    }

    static var maxFileBytes: Int {
        if let raw = ProcessInfo.processInfo.environment["SAYMARK_LOG_MAX_BYTES"],
           let value = Int(raw), value > 0 {
            return value
        }
        let persisted = UserDefaults.standard.integer(forKey: maxBytesKey)
        return persisted > 0 ? persisted : 20 * 1024 * 1024
    }

    static func configure() {
        SaymarkDiagnostics.configure(.init(
            level: current,
            fileURL: fileURL,
            maxFileBytes: maxFileBytes,
            retainedFiles: 3
        ))
    }

    static func set(_ level: SaymarkLogLevel) {
        UserDefaults.standard.set(level.name, forKey: key)
        configure()
        SaymarkDiagnostics.log(.info, "logging.configuration_changed", fields: [
            "configured_level": current.name,
            "max_file_bytes": maxFileBytes,
        ])
    }
}
