import Foundation

/// Process-level switches used only by the native UI-test target. External
/// boundaries become deterministic while the real app views, navigation, and
/// state machine continue to run.
enum RuntimeEnvironment {
    /// Hosted app unit tests load XCTest into a temporary Saymark.app. That app
    /// has a different TCC identity from the installed local build and must never
    /// start services or request real microphone/Accessibility permissions.
    static var isHostedUnitTesting: Bool {
        isHostedUnitTesting(environment: ProcessInfo.processInfo.environment)
    }

    static func isHostedUnitTesting(environment: [String: String]) -> Bool {
        [
            "XCTestConfigurationFilePath",
            "XCTestBundlePath",
            "XCInjectBundleInto",
        ].contains { environment[$0]?.isEmpty == false }
    }

    static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SAYMARK_UI_TESTING"] == "1"
        #else
        false
        #endif
    }

    static var isDailyDriverUITesting: Bool {
        #if DEBUG
        isUITesting &&
            ProcessInfo.processInfo.environment["SAYMARK_UI_TESTING_DAILY_DRIVER"] == "1"
        #else
        false
        #endif
    }

    /// Keeps external services deterministic while presenting the ungranted
    /// Accessibility state for design review and walkthrough recording.
    static var isOnboardingReview: Bool {
        #if DEBUG
        isUITesting &&
            ProcessInfo.processInfo.environment["SAYMARK_ONBOARDING_REVIEW"] == "1"
        #else
        false
        #endif
    }

    static var dailyDriverOutcome: String? {
        #if DEBUG
        guard isDailyDriverUITesting else { return nil }
        return ProcessInfo.processInfo.environment["SAYMARK_UI_TESTING_DELIVERY"]
        #else
        nil
        #endif
    }

    static var dailyDriverScenario: String {
        #if DEBUG
        guard isDailyDriverUITesting else { return "disabled" }
        return ProcessInfo.processInfo.environment["SAYMARK_UI_TESTING_SCENARIO"]
            ?? dailyDriverOutcome
            ?? "success"
        #else
        return "disabled"
        #endif
    }
}
