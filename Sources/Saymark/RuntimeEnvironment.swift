import Foundation

/// Process-level switches used only by the native UI-test target. External
/// boundaries become deterministic while the real app views, navigation, and
/// state machine continue to run.
enum RuntimeEnvironment {
    static var isUITesting: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["SAYMARK_UI_TESTING"] == "1"
        #else
        false
        #endif
    }
}
