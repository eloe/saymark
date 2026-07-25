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

    func testLongDictationHUDProcessesAndInsertsExactlyOnce() throws {
        launch(delivery: "insert")
        runAndAssertHUDLifecycle(outcome: "I", clipboard: "0")
        XCTAssertEqual(Self.transcript.components(separatedBy: ".").count - 1, 3)
    }

    func testLongDictationFallsBackToClipboardExactlyOnce() throws {
        launch(delivery: "fallback")
        runAndAssertHUDLifecycle(outcome: "F", clipboard: "1")
    }

    private func launch(delivery: String) {
        app = XCUIApplication()
        app.launchEnvironment["SAYMARK_UI_TESTING"] = "1"
        app.launchEnvironment["SAYMARK_UI_TESTING_DAILY_DRIVER"] = "1"
        app.launchEnvironment["SAYMARK_UI_TESTING_DELIVERY"] = delivery
        app.launchArguments += ["-saymark.didOnboard", "YES"]
        app.launch()

        XCTAssertTrue(app.windows["Saymark Daily Driver Test"].waitForExistence(timeout: 5))
    }

    private func runAndAssertHUDLifecycle(outcome: String, clipboard: String) {
        // SwiftUI exposes a macOS Button by its label even when its nested label
        // receives the explicit identifier.
        let button = app.buttons["Run deterministic dictation"]
        XCTAssertTrue(button.waitForExistence(timeout: 2))
        button.click()

        let signature = Self.signature(Self.transcript)
        let expected = "L|V3F1\(signature)|P|D1\(outcome)C\(clipboard)\(signature)|TRR"
        XCTAssertTrue(
            status(expected).waitForExistence(timeout: 10),
            "Ordered history must prove live 3-sentence HUD, processing, exact-once delivery, and teardown"
        )
    }

    private func status(_ text: String) -> XCUIElement {
        app.staticTexts[text]
    }

    private static func signature(_ text: String) -> String {
        let checksum = text.utf8.reduce(0) { (($0 * 31) + Int($1)) % 100_000 }
        return "N\(text.count)H\(checksum)"
    }
}
