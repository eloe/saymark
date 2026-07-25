import CoreGraphics
import XCTest

final class DailyDriverLoopUITests: XCTestCase {
    private static let transcript = """
    First, Saymark keeps the full thought visible while I continue speaking. \
    Second, releasing the shortcut moves the HUD into a clear processing state. \
    Third, the final transcript is delivered exactly once without losing clipboard data.
    """

    private var app: XCUIApplication!

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    func testShortcutDeliversLongDictationExactlyOnceAndRestoresClipboard() {
        launch(scenario: "success")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|D1IE1R1\(signature)|TRR"
        )
        assertValue("daily-driver.delivery-count", equals: "deliveries=1")
        assertValue("daily-driver.target-text", equals: Self.transcript + " ")
        assertValue("daily-driver.clipboard", equals: "clipboard-before-success")
    }

    func testMissingAccessibilityLeavesOneManualClipboardCopy() {
        launch(scenario: "accessibility")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|D0AC1\(signature)|TRR"
        )
        assertValue("daily-driver.delivery-count", equals: "deliveries=0")
        assertValue("daily-driver.target-text", equals: "")
        assertValue("daily-driver.clipboard", equals: Self.transcript)
    }

    func testSecureInputLeavesTranscriptOnClipboardWithoutSyntheticPaste() {
        launch(scenario: "secure-input")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|D0SC1\(signature)|TRR"
        )
        assertValue("daily-driver.delivery-count", equals: "deliveries=0")
        assertValue("daily-driver.target-text", equals: "")
        assertValue("daily-driver.clipboard", equals: Self.transcript + " ")
    }

    func testNoSpeechShowsErrorAndNeverTouchesDeliveryBoundary() {
        launch(scenario: "no-speech")
        triggerShortcut()

        assertCompleted("READY|KD|L|KU|P|D0N|TRR")
        assertValue("daily-driver.delivery-count", equals: "deliveries=0")
        assertValue("daily-driver.target-text", equals: "")
        assertValue("daily-driver.clipboard", equals: "")
    }

    func testOriginalClipboardIsRestoredAfterAtomicPaste() {
        launch(scenario: "clipboard-restore")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|D1IE1R1\(signature)|TRR"
        )
        assertValue("daily-driver.clipboard", equals: "clipboard-before-clipboard-restore")
    }

    func testNewerUserClipboardCopyIsNeverOverwrittenByDelayedRestore() {
        launch(scenario: "clipboard-preserve")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|D1IE1N1\(signature)|TRR"
        )
        assertValue("daily-driver.clipboard", equals: "newer-user-copy")
        assertValue("daily-driver.delivery-count", equals: "deliveries=1")
    }

    func testCompatibilityMatrixDeliversExactlyOnceTenTimesPerTarget() {
        launch(scenario: "compatibility-matrix")
        triggerShortcut()

        let signature = Self.signature(Self.transcript)
        assertCompleted(
            "READY|KD|L|V3F1\(signature)|KU|P|M4X10D40E1R40|TRR",
            timeout: 15
        )
        for target in ["native-text-view", "web-textarea", "electron-field", "terminal"] {
            assertValue(
                "daily-driver.target.\(target)",
                equals: "\(target)|10/10|restored=10/10|exact=1"
            )
        }
        assertValue("daily-driver.delivery-count", equals: "deliveries=40")
        assertValue("daily-driver.clipboard", equals: "matrix-restored-40")
    }

    private func launch(scenario: String) {
        app = XCUIApplication()
        app.launchEnvironment["SAYMARK_UI_TESTING"] = "1"
        app.launchEnvironment["SAYMARK_UI_TESTING_DAILY_DRIVER"] = "1"
        app.launchEnvironment["SAYMARK_UI_TESTING_SCENARIO"] = scenario
        app.launchArguments += [
            "-saymark.didOnboard", "YES",
            "-saymark.triggerMode", "hold",
            "-saymark.enabled", "YES",
        ]
        app.launch()

        assertValue("daily-driver.status", equals: "READY")
        XCTAssertTrue(element("daily-driver.shortcut-instruction").exists)
    }

    /// This is deliberately not a harness button. XCUITest emits the configured
    /// keyboard chord and the app's real KeyboardShortcuts/Carbon handlers drive
    /// both the key-down and key-up lifecycle.
    private func triggerShortcut() {
        let source = CGEventSource(stateID: .privateState)
        let space = CGKeyCode(49)
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        let down = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: space, keyDown: false)
        XCTAssertNotNil(down)
        XCTAssertNotNil(up)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        up?.post(tap: .cghidEventTap)
        let status = element("daily-driver.status")
        let receivedShortcut = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label CONTAINS %@ OR value CONTAINS %@",
                "|KD|",
                "|KD|"
            ),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [receivedShortcut], timeout: 3), .completed)
    }

    private func assertCompleted(_ expected: String, timeout: TimeInterval = 12) {
        let status = element("daily-driver.status")
        XCTAssertTrue(status.waitForExistence(timeout: 2))
        let completed = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR value == %@",
                expected,
                expected
            ),
            object: status
        )
        let result = XCTWaiter.wait(for: [completed], timeout: timeout)
        XCTAssertEqual(
            result,
            .completed,
            "Ordered history was label=\(status.label), value=\(String(describing: status.value)); expected \(expected)"
        )
    }

    private func assertValue(
        _ identifier: String,
        equals expected: String,
        timeout: TimeInterval = 2
    ) {
        let value = element(identifier)
        XCTAssertTrue(value.waitForExistence(timeout: timeout), "Missing \(identifier)")
        let matched = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR value == %@",
                expected,
                expected
            ),
            object: value
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [matched], timeout: timeout),
            .completed,
            "\(identifier) was label=\(value.label), value=\(String(describing: value.value)); expected \(expected)"
        )
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.staticTexts[identifier]
    }

    private static func signature(_ text: String) -> String {
        let checksum = text.utf8.reduce(0) { (($0 * 31) + Int($1)) % 100_000 }
        return "N\(text.count)H\(checksum)"
    }
}
